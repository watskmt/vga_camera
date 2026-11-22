/* frame.h: camera frame buffers (VDMA, 3 slots + free / held buffers) and snapshots (stage 4) */
#ifndef FRAME_H
#define FRAME_H

#include "xil_types.h"

#define FB_W        640
#define FB_H        480
#define FB_LINE     (FB_W * 3)
#define FB_BYTES    (FB_LINE * FB_H)

/* Set up the VDMA (3 slots, display as genlock slave) and print the frame rate */
void frame_init(void);

/* Take the latest finished frame out of the VDMA rotation (or share one taken
 * moments ago) and return a handle. The frame stays unchanged until frame_release(). */
int frame_snapshot(void);

/* The snapshot's pixels (FB_BYTES, top line first) */
const u8 *frame_data(int h);

/* Make bytes [0, end) of the snapshot BMP B,G,R (converted in place, line by line).
 * Call before handing a range to lwIP. */
void frame_prepare(int h, u32 end);

/* Drop one reference; the buffer goes back to the free pool at 0 */
void frame_release(int h);

/* Elapsed time in microseconds (AXI timer, 50 ms tick + counter value) */
u32 frame_now_us(void);

#endif
