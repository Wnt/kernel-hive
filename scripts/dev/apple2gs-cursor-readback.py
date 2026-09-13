#!/usr/bin/env python3
"""apple2gs-cursor-readback.py — cursor readback on the apple2gs SHR desktop.

The GS software cursor is XORed in per VBL, so any single shm frame may or may
not contain it.  Every reading here is the PIXELWISE MEDIAN of N frames (the
stable desktop wins the vote) DIFFED against the median taken at the previous
position: the two changed clusters are "where it was" and "where it is", and
the previous position is known, so the other cluster is the answer.  Hotspot =
top-left of the changed cluster (the arrow's tip).
"""
import sys
import time

sys.path.insert(0, "/data/vms/sandbox/apple2gs-ptr/repo/scripts")

import numpy as np

import shmshot

SHM = "/data/vms/sandbox/apple2gs-ptr/rig1/fb.shm"

def frame():
    w, h, st, px = shmshot.read_frame(SHM)
    return np.frombuffer(shmshot.to_rgb(w, h, st, px), dtype=np.uint8).reshape(h, w, 3)

def median(n=9, gap=0.05):
    fs = []
    for _ in range(n):
        fs.append(frame().astype(np.int16)); time.sleep(gap)
    return np.median(np.stack(fs), axis=0).astype(np.int16)

def clusters(a, b, thr=24):
    d = (np.abs(a - b).sum(axis=2) > thr)
    ys, xs = np.nonzero(d)
    if len(xs) == 0:
        return []
    # crude single-link grouping by proximity: the two cursors are far apart
    pts = list(zip(xs.tolist(), ys.tolist()))
    out = []
    for x, y in pts:
        for g in out:
            if abs(x - g[0]) <= 48 and abs(y - g[1]) <= 48:
                g[0] = min(g[0], x); g[1] = min(g[1], y)
                g[2] = max(g[2], x); g[3] = max(g[3], y); g[4] += 1
                break
        else:
            out.append([x, y, x, y, 1])
    return [g for g in out if g[4] >= 6]

def other(a, b, known, tol=60):
    """the cluster that is NOT at `known` (x,y); returns (x,y,size)"""
    gs = clusters(a, b)
    cand = [g for g in gs if not (abs(g[0] - known[0]) <= tol and abs(g[1] - known[1]) <= tol)]
    if not cand:
        return None
    g = max(cand, key=lambda g: g[4])
    return (g[0], g[1], g[4])
