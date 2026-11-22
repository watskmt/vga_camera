/* face.h: face detection on the camera frames (Viola-Jones, OpenCV frontalface_alt cascade) */
#ifndef FACE_H
#define FACE_H

#include "xil_types.h"

#define FACE_MAX  16

struct face_box { u16 x, y, w; u16 hits; };    /* 640x480 coordinates, square box */

/* Call once after frame_init() */
void face_init(void);

/* Call from the main loop: does about budget_us of work (one window row at least), then returns */
void face_poll(u32 budget_us);

/* Latest result as JSON: {"seq":N,"ms":T,"faces":[[x,y,w],...]}. Returns the length. */
int face_json(char *buf, int len);

#endif
