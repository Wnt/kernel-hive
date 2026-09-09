"""labctl.d/capture.py — screendump backends: PPM->PNG conversion and the
QMP / x11spike / shm capture routes `labctl shot` and `labctl assert` share.
Moved verbatim out of scripts/labctl (size-exclusions.json split, step 3).
Imports from labctl.d/common only — never from labctl.
"""

import os, shutil, subprocess

from common import cdrv, ensure_running, is_shm_tile, is_x11_tile, shm_path, x11_display, SHMSHOT

X11SPIKE = os.environ.get("LABCTL_X11SPIKE", "/data/vms/streamhost/build/target/release/x11spike")


# ---- PPM -> PNG (robust: PIL, then pnmtopng, then ffmpeg) -------------------
def ppm_to_png(ppm, png):
    try:
        from PIL import Image

        Image.open(ppm).save(png)
        return
    except Exception:
        pass
    if shutil.which("pnmtopng"):
        with open(png, "wb") as out:
            if subprocess.run(["pnmtopng", ppm], stdout=out, stderr=subprocess.DEVNULL).returncode == 0:
                return
    if shutil.which("ffmpeg"):
        if (
            subprocess.run(
                ["ffmpeg", "-y", "-i", ppm, png], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            ).returncode
            == 0
        ):
            return
    raise RuntimeError("no PPM->PNG converter worked (PIL/pnmtopng/ffmpeg)")


def capture_png(name, c, out, resume):
    if resume:
        ensure_running(c, name)
    # `or "."` is load-bearing, and its absence reads as a fleet-wide outage.
    # QEMU resolves a RELATIVE screendump path against its own cwd, not ours, so
    # a bare `out.png` (dirname "") made the dump land somewhere we never look:
    # cdrv exits 0 and prints "ok", the existence check below fails, and every
    # station answers `screendump failed: ok` while streaming perfectly.
    # capture_png_x11() below has always had this guard; this one did not.
    ppm = os.path.join(os.path.dirname(out) or ".", ".labctl-%s-%d.ppm" % (name, os.getpid()))
    r = cdrv(c["qmp"], "dump", ppm)
    if r.returncode != 0 or not os.path.exists(ppm):
        raise RuntimeError("screendump failed: %s" % (r.stderr.strip() or r.stdout.strip() or "no PPM produced"))
    try:
        ppm_to_png(ppm, out)
    finally:
        try:
            os.remove(ppm)
        except OSError:
            pass


def capture_png_x11(name, c, out):
    """Screendump an x11-capture tile via x11spike (GetImage on the X root of
    SH_X11_DISPLAY) -> PPM -> PNG. No QMP, no cont/resume."""
    if not os.path.exists(X11SPIKE):
        raise RuntimeError("x11spike not found at %s (set LABCTL_X11SPIKE)" % X11SPIKE)
    disp = x11_display(c, name)
    ppm = os.path.join(os.path.dirname(out) or ".", ".labctl-%s-%d.ppm" % (name, os.getpid()))
    env = dict(os.environ, DISPLAY=disp)
    r = subprocess.run([X11SPIKE, "capture", ppm], capture_output=True, text=True, env=env, timeout=30)
    if r.returncode != 0 or not os.path.exists(ppm):
        raise RuntimeError("x11spike capture failed: %s" % (r.stderr.strip() or r.stdout.strip() or "no PPM"))
    try:
        ppm_to_png(ppm, out)
    finally:
        try:
            os.remove(ppm)
        except OSError:
            pass


def capture_png_shm(name, c, out):
    """Screendump a shm-capture tile by reading the framebuffer its emulator
    publishes (SH_SHM_PATH) -> PPM -> PNG. No QMP, no X server, no window.

    Dispatching this to the x11 path instead does not fail — x11spike happily
    captures the tile's unused SH_X11_DISPLAY and returns an all-black image
    with exit 0. That silent wrong answer is what this backend fixes."""
    fb = shm_path(c, name)
    ppm = os.path.join(os.path.dirname(out) or ".", ".labctl-%s-%d.ppm" % (name, os.getpid()))
    r = subprocess.run(["python3", SHMSHOT, fb, ppm], capture_output=True, text=True, timeout=30)
    if r.returncode != 0 or not os.path.exists(ppm):
        raise RuntimeError("shm capture failed: %s" % (r.stderr.strip() or r.stdout.strip() or "no PPM"))
    try:
        ppm_to_png(ppm, out)
    finally:
        try:
            os.remove(ppm)
        except OSError:
            pass


def capture_png_any(name, c, out, resume):
    """Screendump via whichever backend the tile actually uses.

    One dispatcher so `shot` and `assert` cannot drift apart — `assert` used to
    call the QMP path unconditionally, which cannot work on a tile that has no
    QMP monitor."""
    # A frozen guest's last frame IS its current screen, on either mechanism, so
    # `resume` stays the caller's choice rather than a requirement here: the
    # assert path deliberately passes False to compare two frames without
    # waking anything.
    if resume:
        ensure_running(c, name)
    if is_shm_tile(c, name):
        capture_png_shm(name, c, out)
    elif is_x11_tile(c):
        capture_png_x11(name, c, out)
    else:
        capture_png(name, c, out, resume=False)
