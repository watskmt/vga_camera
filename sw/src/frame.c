/* =============================================================================
 * frame.c: camera frame buffers and snapshots (stage 4)
 *
 *   The RTL (cam_ddr_cfg) starts the VDMA with all 3 frame stores at 0x8000_0000
 *   (1 buffer). frame_init() sets it up again with separate buffers:
 *
 *     8 buffers of 900 KB at 0x8000_0000 + n x 1 MB (n = 0..7, below the program
 *     at 0x8100_0000). 3 are in the VDMA's 3 frame stores (slots), the others are
 *     free or held as snapshots.
 *
 *     S2MM (camera write) : cycles through the 3 slots
 *     MM2S (VGA read)     : dynamic genlock slave of S2MM, reads the frame finished
 *                           just before the one being written → no half-written frame
 *     (GenlockEn on S2MM as dynamic master stops it on frame 0 with VDMAIntErr on the
 *      board, so only MM2S uses genlock)
 *
 *   frame_snapshot() "holds" the latest finished frame instead of copying it
 *   (one 900 KB frame takes 140 ms or more just to read from DDR3, much longer than
 *   one camera frame):
 *     1. slot r = the one the display is reading (= latest finished frame, buffer P)
 *     2. point S2MM slot r at a free buffer (applies from the next camera frame;
 *        slot r is written again only 2 frames later)
 *     3. wait until the display has moved off slot r, then point MM2S slot r at the
 *        same buffer (it reads slot r again only after the camera has refilled it)
 *     4. P is now in no slot: the VDMA never touches it
 *   A request within SHARE_US of the last snapshot shares it (reference count), so
 *   several clients do not use up the free buffers. When none is free, the newest
 *   snapshot is shared.
 *
 *   frame_prepare() swaps the byte order of P in place (G,B,R → B,G,R for BMP) just ahead
 *   of what is about to be sent, so the data is still in the cache when lwIP reads it.
 *   frame_release() drops a reference; at 0 it writes the cache back and frees P.
 * ========================================================================== */
#include <string.h>

#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "frame.h"

#define VDMA_BASE     0x44A00000u
#define MM2S_DMACR    0x00
#define MM2S_DMASR    0x04
#define PARK_PTR      0x28
#define S2MM_DMACR    0x30
#define S2MM_DMASR    0x34
#define MM2S_VSIZE    0x50
#define MM2S_HSIZE    0x54
#define MM2S_STRIDE   0x58
#define MM2S_ADDR(i)  (0x5C + 4 * (i))
#define S2MM_VSIZE    0xA0
#define S2MM_HSIZE    0xA4
#define S2MM_STRIDE   0xA8
#define S2MM_ADDR(i)  (0xAC + 4 * (i))

/* DMACR: RS | Circular | IRQFrameCount = 1, MM2S adds GenlockEn | GenlockSrc (internal) */
#define DMACR_RESET   0x00000004u
#define S2MM_RUN      (0x00010000u | (1u << 1) | (1u << 0))
#define MM2S_RUN      (S2MM_RUN | (1u << 7) | (1u << 3))
#define DMASR_ERRS    0x0000FFF0u      /* error / interrupt bits (write 1 to clear) */

#define NUM_SLOT      3
#define NUM_BUF       8
#define BUF_ADDR(i)   (0x80000000u + 0x00100000u * (i))
#define SHARE_US      50000u           /* share a snapshot taken less than this ago */

/* AXI timer 0 (xiltimer tick timer, 50 ms interval) */
#define TMR_BASE      0x41C00000u
#define TMR_TCSR0     0x00
#define TMR_TLR0      0x04
#define TMR_TCR0      0x08
#define TMR_UDT0      (1u << 1)        /* 1 = count down */
#define TMR_HZ        100000000u
#define TICK_US       50000u

extern volatile u32 PlatformTicks;     /* platform.c: +1 per 50 ms timer interrupt */

enum buf_state { BUF_FREE, BUF_SLOT, BUF_HELD };

static struct {
	enum buf_state state;
	int refs;                          /* connections using this snapshot */
	u32 lines;                         /* lines already converted to B,G,R */
	u32 t_taken;
} bufs[NUM_BUF];
static int slot_buf[NUM_SLOT] = { 0, 1, 2 };   /* buffer in each VDMA slot */
static int newest = -1;                        /* newest held snapshot */

static inline u32 vdma_rd(u32 off) { return Xil_In32(VDMA_BASE + off); }
static inline void vdma_wr(u32 off, u32 v) { Xil_Out32(VDMA_BASE + off, v); }

static inline u32 wr_slot(void) { return (vdma_rd(PARK_PTR) >> 24) & 0x1F; }
static inline u32 rd_slot(void) { return (vdma_rd(PARK_PTR) >> 16) & 0x1F; }

u32 frame_now_us(void)
{
	u32 t, c, load, csr, in;

	do {
		t = PlatformTicks;
		c = Xil_In32(TMR_BASE + TMR_TCR0);
	} while (t != PlatformTicks);
	load = Xil_In32(TMR_BASE + TMR_TLR0);
	csr = Xil_In32(TMR_BASE + TMR_TCSR0);
	in = (csr & TMR_UDT0) ? load - c : c - load;  /* counts since the last reload */
	return t * TICK_US + in / (TMR_HZ / 1000000u);
}

static void busy_wait_us(u32 us)
{
	u32 t0 = frame_now_us();
	while (frame_now_us() - t0 < us)
		;
}

/* 1 if the S2MM write slot changes within us microseconds */
static int s2mm_moving(u32 us)
{
	u32 w = wr_slot(), t0 = frame_now_us();

	while (frame_now_us() - t0 < us)
		if (wr_slot() != w)
			return 1;
	return 0;
}

void frame_init(void)
{
	int i, n;
	u32 t0, w, r, w_prev, r_prev, w_chg = 0, r_chg = 0, same = 0;

	for (i = 0; i < NUM_BUF; i++)
		bufs[i].state = BUF_FREE;
	for (i = 0; i < NUM_SLOT; i++)
		bufs[slot_buf[i]].state = BUF_SLOT;

	/* cam_ddr_cfg (RTL) starts the VDMA after MIG calibration: wait for it */
	for (n = 0; n < 1000 && vdma_rd(S2MM_VSIZE) == 0; n++)
		busy_wait_us(1000);

	vdma_wr(MM2S_DMACR, DMACR_RESET);
	for (n = 0; n < 1000 && (vdma_rd(MM2S_DMACR) & DMACR_RESET); n++)
		busy_wait_us(10);
	vdma_wr(S2MM_DMACR, DMACR_RESET);
	for (n = 0; n < 1000 && (vdma_rd(S2MM_DMACR) & DMACR_RESET); n++)
		busy_wait_us(10);

	/* S2MM (camera → DDR3) */
	vdma_wr(S2MM_DMACR, S2MM_RUN);
	for (i = 0; i < NUM_SLOT; i++)
		vdma_wr(S2MM_ADDR(i), BUF_ADDR(slot_buf[i]));
	vdma_wr(S2MM_STRIDE, FB_LINE);
	vdma_wr(S2MM_HSIZE, FB_LINE);
	vdma_wr(S2MM_VSIZE, FB_H);                /* starts the channel */

	/* MM2S (DDR3 → VGA) */
	vdma_wr(MM2S_DMACR, MM2S_RUN);
	for (i = 0; i < NUM_SLOT; i++)
		vdma_wr(MM2S_ADDR(i), BUF_ADDR(slot_buf[i]));
	vdma_wr(MM2S_STRIDE, FB_LINE);
	vdma_wr(MM2S_HSIZE, FB_LINE);
	vdma_wr(MM2S_VSIZE, FB_H);

	/* Starting S2MM in the middle of a camera frame leaves it stopped on slot 0 with
	 * VDMAIntErr / SOFLateErr (seen on the board). Clearing the errors and committing
	 * VSIZE again gets it going. */
	for (n = 0; n < 5 && !s2mm_moving(200000); n++) {
		vdma_wr(S2MM_DMASR, DMASR_ERRS);
		vdma_wr(MM2S_DMASR, DMASR_ERRS);
		vdma_wr(S2MM_VSIZE, FB_H);
		vdma_wr(MM2S_VSIZE, FB_H);
	}

	/* Watch the slot pointers for 1 s: camera / display frame rate */
	w_prev = wr_slot();
	r_prev = rd_slot();
	t0 = frame_now_us();
	while (frame_now_us() - t0 < 1000000u) {
		w = wr_slot();
		r = rd_slot();
		if (w != w_prev) w_chg++;
		if (r != r_prev) r_chg++;
		if (w == r) same++;
		w_prev = w;
		r_prev = r;
	}
	xil_printf("[vdma] %d restarts, camera %d frames/s, display %d buffer switches/s, "
		   "same buffer %d samples\r\n", n, (int)w_chg, (int)r_chg, (int)same);
	xil_printf("[vdma] S2MM SR=%08x  MM2S SR=%08x  PARK=%08x\r\n",
		   (unsigned)vdma_rd(S2MM_DMASR), (unsigned)vdma_rd(MM2S_DMASR),
		   (unsigned)vdma_rd(PARK_PTR));
}

/* One line G,B,R → B,G,R in place, 4 pixels (3 words) at a time */
static void line_convert(u32 *p)
{
	int i;

	/* G,B,R -> B,G,R = swap bytes 0 and 1 of each pixel. Byte loads / stores instead of
	 * word shifts: this MicroBlaze-V's AREA barrel shifter takes ~1 cycle per bit shifted,
	 * which made the word version ~4x slower. */
	u8 *b = (u8 *)p;

	for (i = 0; i < FB_W; i += 4, b += 12) {
		u8 g0 = b[0], b0 = b[1], g1 = b[3], b1 = b[4];
		u8 g2 = b[6], b2 = b[7], g3 = b[9], b3 = b[10];
		b[0] = b0; b[1] = g0; b[3] = b1; b[4] = g1;
		b[6] = b2; b[7] = g2; b[9] = b3; b[10] = g3;
	}
}

int frame_snapshot(void)
{
	u32 t0 = frame_now_us();
	u32 r, w;
	int i, buf, fresh = -1;

	/* A recent snapshot is still in use: share it */
	if (newest >= 0 && t0 - bufs[newest].t_taken < SHARE_US) {
		bufs[newest].refs++;
		return newest;
	}
	for (i = 0; i < NUM_BUF; i++)
		if (bufs[i].state == BUF_FREE) {
			fresh = i;
			break;
		}
	if (fresh < 0) {                          /* all buffers in use: share the newest */
		bufs[newest].refs++;
		return newest;
	}

	w = wr_slot();
	r = rd_slot();
	if (r >= NUM_SLOT || r == w)
		r = (w + NUM_SLOT - 1) % NUM_SLOT;    /* the slot finished just before */
	buf = slot_buf[r];

	/* S2MM: slot r → the free buffer from the next camera frame */
	vdma_wr(S2MM_ADDR(r), BUF_ADDR(fresh));
	vdma_wr(S2MM_VSIZE, FB_H);
	/* MM2S: once the display has left slot r */
	while (rd_slot() == r && frame_now_us() - t0 < 200000u)
		;
	vdma_wr(MM2S_ADDR(r), BUF_ADDR(fresh));
	vdma_wr(MM2S_VSIZE, FB_H);
	slot_buf[r] = fresh;
	bufs[fresh].state = BUF_SLOT;

	bufs[buf].state = BUF_HELD;
	bufs[buf].refs = 1;
	bufs[buf].lines = 0;
	bufs[buf].t_taken = t0;
	newest = buf;
	return buf;
}

const u8 *frame_data(int h)
{
	return (const u8 *)BUF_ADDR(h);
}

void frame_prepare(int h, u32 end)
{
	u32 lines = (end + FB_LINE - 1) / FB_LINE;

	if (h < 0 || h >= NUM_BUF || bufs[h].state != BUF_HELD)
		return;
	if (lines > FB_H)
		lines = FB_H;
	for (; bufs[h].lines < lines; bufs[h].lines++) {
		UINTPTR a = BUF_ADDR(h) + bufs[h].lines * FB_LINE;
		/* The VDMA wrote DDR3 directly: drop any old cached copy before reading */
		Xil_DCacheInvalidateRange(a, FB_LINE);
		line_convert((u32 *)a);
	}
}

void frame_release(int h)
{
	if (h < 0 || h >= NUM_BUF || bufs[h].state != BUF_HELD || --bufs[h].refs > 0)
		return;
	/* Write the converted lines back and drop them from the cache, so no dirty line is
	 * written over a later camera frame when this buffer is back in a slot */
	Xil_DCacheFlushRange((UINTPTR)BUF_ADDR(h), FB_BYTES);
	bufs[h].state = BUF_FREE;
	if (newest == h)
		newest = -1;
}
