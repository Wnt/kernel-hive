#!/usr/bin/env python3
# g2g_key_detect.py <probe.csv> <inject.log> <workdir>
# Pixel-verified keystroke glass-to-glass join (box, ffmpeg/ffprobe + PIL).
# For trial i (char typed at col 4+i on row 0), the response = FIRST wire AU
# (t_fin > t0) whose glyph cell x[(4+i)*9 .. +9] y[0..16] has > THRESH bright
# pixels (luma>90) -- i.e. the echoed glyph has arrived on the wire. The text
# cursor lives in the NEXT cell, so it never triggers. g2g_ms = (t_fin - t0)/1e6.
import os, subprocess, sys
from PIL import Image
csv_path, inj_path, work = sys.argv[1], sys.argv[2], sys.argv[3]
stream = csv_path + ".h264"
frames_dir = os.path.join(work, "frames"); os.makedirs(frames_dir, exist_ok=True)
CW, THRESH, WIN_NS = 9, 6, 800e6
rows = []
with open(csv_path) as f:
    next(f)
    for line in f:
        p = line.strip().split(",")
        rows.append(dict(t_fin=int(p[1]), frame_id=int(p[2]), is_key=int(p[3]),
                         size=int(p[5]), off=int(p[6])))
out = subprocess.check_output(
    ["ffprobe", "-v", "error", "-select_streams", "v", "-show_frames",
     "-show_entries", "frame=pkt_pos", "-of", "csv=p=0", stream]).decode()
pkt_pos = [int(t) for t in (l.split(",")[0] for l in out.split("\n")) if t.isdigit()]
subprocess.check_call(
    ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", stream,
     "-fps_mode", "passthrough", os.path.join(frames_dir, "f%05d.png")])
_cache = {}
def bright(n, col):
    key = (n, col)
    if key in _cache:
        return _cache[key]
    im = Image.open(os.path.join(frames_dir, "f%05d.png" % (n + 1))).convert("L")
    x0 = col * CW
    c = im.crop((x0, 0, x0 + CW, 16)).getdata()
    v = sum(1 for p in c if p > 90)
    _cache[key] = v
    return v
for r in rows:
    r["pics"] = [i for i, p in enumerate(pkt_pos) if r["off"] <= p < r["off"] + r["size"]]
by_fin = sorted(rows, key=lambda r: r["t_fin"])
trials = []
with open(inj_path) as f:
    for line in f:
        p = line.split()
        if p and p[0] == "TRIAL":
            trials.append((int(p[1]), int(p[2])))
def pct(v, q):
    v = sorted(v); return v[min(len(v) - 1, int(len(v) * q))] if v else float("nan")
g2g = []
for i, t0 in trials:
    col = 4 + i
    hit = None
    for r in by_fin:
        if r["t_fin"] <= t0 or not r["pics"]:
            continue
        if r["t_fin"] - t0 > WIN_NS:
            break
        if bright(r["pics"][-1], col) > THRESH:
            hit = r; break
    if hit:
        g2g.append((hit["t_fin"] - t0) / 1e6)
print("trials=%d matched=%d" % (len(trials), len(g2g)))
print("G2G inject->wire ms : p50=%.2f p95=%.2f min=%.2f max=%.2f"
      % (pct(g2g, .5), pct(g2g, .95), min(g2g) if g2g else float("nan"),
         max(g2g) if g2g else float("nan")))
print("samples_ms " + " ".join("%.1f" % x for x in sorted(g2g)))
