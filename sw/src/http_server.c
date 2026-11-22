/* =============================================================================
 * http_server.c: simple web server (stages 3-4, lwIP RAW API)
 *
 *   GET /           : one HTML page that shows the camera image and keeps reloading it
 *   GET /frame.bmp  : a snapshot of the latest camera frame as a 24-bit BMP
 *   GET /faces      : latest face detection result (face.c) as JSON
 *   anything else   : 404
 *
 *   Frame buffers / snapshots: frame.c
 *     - each /frame.bmp request first takes the latest finished frame out of the VDMA
 *       rotation (no copy; converted to BMP B,G,R in place), sends it, and gives it
 *       back when done, so the image does not tear even though sending takes longer
 *       than one camera frame
 *     - each connection keeps its snapshot until it is closed (lwIP points into it);
 *       requests arriving within 50 ms of each other share one
 *
 *   Sending: the BMP header and pixels are passed to tcp_write without COPY (lwIP keeps
 *   pointers to the static data; no extra copy). Only the HTTP header, which lives in the
 *   per-connection struct, is copied. Nagle is off so that the last partial segment of
 *   each write does not wait for an ACK. Continues from the sent/poll callbacks and
 *   closes the connection when everything is acked (HTTP/1.0, Connection: close).
 *
 *   main.c (the template) calls print_app_header / start_application /
 *   transfer_data, so those 3 functions are provided here.
 * ========================================================================== */
#include <stdio.h>
#include <string.h>

#include "lwip/err.h"
#include "lwip/tcp.h"
#include "lwip/mem.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "frame.h"
#include "face.h"

#define HTTP_PORT     80

#define BMP_HDR_LEN   54
#define BMP_FILE_LEN  (BMP_HDR_LEN + FB_BYTES)

#define REQ_MAX       512
#define WRITE_MAX     4096    /* bytes per tcp_write call (well inside the 8 KB D-cache) */
#define POLL_INTERVAL 1       /* x 500 ms (tcp_slowtmr) */
#define IDLE_LIMIT    40      /* drop connections stalled for ~20 s */

enum body_kind { BODY_HTML, BODY_BMP, BODY_JSON, BODY_404 };

struct http_conn {
	char req[REQ_MAX];
	u16  req_len;
	u8   started;
	u8   idle;
	int  snap;                 /* frame.c snapshot handle, -1 = none */
	enum body_kind kind;
	char hdr[192];
	char json[400];            /* /faces body (sent with COPY) */
	u32  json_len;
	u32  hdr_len;
	u32  pos;                  /* bytes already passed to tcp_write (header + body) */
	u32  total;                /* header + body */
	u32  t_start;              /* us, for the log */
};

static const char html_page[] =
	"<!DOCTYPE html>\n"
	"<html lang=\"ja\"><head><meta charset=\"utf-8\">\n"
	"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
	"<title>vga_camera</title>\n"
	"<style>\n"
	"body{margin:0;padding:16px;background:#111;color:#ddd;font-family:sans-serif;text-align:center}\n"
	"#v{position:relative;width:640px;max-width:100%;margin:0 auto}\n"
	"img{display:block;width:100%;height:auto;background:#000}\n"
	"canvas{position:absolute;left:0;top:0;width:100%;height:100%}\n"
	"p{font-size:14px;color:#999}\n"
	"</style></head>\n"
	"<body>\n"
	"<h1>vga_camera</h1>\n"
	"<div id=\"v\"><img id=\"f\" src=\"/frame.bmp\" width=\"640\" height=\"480\" alt=\"camera\">"
	"<canvas id=\"c\" width=\"640\" height=\"480\"></canvas></div>\n"
	"<p id=\"s\">loading...</p>\n"
	"<script>\n"
	"var f=document.getElementById('f'),s=document.getElementById('s'),"
	"g=document.getElementById('c').getContext('2d'),n=0,t=Date.now(),d='';\n"
	"function next(){t=Date.now();f.src='/frame.bmp?'+t;}\n"
	"function faces(){fetch('/faces?'+Date.now()).then(function(r){return r.json();}).then(function(j){\n"
	"g.clearRect(0,0,640,480);g.lineWidth=3;g.strokeStyle='#0f0';\n"
	"j.faces.forEach(function(b){g.strokeRect(b[0],b[1],b[2],b[2]);});\n"
	"d=' / faces '+j.faces.length+' (detect '+j.ms+' ms)';}).catch(function(){});}\n"
	"f.onload=function(){n++;s.textContent='frame '+n+' ('+(Date.now()-t)+' ms)'+d;faces();setTimeout(next,100);};\n"
	"f.onerror=function(){s.textContent='error, retrying';setTimeout(next,1000);};\n"
	"</script>\n"
	"</body></html>\n";

static const char page_404[] = "404 Not Found\n";

static u8 bmp_hdr[BMP_HDR_LEN];
static int bmp_active;                 /* BMP responses in progress (see http_busy) */

/* ── BMP header (BITMAPFILEHEADER + BITMAPINFOHEADER, 24 bit, negative height = top-down) ── */
static void put_le16(u8 *p, u32 v) { p[0] = v; p[1] = v >> 8; }
static void put_le32(u8 *p, u32 v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static void bmp_header_init(void)
{
	memset(bmp_hdr, 0, sizeof(bmp_hdr));
	bmp_hdr[0] = 'B';
	bmp_hdr[1] = 'M';
	put_le32(&bmp_hdr[2], BMP_FILE_LEN);
	put_le32(&bmp_hdr[10], BMP_HDR_LEN);          /* pixel data offset */
	put_le32(&bmp_hdr[14], 40);                   /* BITMAPINFOHEADER */
	put_le32(&bmp_hdr[18], FB_W);
	put_le32(&bmp_hdr[22], (u32)(-FB_H));         /* top-down */
	put_le16(&bmp_hdr[26], 1);                    /* planes */
	put_le16(&bmp_hdr[28], 24);                   /* bpp */
	put_le32(&bmp_hdr[34], FB_BYTES);
	put_le32(&bmp_hdr[38], 2835);                 /* 72 dpi */
	put_le32(&bmp_hdr[42], 2835);
}

static u32 body_len(const struct http_conn *c)
{
	switch (c->kind) {
	case BODY_HTML: return sizeof(html_page) - 1;
	case BODY_BMP:  return BMP_FILE_LEN;
	case BODY_JSON: return c->json_len;
	default:        return sizeof(page_404) - 1;
	}
}

/* Pointer to body byte off and how many bytes are contiguous from there */
static const u8 *body_ptr(const struct http_conn *c, u32 off, u32 *avail)
{
	enum body_kind k = c->kind;

	if (k == BODY_JSON) {
		*avail = c->json_len - off;
		return (const u8 *)&c->json[off];
	}
	if (k == BODY_HTML) {
		*avail = sizeof(html_page) - 1 - off;
		return (const u8 *)&html_page[off];
	}
	if (k == BODY_404) {
		*avail = sizeof(page_404) - 1 - off;
		return (const u8 *)&page_404[off];
	}
	if (off < BMP_HDR_LEN) {
		*avail = BMP_HDR_LEN - off;
		return &bmp_hdr[off];
	}
	*avail = BMP_FILE_LEN - off;
	return frame_data(c->snap) + (off - BMP_HDR_LEN);
}

static void conn_free(struct http_conn *c)
{
	if (c == NULL)
		return;
	if (c->snap >= 0) {
		bmp_active--;
		frame_release(c->snap);          /* lwIP holds no pointers into it any more */
		if (c->pos >= c->total)
			xil_printf("[bmp] buffer %d sent in %d ms\r\n", c->snap,
				   (int)((frame_now_us() - c->t_start) / 1000));
		else
			xil_printf("[bmp] aborted at %d / %d bytes\r\n", (int)c->pos, (int)c->total);
	}
	mem_free(c);
}

/* Returns ERR_ABRT when the pcb was aborted (callbacks must then return ERR_ABRT) */
static err_t conn_close(struct tcp_pcb *pcb, struct http_conn *c)
{
	int pending = (c && c->pos < c->total) || tcp_sndqueuelen(pcb) != 0;

	tcp_arg(pcb, NULL);
	tcp_recv(pcb, NULL);
	tcp_sent(pcb, NULL);
	tcp_err(pcb, NULL);
	tcp_poll(pcb, NULL, 0);
	conn_free(c);
	/* With data still queued, abort: lwIP must not keep pointers into the snapshot */
	if (pending || tcp_close(pcb) != ERR_OK) {
		tcp_abort(pcb);
		return ERR_ABRT;
	}
	return ERR_OK;
}

/* Queue as much of the response as the send buffer allows */
static err_t send_more(struct tcp_pcb *pcb, struct http_conn *c)
{
	while (c->pos < c->total) {
		u32 room = tcp_sndbuf(pcb);
		u32 n = c->total - c->pos;
		const void *p;
		u8 flags;
		err_t err;

		if (room == 0 || tcp_sndqueuelen(pcb) >= TCP_SND_QUEUELEN - 4)
			break;
		if (c->pos < c->hdr_len) {
			u32 h = c->hdr_len - c->pos;
			p = &c->hdr[c->pos];
			flags = TCP_WRITE_FLAG_COPY;         /* the struct is freed on close */
			if (n > h)
				n = h;
		} else {
			u32 avail;
			p = body_ptr(c, c->pos - c->hdr_len, &avail);
			/* static data / snapshot: no copy. The JSON lives in the struct: copy */
			flags = (c->kind == BODY_JSON) ? TCP_WRITE_FLAG_COPY : 0;
			if (n > avail)
				n = avail;
		}
		if (n > room)
			n = room;
		if (n > WRITE_MAX)
			n = WRITE_MAX;
		if (c->pos + n < c->total)
			flags |= TCP_WRITE_FLAG_MORE;
		if (c->kind == BODY_BMP && c->pos + n > c->hdr_len + BMP_HDR_LEN)
			frame_prepare(c->snap, c->pos + n - c->hdr_len - BMP_HDR_LEN);
		err = tcp_write(pcb, p, n, flags);
		if (err == ERR_MEM)
			break;                               /* try again on sent/poll */
		if (err != ERR_OK)
			return err;
		c->pos += n;
		/* Send now, while the chunk just converted is still in the D-cache (8 KB).
		 * Anything the window does not allow yet goes out later on its own. */
		tcp_output(pcb);
	}
	return ERR_OK;
}

/* Returns ERR_ABRT when the pcb was aborted */
static err_t start_response(struct tcp_pcb *pcb, struct http_conn *c)
{
	const char *status = "200 OK";
	const char *type;

	if (strncmp(c->req, "GET /frame.bmp", 14) == 0 &&
	    (c->req[14] == ' ' || c->req[14] == '?')) {
		c->kind = BODY_BMP;
		type = "image/bmp";
		c->t_start = frame_now_us();
		c->snap = frame_snapshot();
		bmp_active++;
	} else if (strncmp(c->req, "GET /faces", 10) == 0 &&
		   (c->req[10] == ' ' || c->req[10] == '?')) {
		c->kind = BODY_JSON;
		type = "application/json";
		c->json_len = face_json(c->json, sizeof(c->json));
	} else if (strncmp(c->req, "GET / ", 6) == 0 ||
		   strncmp(c->req, "GET /index.html", 15) == 0) {
		c->kind = BODY_HTML;
		type = "text/html; charset=utf-8";
	} else {
		c->kind = BODY_404;
		status = "404 Not Found";
		type = "text/plain";
	}
	c->hdr_len = snprintf(c->hdr, sizeof(c->hdr),
			      "HTTP/1.0 %s\r\n"
			      "Content-Type: %s\r\n"
			      "Content-Length: %lu\r\n"
			      "Cache-Control: no-store\r\n"
			      "Connection: close\r\n"
			      "\r\n",
			      status, type, (unsigned long)body_len(c));
	c->total = c->hdr_len + body_len(c);
	c->pos = 0;
	c->started = 1;
	if (send_more(pcb, c) != ERR_OK)
		return conn_close(pcb, c);
	return ERR_OK;
}

static err_t http_sent(void *arg, struct tcp_pcb *pcb, u16_t len)
{
	struct http_conn *c = (struct http_conn *)arg;
	(void)len;

	if (c == NULL)
		return ERR_OK;
	c->idle = 0;
	if (c->pos < c->total) {
		if (send_more(pcb, c) != ERR_OK)
			return conn_close(pcb, c);
	} else if (tcp_sndqueuelen(pcb) == 0) {
		return conn_close(pcb, c);               /* everything sent and acked */
	}
	return ERR_OK;
}

static err_t http_poll(void *arg, struct tcp_pcb *pcb)
{
	struct http_conn *c = (struct http_conn *)arg;

	if (c == NULL) {
		tcp_abort(pcb);
		return ERR_ABRT;
	}
	if (++c->idle > IDLE_LIMIT) {
		xil_printf("[http] idle abort: pos %d/%d, sndqueuelen %d, sndbuf %d, unacked %s, unsent %s\r\n",
			   (int)c->pos, (int)c->total, (int)tcp_sndqueuelen(pcb), (int)tcp_sndbuf(pcb),
			   pcb->unacked ? "yes" : "no", pcb->unsent ? "yes" : "no");
		conn_free(c);
		tcp_arg(pcb, NULL);
		tcp_abort(pcb);
		return ERR_ABRT;
	}
	if (c->started && c->pos < c->total)
		send_more(pcb, c);
	return ERR_OK;
}

static void http_err(void *arg, err_t err)
{
	(void)err;
	conn_free((struct http_conn *)arg);          /* the pcb is already freed */
}

static err_t http_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
	struct http_conn *c = (struct http_conn *)arg;

	if (p == NULL || err != ERR_OK) {            /* client closed the connection */
		if (p)
			pbuf_free(p);
		if (c && c->started && (c->pos < c->total || tcp_sndqueuelen(pcb) != 0))
			return ERR_OK;                       /* half-close: keep sending the response */
		return conn_close(pcb, c);
	}
	tcp_recved(pcb, p->tot_len);
	if (c && !c->started) {
		u16 room = REQ_MAX - 1 - c->req_len;
		u16 n = p->tot_len < room ? p->tot_len : room;

		pbuf_copy_partial(p, &c->req[c->req_len], n, 0);
		c->req_len += n;
		c->req[c->req_len] = '\0';
		c->idle = 0;
		/* Only the request line is needed: start once we have one line (or the buffer is full) */
		if (strstr(c->req, "\r\n") || strchr(c->req, '\n') || c->req_len >= REQ_MAX - 1) {
			pbuf_free(p);
			return start_response(pcb, c);
		}
	}
	pbuf_free(p);
	return ERR_OK;
}

static err_t http_accept(void *arg, struct tcp_pcb *pcb, err_t err)
{
	struct http_conn *c;
	(void)arg;

	if (err != ERR_OK || pcb == NULL)
		return ERR_VAL;
	c = (struct http_conn *)mem_malloc(sizeof(*c));
	if (c == NULL) {
		tcp_abort(pcb);
		return ERR_ABRT;
	}
	memset(c, 0, sizeof(*c));
	c->snap = -1;
	tcp_setprio(pcb, TCP_PRIO_MIN);
	tcp_nagle_disable(pcb);
	tcp_arg(pcb, c);
	tcp_recv(pcb, http_recv);
	tcp_sent(pcb, http_sent);
	tcp_err(pcb, http_err);
	tcp_poll(pcb, http_poll, POLL_INTERVAL);
	return ERR_OK;
}

/* ── interface called from main.c ── */
void print_app_header(void)
{
	xil_printf("\n\r\n\r----- vga_camera HTTP server -----\n\r");
	xil_printf("GET /           : viewer page\n\r");
	xil_printf("GET /frame.bmp  : camera frame (%dx%d, 24-bit BMP)\n\r", FB_W, FB_H);
	xil_printf("GET /faces      : face detection result (JSON)\n\r");
}

int start_application(void)
{
	struct tcp_pcb *pcb;
	err_t err;

	bmp_header_init();
	frame_init();
	face_init();
	pcb = tcp_new_ip_type(IPADDR_TYPE_ANY);
	if (!pcb) {
		xil_printf("Error creating PCB. Out of Memory\n\r");
		return -1;
	}
	err = tcp_bind(pcb, IP_ANY_TYPE, HTTP_PORT);
	if (err != ERR_OK) {
		xil_printf("Unable to bind to port %d: err = %d\n\r", HTTP_PORT, err);
		return -2;
	}
	pcb = tcp_listen(pcb);
	if (!pcb) {
		xil_printf("Out of memory while tcp_listen\n\r");
		return -3;
	}
	tcp_accept(pcb, http_accept);
	xil_printf("HTTP server started @ port %d\n\r", HTTP_PORT);
	return 0;
}

int transfer_data(void)
{
	return 0;
}

/* Number of BMP responses being sent (main.c gives face detection less time then) */
int http_busy(void)
{
	return bmp_active;
}
