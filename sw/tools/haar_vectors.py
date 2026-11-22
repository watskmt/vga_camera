#!/usr/bin/env python3
"""haar_vectors.py: test vectors for rtl_haar/haar_engine.v (from the face.c model)

  python sw/tools/haar_vectors.py <image> <out_dir> <n_hw_stages> <level> [<level> ...]

For each pyramid level: <out_dir>/lvl<L>_img.mem (4800 x 32-bit words, image bytes
with row stride 160, little-endian in each word) and <out_dir>/lvl<L>_exp.txt:
    lw lh step windows weaks
    x y            (windows that pass the first n_hw_stages stages, scan order)
"""
import os
import sys
import importlib.util
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('face_ref', os.path.join(HERE, 'face_ref.py'))
fr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fr)


def letterbox(path):
    import cv2
    img = cv2.imread(path)
    h, w = img.shape[:2]
    sc = min(640 / w, 480 / h)
    small = cv2.resize(img, (int(w * sc), int(h * sc)), interpolation=cv2.INTER_AREA)
    canvas = np.zeros((480, 640, 3), np.uint8)
    oy, ox = (480 - small.shape[0]) // 2, (640 - small.shape[1]) // 2
    canvas[oy:oy + small.shape[0], ox:ox + small.shape[1]] = small
    return canvas


def run_level(base, casc, nst, level):
    W, H, stages, weaks = casc
    s_q8 = 256
    for _ in range(level):
        s_q8 = (s_q8 * fr.SCALE_Q8 + 128) >> 8
    lw = (fr.BASE_W * 256 + s_q8 // 2) // s_q8
    lh = (fr.BASE_H * 256 + s_q8 // 2) // s_q8
    img = fr.resize_level(base, lw, lh, s_q8) if s_q8 != 256 else base.copy()
    step = 1 if s_q8 > 512 else 2
    ii = np.zeros((lh + 1, lw + 1), np.int64)
    ii[1:, 1:] = img.cumsum(0).cumsum(1)
    sq = np.zeros((lh + 1, lw + 1), np.int64)
    sq[1:, 1:] = (img * img).cumsum(0).cumsum(1)
    area = (W - 2) * (H - 2)
    out, windows, weak_n = [], 0, 0
    for y in range(0, lh - H + 1, step):
        for x in range(0, lw - W + 1, step):
            windows += 1

            def rs(a, rx, ry, rw, rh):
                return int(a[y + ry, x + rx] - a[y + ry, x + rx + rw]
                           - a[y + ry + rh, x + rx] + a[y + ry + rh, x + rx + rw])
            s1 = rs(ii, 1, 1, W - 2, H - 2)
            s2 = rs(sq, 1, 1, W - 2, H - 2)
            nf2 = area * s2 - s1 * s1
            if nf2 <= 0:
                nf = 1
            elif nf2 < (1 << 32):
                nf = fr.isqrt(nf2)
            else:
                nf = fr.isqrt(nf2 >> 2) * 2
            if nf == 0:
                nf = 1
            ok = True
            for first, cnt, sthr in stages[:nst]:
                acc = 0
                for k in range(first, first + cnt):
                    thr, left, right, rects = weaks[k]
                    f = sum(wt * rs(ii, rx, ry, rw, rh) for rx, ry, rw, rh, wt in rects)
                    acc += left if f <= (thr * 2 * nf) >> 32 else right
                weak_n += cnt
                if acc < sthr:
                    ok = False
                    break
            if ok:
                out.append((x, y))
    return img, lw, lh, step, windows, weak_n, out


def main():
    path, out_dir, nst = sys.argv[1], sys.argv[2], int(sys.argv[3])
    levels = [int(v) for v in sys.argv[4:]]
    os.makedirs(out_dir, exist_ok=True)
    base = fr.to_gray160(letterbox(path))
    casc = fr.load_cascade_header(os.path.join(HERE, '..', 'src', 'face_cascade.h'))
    for L in levels:
        img, lw, lh, step, windows, weak_n, out = run_level(base, casc, nst, L)
        buf = np.zeros(160 * 120, np.uint8)
        for y in range(lh):
            buf[y * 160:y * 160 + lw] = img[y]
        words = buf.view('<u4')
        with open(os.path.join(out_dir, f'lvl{L}_img.mem'), 'w', newline='\n') as f:
            f.write('\n'.join(f'{int(w):08x}' for w in words) + '\n')
        with open(os.path.join(out_dir, f'lvl{L}_exp.txt'), 'w', newline='\n') as f:
            f.write(f'{lw} {lh} {step} {windows} {weak_n}\n')
            for x, y in out:
                f.write(f'{x} {y}\n')
        print(f'level {L}: {lw}x{lh} step {step}, {windows} windows, {weak_n} weaks, {len(out)} pass')


if __name__ == '__main__':
    main()
