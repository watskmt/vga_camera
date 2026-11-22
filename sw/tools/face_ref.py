#!/usr/bin/env python3
"""face_ref.py: bit-exact Python model of sw/src/face.c (for checking against OpenCV)

  python sw/tools/face_ref.py <image> [<haarcascade_frontalface_alt.xml>]

  - the image is fitted into 640x480 (letterboxed, like a camera frame), made gray and
    averaged 4x4 down to 160x120, exactly like face.c
  - runs the integer detector from face.c and prints the raw / grouped detections
  - if an OpenCV cascade XML is given and cv2 is installed, also runs
    cv2.CascadeClassifier.detectMultiScale on the same 160x120 image for comparison
  - needs numpy (and opencv-python for loading the image / the comparison)
"""
import sys
import numpy as np


# ── constants: keep in sync with face.c ──
BASE_W, BASE_H = 160, 120
SCALE_Q8 = 307              # 1.2 in Q8 (307 / 256 = 1.1992)
MIN_NEIGHBORS = 3
GROUP_EPS_Q8 = 51           # 0.2 in Q8


def load_cascade_header(path):
    """Parse sw/src/face_cascade.h back into Python lists."""
    import re
    t = open(path, encoding='utf-8').read()
    W = int(re.search(r'#define CASC_W\s+(\d+)', t).group(1))
    H = int(re.search(r'#define CASC_H\s+(\d+)', t).group(1))
    st = re.search(r'casc_stages\[CASC_NSTAGES\] = \{(.*?)\n\};', t, re.S).group(1)
    stages = [tuple(int(v) for v in m) for m in re.findall(r'\{ (-?\d+), (-?\d+), (-?\d+) \}', st)]
    wk = re.search(r'casc_weaks\[CASC_NWEAK\] = \{(.*?)\n\};', t, re.S).group(1)
    weaks = []
    for line in wk.strip().splitlines():
        nums = [int(v) for v in re.findall(r'-?\d+', line)]
        thr, left, right, n = nums[:4]
        xs, ys, ws, hs, wts = nums[4:7], nums[7:10], nums[10:13], nums[13:16], nums[16:19]
        weaks.append((thr, left, right, [(xs[k], ys[k], ws[k], hs[k], wts[k]) for k in range(n)]))
    return W, H, stages, weaks


def to_gray160(img_bgr):
    """640x480 BGR -> 4x4 sum of (77R + 150G + 29B) -> (sum + 2048) >> 12."""
    b = img_bgr[:, :, 0].astype(np.int32)
    g = img_bgr[:, :, 1].astype(np.int32)
    r = img_bgr[:, :, 2].astype(np.int32)
    gray = 77 * r + 150 * g + 29 * b
    s = gray.reshape(BASE_H, 4, BASE_W, 4).sum(axis=(1, 3))
    return ((s + 2048) >> 12).astype(np.int32)


def resize_level(base, lw, lh, s_q8):
    """Bilinear, centers aligned, Q8 source coordinates (same integer math as face.c)."""
    out = np.zeros((lh, lw), np.int32)
    bh, bw = base.shape
    for y in range(lh):
        fy = ((2 * y + 1) * s_q8 - 256) // 2      # Q8, = (y + 0.5) * s - 0.5
        if fy < 0:
            fy = 0
        y0 = fy >> 8
        wy = fy & 255
        y1 = min(y0 + 1, bh - 1)
        for x in range(lw):
            fx = ((2 * x + 1) * s_q8 - 256) // 2
            if fx < 0:
                fx = 0
            x0 = fx >> 8
            wx = fx & 255
            x1 = min(x0 + 1, bw - 1)
            top = base[y0, x0] * (256 - wx) + base[y0, x1] * wx
            bot = base[y1, x0] * (256 - wx) + base[y1, x1] * wx
            out[y, x] = (top * (256 - wy) + bot * wy + 32768) >> 16
    return out


def isqrt(n):
    return int(np.floor(np.sqrt(float(n)))) if n < (1 << 52) else int(n ** 0.5)


def detect(base, casc):
    W, H, stages, weaks = casc
    raw = []
    s_q8 = 256
    while True:
        lw = (BASE_W * 256 + s_q8 // 2) // s_q8
        lh = (BASE_H * 256 + s_q8 // 2) // s_q8
        if lw < W or lh < H:
            break
        img = resize_level(base, lw, lh, s_q8) if s_q8 != 256 else base.copy()
        ii = np.zeros((lh + 1, lw + 1), np.int64)
        sq = np.zeros((lh + 1, lw + 1), np.int64)
        ii[1:, 1:] = img.cumsum(0).cumsum(1)
        sq[1:, 1:] = (img * img).cumsum(0).cumsum(1)
        step = 1 if s_q8 > 512 else 2
        area = (W - 2) * (H - 2)
        for y in range(0, lh - H + 1, step):
            for x in range(0, lw - W + 1, step):
                def rs(a, rx, ry, rw, rh):
                    return int(a[y + ry, x + rx] - a[y + ry, x + rx + rw]
                               - a[y + ry + rh, x + rx] + a[y + ry + rh, x + rx + rw])
                s1 = rs(ii, 1, 1, W - 2, H - 2)
                s2 = rs(sq, 1, 1, W - 2, H - 2)
                nf2 = area * s2 - s1 * s1
                if nf2 <= 0:
                    nf = 1
                elif nf2 < (1 << 32):
                    nf = isqrt(nf2)
                else:
                    nf = isqrt(nf2 >> 2) * 2          # face.c: 32-bit sqrt
                if nf == 0:
                    nf = 1
                ok = True
                for first, cnt, sthr in stages:
                    acc = 0
                    for k in range(first, first + cnt):
                        thr, left, right, rects = weaks[k]
                        f = sum(wt * rs(ii, rx, ry, rw, rh) for rx, ry, rw, rh, wt in rects)
                        t = (thr * 2 * nf) >> 32          # mulh: floor(thr * nf), thr in Q31
                        acc += left if f <= t else right
                    if acc < sthr:
                        ok = False
                        break
                if ok:
                    raw.append(((x * s_q8 + 128) >> 8, (y * s_q8 + 128) >> 8, (W * s_q8 + 128) >> 8))
        s_q8 = (s_q8 * SCALE_Q8 + 128) >> 8
    return raw


def group(raw):
    """OpenCV groupRectangles (eps 0.2, minNeighbors 3), integer version of face.c."""
    n = len(raw)
    label = list(range(n))

    def find(i):
        while label[i] != i:
            label[i] = label[label[i]]
            i = label[i]
        return i

    for i in range(n):
        for j in range(i + 1, n):
            (x1, y1, w1), (x2, y2, w2) = raw[i], raw[j]
            delta = GROUP_EPS_Q8 * min(w1, w2)          # Q8: eps * (min w + min h) / 2, square windows
            if (abs(x1 - x2) * 256 <= delta and abs(y1 - y2) * 256 <= delta and
                    abs(x1 + w1 - x2 - w2) * 256 <= delta):
                a, b = find(i), find(j)
                if a != b:
                    label[b] = a
    cl = {}
    for i in range(n):
        cl.setdefault(find(i), []).append(raw[i])
    out = []
    for members in cl.values():
        if len(members) <= MIN_NEIGHBORS:
            continue
        k = len(members)
        x = (sum(m[0] for m in members) + k // 2) // k
        y = (sum(m[1] for m in members) + k // 2) // k
        w = (sum(m[2] for m in members) + k // 2) // k
        out.append((x, y, w, k))
    # drop rects inside a bigger cluster with more members (OpenCV does the same)
    keep = []
    for i, (x, y, w, k) in enumerate(out):
        inside = False
        for j, (x2, y2, w2, k2) in enumerate(out):
            if i == j:
                continue
            d = (w2 * 51) >> 8
            if (k2 > max(3, k) and x >= x2 - d and y >= y2 - d and
                    x + w <= x2 + w2 + d and y + w <= y2 + w2 + d):
                inside = True
        if not inside:
            keep.append((x, y, w, k))
    return keep


def main():
    import cv2
    img = cv2.imread(sys.argv[1])
    h, w = img.shape[:2]
    sc = min(640 / w, 480 / h)
    small = cv2.resize(img, (int(w * sc), int(h * sc)), interpolation=cv2.INTER_AREA)
    canvas = np.zeros((480, 640, 3), np.uint8)
    oy, ox = (480 - small.shape[0]) // 2, (640 - small.shape[1]) // 2
    canvas[oy:oy + small.shape[0], ox:ox + small.shape[1]] = small
    base = to_gray160(canvas)
    hdr = __file__.replace('\\', '/').rsplit('/', 2)[0] + '/src/face_cascade.h'
    casc = load_cascade_header(hdr)
    raw = detect(base, casc)
    print(f'face.c model: {len(raw)} raw windows')
    for r in group(raw):
        x, y, w, k = r
        print(f'  face at base ({x},{y}) size {w}  -> 640x480 ({x*4},{y*4}) size {w*4}, {k} hits')
    if len(sys.argv) > 2:
        cc = cv2.CascadeClassifier(sys.argv[2])
        g8 = base.astype(np.uint8)
        res = cc.detectMultiScale(g8, scaleFactor=1.2, minNeighbors=3, minSize=(20, 20))
        print(f'OpenCV detectMultiScale: {len(res)} faces')
        for (x, y, w, h) in res:
            print(f'  face at base ({x},{y}) size {w}x{h}')


if __name__ == '__main__':
    main()
