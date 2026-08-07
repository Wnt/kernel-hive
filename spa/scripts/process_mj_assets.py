#!/usr/bin/env python3
"""
process_mj_assets.py — Bitmap pipeline for retained poster source art and icons.

Reads   $MJ_OUTPUT_DIR/<slot>/(v1..v4 | job*_v*).png
        (default spa/mj-output/ — gitignored; the raw MJ masters live outside
        the repo)
Writes  spa/public/assets/generated/hero-backplate.{webp,jpg}, era-90s.jpg,
        and application favicons

Tooling: Python + Pillow + numpy only (no ImageMagick needed).  sips is used
elsewhere for spot conversions but everything reproducible lives here.

Per-slot processing (see SLOTS below for the chosen variant):
  hero-backplate            crop to the scene's backdrop aspect (22:7.4 ~ 2.97:1),
                            warm tone, edge vignette + gentle centre knock-down.
  era-90s                   16:9 source for showcase poster capture.
  mark                      luma-key the near-black background, crop to subject,
                            and export application favicons/.ico.

Re-run after re-selecting a variant by editing SLOTS and running:
  spa/scripts/process-mj-assets.sh
"""
import os
import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))  # -> spa/
SRC  = os.environ.get("MJ_OUTPUT_DIR", os.path.join(ROOT, "mj-output"))
OUT  = os.path.join(ROOT, "public", "assets", "generated")

# --- chosen variant per slot (edit here to re-select) -----------------------
SLOTS = {
    "hero-backplate":           "hero-backplate-ultrawide/v2.png",  # symmetric warm aisle
    "era-90s":                  "era-90s/v1.png",
    "mark":                     "mark/v3.png",          # retained favicon source
}

os.makedirs(OUT, exist_ok=True)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def load(slot):
    p = os.path.join(SRC, SLOTS[slot])
    return Image.open(p).convert("RGB")

def f(im):        # PIL -> float array 0..1
    return np.asarray(im).astype(np.float32) / 255.0

def u8(a):        # float array -> PIL
    return Image.fromarray(np.clip(a * 255.0 + 0.5, 0, 255).astype(np.uint8))

def center_crop_aspect(im, aspect):
    w, h = im.size
    if w / h > aspect:            # too wide -> trim sides
        nw = int(round(h * aspect)); x = (w - nw) // 2
        return im.crop((x, 0, x + nw, h))
    nh = int(round(w / aspect)); y = (h - nh) // 2  # too tall -> trim top/bottom
    return im.crop((0, y, w, y + nh))

def warm_tone(a, r=1.05, g=1.0, b=0.90, sat=0.92, lift=0.0, gain=1.0):
    """Warm white-balance + gentle desaturation + brightness gain."""
    a = a.copy()
    a[..., 0] *= r; a[..., 1] *= g; a[..., 2] *= b
    lum = a @ np.array([0.299, 0.587, 0.114], np.float32)
    a = lum[..., None] + (a - lum[..., None]) * sat
    a = (a + lift) * gain
    return np.clip(a, 0, 1)

def vignette(a, edge=0.45, center_knock=0.0):
    """Darken edges (edge) and optionally knock the bright centre down a touch."""
    h, w = a.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    cx, cy = (w - 1) / 2, (h - 1) / 2
    r = np.sqrt(((xx - cx) / (w / 2)) ** 2 + ((yy - cy) / (h / 2)) ** 2)
    r = np.clip(r, 0, 1.4)
    v = 1.0 - edge * (r ** 2)                        # edge falloff
    if center_knock:                                 # soft dark pool in the middle
        v *= 1.0 - center_knock * np.exp(-(r ** 2) / 0.25)
    return np.clip(a * v[..., None], 0, 1)

def unsharp(a, amount=0.6, radius=2):
    """Light unsharp mask to restore crispness after tiling blends."""
    im = u8(a).filter(_gauss(radius))
    blur = f(im)
    return np.clip(a + (a - blur) * amount, 0, 1)

def _gauss(radius):
    from PIL import ImageFilter
    return ImageFilter.GaussianBlur(radius)

def save(im_or_a, name, webp=True, jpg=False, q=88):
    im = im_or_a if isinstance(im_or_a, Image.Image) else u8(im_or_a)
    paths = []
    if webp:
        p = os.path.join(OUT, name + ".webp")
        im.convert("RGB").save(p, "WEBP", quality=q, method=6); paths.append(p)
    if jpg:
        p = os.path.join(OUT, name + ".jpg")
        im.convert("RGB").save(p, "JPEG", quality=q, optimize=True); paths.append(p)
    return paths

# ---------------------------------------------------------------------------
# per-slot builders
# ---------------------------------------------------------------------------
def build_hero():
    im = load("hero-backplate")
    a = f(center_crop_aspect(im, 22 / 7.4))          # scene backdrop plane aspect
    a = warm_tone(a, r=1.05, b=0.92, sat=0.9, gain=0.98)
    a = vignette(a, edge=0.42, center_knock=0.18)    # edges dark + centre pool
    a = unsharp(a, amount=0.5, radius=2)
    out = u8(a).resize((2560, int(2560 * 7.4 / 22)), Image.LANCZOS)
    print("hero-backplate", out.size, save(out, "hero-backplate", webp=True, jpg=True, q=86))

def build_era(slot, gain):
    a = f(center_crop_aspect(load(slot), 16 / 9))
    a = warm_tone(a, r=1.06, g=1.0, b=0.88, sat=0.85, gain=gain)  # tone-match set
    a = vignette(a, edge=0.34)
    out = u8(a).resize((1600, 900), Image.LANCZOS)
    print(slot, save(out, slot, webp=False, jpg=True))

def build_mark():
    im = load("mark")
    a = f(im)
    lum = a @ np.array([0.299, 0.587, 0.114], np.float32)
    # luma key: near-black bg -> transparent; subject (glow+column) -> opaque
    lo, hi = 0.14, 0.34
    alpha = np.clip((lum - lo) / (hi - lo), 0, 1)
    # clean speckle: anything very dark is fully transparent
    alpha[lum < 0.10] = 0.0
    rgba = np.dstack([a, alpha])
    im2 = Image.fromarray(np.clip(rgba * 255 + 0.5, 0, 255).astype(np.uint8), "RGBA")
    # crop to opaque bbox, pad to square, center
    bbox = im2.getchannel("A").point(lambda v: 255 if v > 24 else 0).getbbox()
    if bbox:
        im2 = im2.crop(bbox)
    w, h = im2.size
    s = int(max(w, h) * 1.16)
    sq = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sq.paste(im2, ((s - w) // 2, (s - h) // 2), im2)
    logo = sq.resize((512, 512), Image.LANCZOS)
    # The old scene's transparent mark is intentionally not emitted; only the
    # still-current application icons are derived from this source.
    for px, nm in [(16, "favicon-16.png"), (32, "favicon-32.png"), (180, "apple-touch-icon.png")]:
        logo.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, nm))
    ico = os.path.join(OUT, "favicon.ico")
    logo.save(ico, sizes=[(16, 16), (32, 32), (48, 48)])
    print("icons", "-> favicon-16/32.png, apple-touch-icon.png, favicon.ico")

def main():
    build_hero()
    build_era("era-90s", 1.04)
    build_mark()
    print("done ->", OUT)

if __name__ == "__main__":
    main()
