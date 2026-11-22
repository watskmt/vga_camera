/* face.c: face detection on the camera frames (Viola-Jones / Haar cascade)
 *
 * Cascade: OpenCV haarcascade_frontalface_alt (20x20 window, 22 stages, 2135 stumps),
 * converted to integer tables in face_cascade.h by sw/tools/gen_cascade.py.
 * sw/tools/face_ref.py is a bit-exact Python model of this file (checked against
 * OpenCV's detectMultiScale).
 *
 * Steps (one detection = one camera frame):
 *   1. take a snapshot (frame.c), make it B,G,R in place (frame_prepare) and average
 *      it down to gray 160x120: (sum over 4x4 of (77 R + 150 G + 29 B) + 2048) >> 12
 *   2. image pyramid, factor 1.2: for each level, bilinear resize of the 160x120 image,
 *      integral image and squared integral image (u32 is enough: 160*120*255^2 < 2^32)
 *   3. slide the 20x20 window (step 2 while the level scale <= 2, then 1). Per window:
 *        nf = sqrt(A * sqsum - sum^2) over the inner 18x18 rect (A = 324)
 *        weak classifier: sum(w_i * rectsum_i) <= floor(thr * nf)  ? left : right
 *        stage: sum of leaf values >= stage threshold, else reject the window
 *   4. group the hits (OpenCV groupRectangles, eps 0.2, more than 3 neighbours)
 *
 * The work is split into slices (budget given to face_poll) so that it can be
 * called from the main loop without stalling lwIP. Fixed point only (no FPU).
 */
#include <string.h>
#include <stdio.h>
#include "xil_printf.h"
#include "frame.h"
#include "face.h"
#include "face_cascade.h"

#define BASE_W         160
#define BASE_H         120
#define DOWN           4                   /* 640x480 -> 160x120 */
#define SCALE_Q8       307                 /* pyramid factor 1.2 (Q8) */
#define MIN_NEIGHBORS  3
#define GROUP_EPS_Q8   51                  /* 0.2 */
#define MAX_RAW        512
#define NORM_AREA      ((CASC_W - 2) * (CASC_H - 2))

enum face_state { ST_IDLE, ST_DOWN, ST_LEVEL, ST_SCAN, ST_GROUP };

struct raw_hit { u16 x, y, w; };           /* base (160x120) coordinates */

static u8  base_img[BASE_W * BASE_H];
static u8  lvl_img[BASE_W * BASE_H];

/* Hot data, kept together in one block smaller than the 32 KB D-cache so that its
 * lines never evict each other (the cache maps addresses directly):
 *   - integral image of one band of CASC_H image rows (the rows of the current window
 *     row). Rect sums only use differences, so band-relative sums are enough; the band
 *     is rebuilt for each window row.
 *   - prefix sums over x of the column sums of v^2 over the inner CASC_H - 2 band rows:
 *     the squared sum of a window's inner rect is psq[x + 1 + CASC_W - 2] - psq[x + 1]
 *     (a squared integral image is only needed for that)
 *   - the weak classifiers of the first HOT_STAGES stages with their rect offsets for
 *     the current level (almost all windows are rejected there; later stages compute
 *     their offsets on the fly from casc_weaks) */
#define BAND_ROWS   (CASC_H + 1)
#define HOT_STAGES  10
#define HOT_MAX     384

struct hot_weak {
	u16 o[3], hs[3];
	u8  w[3];
	s8  wt[3];
	u8  n, pad;
	s32 thr, left, right;
};

static struct {
	u32 ii[BAND_ROWS * (BASE_W + 1)];
	u32 psq[BASE_W + 1];
	struct hot_weak hw[HOT_MAX];
} hot __attribute__((aligned(64)));
static u32 hot_n;                          /* weak classifiers in hot.hw */
static struct raw_hit raw[MAX_RAW];
static int raw_n;

static enum face_state st = ST_IDLE;
static int snap = -1, gy;
static u32 s_q8, lw, lh, stride, step, wx, wy;
static u32 t_start, windows;
static u32 t_state[5], weak_evals;         /* profiling (printed per detection) */

/* published result */
static struct face_box result[FACE_MAX];
static int result_n;
static u32 result_seq, result_ms, result_windows;

/* ── helpers ──
 * This MicroBlaze-V has the AREA barrel shifter (C_USE_BARREL = 2): a shift takes
 * about one cycle per bit. The inner loops therefore avoid shifts: byte offsets
 * instead of index << 2, mulh instead of 64-bit shifts, one shift per output pixel. */
static u32 isqrt32(u32 n)
{
	u32 bit = 1u << 30, r = 0;

	while (bit > n)
		bit >>= 2;
	while (bit) {
		if (n >= r + bit) {
			n -= r + bit;
			r = (r >> 1) + bit;
		} else {
			r >>= 1;
		}
		bit >>= 2;
	}
	return r;
}

/* rect sum from byte offsets into a u32 integral image */
#define LD(p, o)  (*(const u32 *)((p) + (o)))
static inline u32 rsb(const u8 *p, u32 o, u32 w, u32 hs)
{
	return LD(p, o) - LD(p, o + w) - LD(p, o + hs) + LD(p, o + hs + w);
}

/* floor(thr * nf) with thr in Q31 and nf2x = 2 * nf: the high word of the product */
static inline s32 mulh(s32 a, s32 b)
{
	s32 r;
	asm("mulh %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
	return r;
}

/* 1. one gray row (= 4 source lines) of the 160x120 image:
 *    (sum of 16 x (77 R + 150 G + 29 B) + 2048) >> 12 */
static void down_row(const u8 *fb, int y)
{
	int x, dy, dx;
	const u8 *line;
	u8 *out = &base_img[y * BASE_W];

	for (x = 0; x < BASE_W; x++) {
		u32 s = 0;
		for (dy = 0; dy < DOWN; dy++) {
			line = fb + (y * DOWN + dy) * FB_LINE + x * DOWN * 3;
			for (dx = 0; dx < DOWN; dx++, line += 3)   /* B, G, R (after frame_prepare) */
				s += 77 * line[2] + 150 * line[1] + 29 * line[0];
		}
		out[x] = (s + 2048) >> 12;
	}
}

/* 2. resize + rect offsets (bytes) for the current level */
static void level_setup(void)
{
	u32 x, y, k, r;

	if (s_q8 != 256) {
		for (y = 0; y < lh; y++) {
			s32 fy = ((s32)(2 * y + 1) * (s32)s_q8 - 256) / 2;
			u32 y0, y1, wyq;
			if (fy < 0)
				fy = 0;
			y0 = fy >> 8;
			wyq = fy & 255;
			y1 = (y0 + 1 < BASE_H) ? y0 + 1 : BASE_H - 1;
			for (x = 0; x < lw; x++) {
				s32 fx = ((s32)(2 * x + 1) * (s32)s_q8 - 256) / 2;
				u32 x0, x1, wxq, top, bot;
				if (fx < 0)
					fx = 0;
				x0 = fx >> 8;
				wxq = fx & 255;
				x1 = (x0 + 1 < BASE_W) ? x0 + 1 : BASE_W - 1;
				top = base_img[y0 * BASE_W + x0] * (256 - wxq) + base_img[y0 * BASE_W + x1] * wxq;
				bot = base_img[y1 * BASE_W + x0] * (256 - wxq) + base_img[y1 * BASE_W + x1] * wxq;
				lvl_img[y * lw + x] = (top * (256 - wyq) + bot * wyq + 32768) >> 16;
			}
		}
	} else {
		memcpy(lvl_img, base_img, sizeof(base_img));
	}

	stride = lw + 1;
	for (k = 0; k < hot_n; k++) {
		const struct casc_weak *wk = &casc_weaks[k];
		struct hot_weak *h = &hot.hw[k];
		h->n = wk->n;
		h->thr = wk->thr;
		h->left = wk->left;
		h->right = wk->right;
		for (r = 0; r < 3; r++) {
			h->o[r] = (wk->y[r] * stride + wk->x[r]) * 4;
			h->hs[r] = wk->h[r] * stride * 4;
			h->w[r] = wk->w[r] * 4;
			h->wt[r] = wk->wt[r];
		}
	}
	step = (s_q8 > 512) ? 1 : 2;
}

/* integral image of level rows y0 .. y0 + CASC_H - 1 (band row 0 = zeros) and the
 * squared prefix sums of the inner rows y0 + 1 .. y0 + CASC_H - 2 */
static void band_build(u32 y0)
{
	static u32 colsq[BASE_W];
	u32 x, y;

	memset(hot.ii, 0, stride * sizeof(u32));
	memset(colsq, 0, lw * sizeof(u32));
	for (y = 0; y < CASC_H; y++) {
		const u8 *src = &lvl_img[(y0 + y) * lw];
		u32 *pi = &hot.ii[(y + 1) * stride];
		const u32 *qi = pi - stride;
		u32 rs = 0;
		int inner = (y >= 1 && y <= CASC_H - 2);
		pi[0] = 0;
		for (x = 0; x < lw; x++) {
			u32 v = src[x];
			rs += v;
			pi[x + 1] = qi[x + 1] + rs;
			if (inner)
				colsq[x] += v * v;
		}
	}
	hot.psq[0] = 0;
	for (x = 0; x < lw; x++)
		hot.psq[x + 1] = hot.psq[x] + colsq[x];
}

/* 3. one window: 1 = face */
static int classify(u32 x)
{
	const u8 *pi = (const u8 *)&hot.ii[x];
	u32 o = (stride + 1) * 4, w = (CASC_W - 2) * 4, hs = (CASC_H - 2) * stride * 4;
	u32 s1 = rsb(pi, o, w, hs);
	u32 s2 = hot.psq[x + 1 + CASC_W - 2] - hot.psq[x + 1];
	u64 nf2 = (u64)NORM_AREA * s2, ss = (u64)s1 * s1;
	s32 nf2x;
	int si;
	u32 k;

	/* nf = sqrt(A * sqsum - sum^2); the 64-bit value only exceeds 32 bits for very
	 * high-contrast windows, then take sqrt(v / 4) * 2 */
	nf2 = nf2 > ss ? nf2 - ss : 0;
	if ((u32)(nf2 >> 32) == 0)
		nf2x = isqrt32((u32)nf2);
	else
		nf2x = isqrt32((u32)(nf2 >> 2)) * 2;
	if (nf2x == 0)
		nf2x = 1;
	nf2x *= 2;

	for (si = 0; si < HOT_STAGES; si++) {
		const struct casc_stage *sg = &casc_stages[si];
		s32 acc = 0;
		weak_evals += sg->count;
		for (k = sg->first; k < (u32)sg->first + sg->count; k++) {
			const struct hot_weak *h = &hot.hw[k];
			s32 f = h->wt[0] * (s32)rsb(pi, h->o[0], h->w[0], h->hs[0])
			      + h->wt[1] * (s32)rsb(pi, h->o[1], h->w[1], h->hs[1]);
			if (h->n > 2)
				f += h->wt[2] * (s32)rsb(pi, h->o[2], h->w[2], h->hs[2]);
			acc += f <= mulh(h->thr, nf2x) ? h->left : h->right;
		}
		if (acc < sg->thr)
			return 0;
	}
	for (; si < CASC_NSTAGES; si++) {
		const struct casc_stage *sg = &casc_stages[si];
		s32 acc = 0;
		weak_evals += sg->count;
		for (k = sg->first; k < (u32)sg->first + sg->count; k++) {
			const struct casc_weak *wk = &casc_weaks[k];
			s32 f = 0;
			u32 r;
			for (r = 0; r < wk->n; r++)
				f += wk->wt[r] * (s32)rsb(pi, (wk->y[r] * stride + wk->x[r]) * 4,
							  wk->w[r] * 4, wk->h[r] * stride * 4);
			acc += f <= mulh(wk->thr, nf2x) ? wk->left : wk->right;
		}
		if (acc < sg->thr)
			return 0;
	}
	return 1;
}

/* 4. groupRectangles (same as face_ref.py) */
static int lbl[MAX_RAW];

static int find_root(int i)
{
	while (lbl[i] != i) {
		lbl[i] = lbl[lbl[i]];
		i = lbl[i];
	}
	return i;
}

static u32 absdiff(u32 a, u32 b) { return a > b ? a - b : b - a; }

static void group(void)
{
	static u32 cx[MAX_RAW], cy[MAX_RAW], cw[MAX_RAW], cn[MAX_RAW];
	struct face_box tmp[FACE_MAX * 2];
	int i, j, n = raw_n, nt = 0;

	for (i = 0; i < n; i++)
		lbl[i] = i;
	for (i = 0; i < n; i++)
		for (j = i + 1; j < n; j++) {
			u32 d = GROUP_EPS_Q8 * (raw[i].w < raw[j].w ? raw[i].w : raw[j].w);
			if (absdiff(raw[i].x, raw[j].x) * 256 <= d &&
			    absdiff(raw[i].y, raw[j].y) * 256 <= d &&
			    absdiff(raw[i].x + raw[i].w, raw[j].x + raw[j].w) * 256 <= d) {
				int a = find_root(i), b = find_root(j);
				if (a != b)
					lbl[b] = a;
			}
		}
	for (i = 0; i < n; i++)
		cx[i] = cy[i] = cw[i] = cn[i] = 0;
	for (i = 0; i < n; i++) {
		int r = find_root(i);
		cx[r] += raw[i].x;
		cy[r] += raw[i].y;
		cw[r] += raw[i].w;
		cn[r]++;
	}
	for (i = 0; i < n && nt < FACE_MAX * 2; i++) {
		u32 k = cn[i];
		if (k <= MIN_NEIGHBORS)
			continue;
		tmp[nt].x = (cx[i] + k / 2) / k;
		tmp[nt].y = (cy[i] + k / 2) / k;
		tmp[nt].w = (cw[i] + k / 2) / k;
		tmp[nt].hits = k;
		nt++;
	}
	/* drop boxes inside a bigger one with more hits */
	result_n = 0;
	for (i = 0; i < nt; i++) {
		int inside = 0;
		for (j = 0; j < nt; j++) {
			u32 d = (tmp[j].w * 51) >> 8, kmin = tmp[i].hits > 3 ? tmp[i].hits : 3;
			if (i != j && tmp[j].hits > kmin &&
			    tmp[i].x + d >= tmp[j].x && tmp[i].y + d >= tmp[j].y &&
			    tmp[i].x + tmp[i].w <= tmp[j].x + tmp[j].w + d &&
			    tmp[i].y + tmp[i].w <= tmp[j].y + tmp[j].w + d)
				inside = 1;
		}
		if (!inside && result_n < FACE_MAX) {
			result[result_n].x = tmp[i].x * DOWN;
			result[result_n].y = tmp[i].y * DOWN;
			result[result_n].w = tmp[i].w * DOWN;
			result[result_n].hits = tmp[i].hits;
			result_n++;
		}
	}
}

/* ── public ── */
void face_init(void)
{
	st = ST_IDLE;
	result_n = 0;
	result_seq = 0;
	hot_n = casc_stages[HOT_STAGES].first;
	if (hot_n > HOT_MAX)
		xil_printf("[face] HOT_MAX too small (%d)\r\n", (int)hot_n);
	xil_printf("[face] Haar cascade %dx%d, %d stages, %d weak classifiers, image %dx%d\r\n",
		   CASC_W, CASC_H, CASC_NSTAGES, CASC_NWEAK, BASE_W, BASE_H);
}

void face_poll(u32 budget_us)
{
	u32 t0 = frame_now_us(), x, ts;

	while ((ts = frame_now_us()) - t0 < budget_us) {
		enum face_state cur = st;
		switch (st) {
		case ST_IDLE:
			snap = frame_snapshot();
			if (snap < 0)
				return;
			t_start = frame_now_us();
			memset(t_state, 0, sizeof(t_state));
			weak_evals = 0;
			gy = 0;
			raw_n = 0;
			windows = 0;
			st = ST_DOWN;
			break;

		case ST_DOWN:
			frame_prepare(snap, (u32)(gy + 1) * DOWN * FB_LINE);
			down_row(frame_data(snap), gy);
			if (++gy == BASE_H) {
				frame_release(snap);
				snap = -1;
				s_q8 = 256;
				st = ST_LEVEL;
			}
			break;

		case ST_LEVEL:
			lw = (BASE_W * 256 + s_q8 / 2) / s_q8;
			lh = (BASE_H * 256 + s_q8 / 2) / s_q8;
			if (lw < CASC_W || lh < CASC_H) {
				st = ST_GROUP;
				break;
			}
			level_setup();
			wx = wy = 0;
			st = ST_SCAN;
			break;

		case ST_SCAN:
			/* up to 8 windows per step so that a slice stays close to its budget */
			if (wx == 0)
				band_build(wy);
			for (x = 0; x < 8 && wx + CASC_W <= lw; x++, wx += step) {
				windows++;
				if (classify(wx) && raw_n < MAX_RAW) {
					raw[raw_n].x = (wx * s_q8 + 128) >> 8;
					raw[raw_n].y = (wy * s_q8 + 128) >> 8;
					raw[raw_n].w = (CASC_W * s_q8 + 128) >> 8;
					raw_n++;
				}
			}
			if (wx + CASC_W > lw) {
				wx = 0;
				wy += step;
				if (wy + CASC_H > lh) {
					s_q8 = (s_q8 * SCALE_Q8 + 128) >> 8;
					st = ST_LEVEL;
				}
			}
			break;

		case ST_GROUP:
			group();
			result_ms = (frame_now_us() - t_start) / 1000;
			result_windows = windows;
			result_seq++;
			if (result_n || (result_seq % 10) == 1) {
				int i;
				xil_printf("[face] #%d: %d face(s) in %d ms (%d windows, %d raw)",
					   (int)result_seq, result_n, (int)result_ms, (int)windows, raw_n);
				for (i = 0; i < result_n; i++)
					xil_printf(" (%d,%d %d)", result[i].x, result[i].y, result[i].w);
				xil_printf("\r\n");
			}
			xil_printf("[face] time: down %d, level %d, scan %d ms, weak evals %d\r\n",
				   (int)(t_state[ST_DOWN] / 1000), (int)(t_state[ST_LEVEL] / 1000),
				   (int)(t_state[ST_SCAN] / 1000), (int)weak_evals);
			st = ST_IDLE;
			return;
		}
		t_state[cur] += frame_now_us() - ts;
	}
}

int face_json(char *buf, int len)
{
	int n, i;

	n = snprintf(buf, len, "{\"seq\":%lu,\"ms\":%lu,\"windows\":%lu,\"faces\":[",
		     (unsigned long)result_seq, (unsigned long)result_ms, (unsigned long)result_windows);
	for (i = 0; i < result_n && n < len; i++)
		n += snprintf(buf + n, len - n, "%s[%u,%u,%u]", i ? "," : "",
			      result[i].x, result[i].y, result[i].w);
	if (n < len)
		n += snprintf(buf + n, len - n, "]}");
	return n < len ? n : len - 1;
}
