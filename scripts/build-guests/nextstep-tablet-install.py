#!/usr/bin/env python3
"""Attach the NeXTSTEP tablet driver in the `nextstep` tile, and prove it 1:1.

Runs ON THE LAB BOX against a *running* nextstep QEMU (the tile or a
/data/vms/soltest clone). Called by scripts/build-guests/nextstep.sh between the
last cold boot and `savevm golden`; safe to re-run by hand after any COLD boot,
which is the one state that loses the driver (see docs/guests/nextstep.md §4).

Why this exists at all: Previous emulates a SummaGraphics digitiser on the NeXT
SCC serial port B and feeds it the host's ABSOLUTE window coordinates whenever
`[Tablet] nTabletType` is non-zero AND the guest has a tablet driver attached.
NeXTSTEP 3.3 ships that driver in /NextAdmin/InstallTablet.app, but the app is
GUI-only: NeXTSTEP refuses a DPS connection from a telnet session ("Could not
form connection"), so the install has to be driven through the framebuffer.
Nothing is compiled -- the golden carries no m68k toolchain.

The driver survives `loadvm golden` (RAM + device state, not a boot), which is
why the exhibit's reset model fits; it does NOT survive a cold boot.

Usage: nextstep-tablet-install.py [--dir DIR] [--ssh-port N] [--key PATH]
"""

import argparse
import subprocess
import time

import numpy as np

W, H = 1120, 832
# The NeXT arrow's exact 11x16 glyph, as (dx, dy, white?) samples. The display is
# 2-bit greyscale, so every pixel is one of 0/85/170/255 and the 96 glyph pixels
# that are 0 or 255 form an exact, background-independent template.
# fmt: off
SIG = [
    (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 0), (2, 1, 1), (0, 2, 1),
    (1, 2, 0), (2, 2, 0), (3, 2, 1), (0, 3, 1), (1, 3, 0), (2, 3, 0),
    (3, 3, 0), (4, 3, 1), (0, 4, 1), (1, 4, 0), (2, 4, 0), (3, 4, 0),
    (4, 4, 0), (5, 4, 1), (0, 5, 1), (1, 5, 0), (2, 5, 0), (3, 5, 0),
    (4, 5, 0), (5, 5, 0), (6, 5, 1), (0, 6, 1), (1, 6, 0), (2, 6, 0),
    (3, 6, 0), (4, 6, 0), (5, 6, 0), (6, 6, 0), (7, 6, 1), (0, 7, 1),
    (1, 7, 0), (2, 7, 0), (3, 7, 0), (4, 7, 0), (5, 7, 0), (6, 7, 0),
    (7, 7, 0), (8, 7, 1), (0, 8, 1), (1, 8, 0), (2, 8, 0), (3, 8, 0),
    (4, 8, 0), (5, 8, 0), (6, 8, 0), (7, 8, 0), (8, 8, 0), (9, 8, 1),
    (0, 9, 1), (1, 9, 0), (2, 9, 0), (3, 9, 0), (4, 9, 0), (5, 9, 0),
    (6, 9, 1), (7, 9, 1), (8, 9, 1), (9, 9, 1), (10, 9, 1), (0, 10, 1),
    (1, 10, 0), (2, 10, 0), (3, 10, 1), (4, 10, 0), (5, 10, 0), (6, 10, 1),
    (0, 11, 1), (1, 11, 0), (2, 11, 1), (4, 11, 1), (5, 11, 0), (6, 11, 0),
    (7, 11, 1), (0, 12, 1), (1, 12, 1), (4, 12, 1), (5, 12, 0), (6, 12, 0),
    (7, 12, 1), (0, 13, 1), (5, 13, 1), (6, 13, 0), (7, 13, 0), (8, 13, 1),
    (5, 14, 1), (6, 14, 0), (7, 14, 0), (8, 14, 1), (6, 15, 1), (7, 15, 1),
]
# fmt: on
# The Dock clock repaints on its own; never diff it.
CLOCK = (1030, 0, W, 140)
# The `me` house icon on the File Viewer's shelf, in the fixture's own layout.
SHELF_HOME = (208, 70)
ARGS = argparse.Namespace()
# Resolve the kiosk's X display from the SERVER's own command line rather than
# assuming :0. A restarted kiosk session can come up on :1 while the old server
# drains, and every xdotool call then goes somewhere harmless and silent -- which
# reads exactly like "the guest ignores input".
XENV = (
    'X=$(ps -eo args= | grep -m1 "[X]org "); '
    "export DISPLAY=$(echo \"$X\" | grep -o ' :[0-9]*' | head -1 | tr -d ' '); "
    "export XAUTHORITY=$(echo \"$X\" | sed -n 's/.*-auth \\([^ ]*\\).*/\\1/p'); "
)


def log(msg):
    print("[tablet {}] {}".format(time.strftime("%H:%M:%S"), msg), flush=True)


def kiosk(cmd):
    """Run a command on the Debian kiosk with its X display in the environment."""
    out = subprocess.run(
        [
            "ssh",
            "-i",
            ARGS.key,
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "ConnectTimeout=8",
            "-p",
            str(ARGS.ssh_port),
            "root@127.0.0.1",
            XENV + cmd,
        ],
        capture_output=True,
        text=True,
    )
    return out.stdout.strip()


def nextstep(*cmds):
    """Run shell commands INSIDE NeXTSTEP over the kiosk-side telnet redirection."""
    quoted = " ".join('"{}"'.format(c.replace('"', '\\"')) for c in cmds)
    return kiosk("python3 /usr/local/bin/nstel.py me " + quoted)


def frame(name):
    """QMP screendump -> the 1120x832 greyscale plane as a numpy array."""
    path = f"{ARGS.evidence}/{name}.ppm"
    subprocess.run(
        ["python3", "/root/qmp_hmp.py", ARGS.dir + "/qmp.sock", "screendump " + path], capture_output=True, check=False
    )
    with open(path, "rb") as fh:
        data = fh.read()
    px = np.frombuffer(data[data.index(b"255\n") + 4 :], dtype=np.uint8)
    return px[0::3].reshape(H, W)


def locate(img):
    """Every position whose pixels match the arrow glyph. Exactly one, in practice."""
    ok = np.ones((H, W), dtype=bool)
    seen = np.zeros((H, W), dtype=np.int16)
    for dx, dy, white in SIG:
        seen[: H - dy, : W - dx] += 1
        sub = np.zeros((H, W), dtype=bool)
        sub[: H - dy, : W - dx] = img[dy:, dx:] == (255 if white else 0)
        sub[H - dy :, :] = True  # samples off the bottom edge cannot disagree
        sub[:, W - dx :] = True  # ... nor off the right edge
        ok &= sub
    # A clipped glyph shows fewer sample points; 30 is still far more evidence
    # than any static element of this desktop provides.
    ok &= seen >= 30
    ys, xs = np.nonzero(ok)
    return [(int(x) + 1, int(y) + 1) for x, y in zip(xs, ys)]


def cursor(name="probe"):
    hits = locate(frame(name))
    if len(hits) != 1:
        raise SystemExit(f"cursor locator saw {len(hits)} candidates: {hits[:6]}")
    return hits[0]


# Three measured properties of this relative path shape the controller below.
# (1) The NeXT KMS mouse register carries a SIGNED 6-BIT delta, so one event can
#     move the cursor at most 63 px and anything larger is truncated -- which
#     makes a proportional controller with big steps estimate a nonsense gain.
# (2) NeXTSTEP's acceleration curve has a DEAD ZONE that is not symmetric: a
#     step of -24 in y moved the cursor not at all, while -1 in x moved it 1:1.
#     So the loop must never need to come back UP -- it approaches every target
#     from the top-left park and damps its steps so it cannot overshoot.
# (3) A relative warp is delivered by moving the KIOSK's X pointer, which X
#     clamps at the screen edge: a loop that drifts into an edge stops moving
#     while still reporting a position. The host position is tracked.
STEP_CAP = 24


def park():
    """Walk BOTH cursors into the top-left corner, in steps under the 63 px clamp.

    A single big warp cannot do it: the KMS register saturates at 63 px, so one
    `mousemove 0 0` moves the guest arrow 63 px and no further, however far the
    host pointer went. Twenty short steps walk it all the way out instead.
    """
    steps = " ".join("mousemove_relative --sync -- -56 -56 sleep 0.04" for _ in range(22))
    # ... and then 8 px back in, because an arrow parked exactly at 0,0 has its
    # glyph origin off-screen and the locator (rightly) refuses to see it.
    kiosk("xdotool mousemove 1119 831 sleep 0.1 " + steps + " sleep 0.1 mousemove_relative --sync -- 8 8")
    time.sleep(0.8)


def goto(tx, ty, tol=3, iters=60, parks=4):
    """Walk the RELATIVE (pre-driver) pointer onto a target, closing the loop on
    the framebuffer. Returns where it actually landed; the caller checks."""
    cx = cy = -1
    for attempt in range(parks):
        damp = (0.6, 0.45, 0.3, 0.2)[attempt]
        park()
        hostx = hosty = 0
        gain_x = gain_y = 1.3
        cx, cy = cursor()
        overshot = False
        for _ in range(iters):
            ex, ey = tx - cx, ty - cy
            if abs(ex) <= tol and abs(ey) <= tol:
                return cx, cy
            if ex < -tol or ey < -tol:
                overshot = True  # past the target: only a re-park recovers
                break
            dx = min(STEP_CAP, max(0, int(round(ex * damp / gain_x)))) or (1 if ex > tol else 0)
            dy = min(STEP_CAP, max(0, int(round(ey * damp / gain_y)))) or (1 if ey > tol else 0)
            dx = min(dx, W - 1 - hostx)
            dy = min(dy, H - 1 - hosty)
            if dx == 0 and dy == 0:
                break  # host pinned against an edge: re-park and try again
            kiosk(f"xdotool mousemove_relative --sync -- {dx} {dy}")
            hostx += dx
            hosty += dy
            time.sleep(0.35)
            nx, ny = cursor()
            if dx and nx != cx:
                gain_x = max(0.2, abs(nx - cx) / float(dx))
            if dy and ny != cy:
                gain_y = max(0.2, abs(ny - cy) / float(dy))
            cx, cy = nx, ny
        if not overshot and abs(tx - cx) <= tol and abs(ty - cy) <= tol:
            return cx, cy
    return cx, cy


def workspace_ready(name):
    """The grey Workspace, edge to edge: not the white ROM/panic page, not a bare
    root, not the small boot panel on an otherwise dark screen."""
    img = frame(name)
    # The mid-grey test alone is not enough: NeXTSTEP's boot panel sits on a
    # full-screen grey that passes it, and a run that typed into that gap found
    # no app and no error. The Workspace menu's black title block is the tell.
    if np.count_nonzero(img[2:19, 2:90] < 40) < 0.5 * 17 * 88:
        return False
    grey = int(np.count_nonzero((img >= 70) & (img <= 190)))
    white = int(np.count_nonzero(img > 200))
    dark = int(np.count_nonzero(img < 32))
    return grey > 419000 and white < 300000 and dark < 60000


def wait_workspace(name, timeout=600):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if workspace_ready(name):
            return True
        time.sleep(10)
    return False


def install_panel():
    """Bounding box of the Install Tablet panel's white Status view, or None.

    The panel is placed by NeXTSTEP, not by us, so its buttons are found relative
    to the one landmark that is unmistakable at this depth: a ~440x270 block of
    pure white in a desktop that is otherwise mid-grey.
    """
    img = frame("panel")
    rows = np.count_nonzero(img == 255, axis=1)
    hit = rows > 380
    # The Dock's own icons put a few isolated wide-white rows near the top, so
    # take the longest CONTIGUOUS run rather than first-to-last: a run spanning
    # them made the column test straddle the desktop and find nothing.
    best = run = 0
    end = -1
    for y in range(H):
        run = run + 1 if hit[y] else 0
        if run > best:
            best, end = run, y
    if best < 150:
        return None
    y0, y1 = end - best + 1, end
    cols = np.count_nonzero(img[y0 : y1 + 1] == 255, axis=0)
    xs = np.nonzero(cols > (y1 - y0) * 0.8)[0]
    if xs.size < 300:
        return None
    return int(xs[0]), y0, int(xs[-1]), y1


def absolute_ok(tag):
    """One commanded absolute move per probe point, then read the framebuffer."""
    worst = 0
    # Probe points chosen to miss the Install Tablet panel: NeXTSTEP swaps the
    # arrow for an I-beam over a text view, and the panel's Status view is one --
    # the glyph locator (correctly) finds nothing there.
    for tx, ty in ((8, 8), (1111, 823), (60, 760)):
        kiosk(f"xdotool mousemove {tx} {ty}")
        time.sleep(0.25)
        hits = locate(frame(f"{tag}-{tx}-{ty}"))
        if len(hits) != 1:
            return None
        worst = max(worst, abs(hits[0][0] - tx), abs(hits[0][1] - ty))
    return worst


def diff_px(before, after):
    """Pixels that changed, ignoring the self-ticking Dock clock."""
    changed = before != after
    x0, y0, x1, y1 = CLOCK
    changed[y0:y1, x0:x1] = False
    return int(np.count_nonzero(changed))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", default="/data/vms/streamhost/tiles/nextstep")
    parser.add_argument("--ssh-port", type=int, default=5837)
    parser.add_argument("--key", default="/data/vms/bridge/bridge_key")
    parser.add_argument("--evidence", default=None)
    parser.parse_args(namespace=ARGS)
    if ARGS.evidence is None:
        ARGS.evidence = ARGS.dir + "/evidence"

    if "nTabletType = 0" in kiosk("cat /home/bridge/.config/previous/previous.cfg"):
        raise SystemExit("previous.cfg still has nTabletType = 0; nothing to attach to")
    if not wait_workspace("tablet-00-workspace"):
        raise SystemExit("no NeXTSTEP Workspace on the framebuffer")

    pristine = frame("tablet-01-pristine")

    # The app lives in /NextAdmin, which the File Viewer is not showing, so link it
    # into the home directory: one type-select away. The Workspace only rescans a
    # directory it re-opens, and re-opening it means double-clicking the `me` icon
    # on the shelf -- which is why this needs a working pointer BEFORE the driver
    # exists, and why the relative closed loop below is not optional.
    #
    # Do NOT reboot NeXTSTEP to force the rescan instead. Previous keeps its own
    # `bTabletEnabled` across a GUEST reboot, so a rebooted guest has no driver
    # while the emulator is still routing every motion to tablet_pen_move(): the
    # cursor freezes completely and nothing can be clicked. (Same trap live: if
    # anyone ever reboots NeXTSTEP inside the exhibit, reset the tile to golden.)
    log("linking InstallTablet.app into /me and re-opening the home directory")
    nextstep(
        "rm -f /me/InstallTablet.app",
        "ln -s /NextAdmin/InstallTablet.app /me/InstallTablet.app",
        "sync",
    )
    landed = goto(*SHELF_HOME)
    if max(abs(landed[0] - SHELF_HOME[0]), abs(landed[1] - SHELF_HOME[1])) > 8:
        raise SystemExit(f"could not reach the shelf home icon: {landed} vs {SHELF_HOME}")
    kiosk("xdotool click --repeat 2 --delay 90 1")
    time.sleep(4)

    # Type-select in the File Viewer, then RETURN opens the selection. RETURN can
    # do no more than that: the app's panel never becomes the key window, so its
    # default button cannot be reached from the keyboard.
    log("opening InstallTablet.app from the File Viewer")
    box = None
    for _ in range(4):
        kiosk("xdotool type --delay 120 Install")
        time.sleep(1.5)
        kiosk("xdotool key Return")
        for _ in range(8):
            time.sleep(5)
            box = install_panel()
            if box:
                break
        if box:
            break
    if not box:
        raise SystemExit("the Install Tablet panel never appeared")
    x0, y0, x1, _y1 = box
    button = (x1 - 34, y0 - 70)  # the panel's "Install" button, relative to Status
    log(f"Install Tablet panel at {box}; Install button at {button}")

    landed = goto(*button)
    log(f"pointer walked to {landed} (relative closed loop)")
    if max(abs(landed[0] - button[0]), abs(landed[1] - button[1])) > 8:
        raise SystemExit(f"could not put the pointer on the Install button: {landed} vs {button}")
    kiosk("xdotool click 1")
    time.sleep(25)
    worst = absolute_ok("tablet-03-probe")
    if worst is None or worst > 2:
        frame("tablet-03-FAILED")
        raise SystemExit(f"tablet did not attach: absolute probe error {worst!r}")
    log(f"driver attached; absolute probe max error {worst} px")

    # Leave the machine on the fixture it was on: quit the app (its menu is pinned
    # at the top left while it is active), drop the symlink, and re-open /me so the
    # File Viewer forgets it ever existed.
    kiosk("xdotool mousemove 30 71; sleep 0.3; xdotool click 1")
    time.sleep(4)
    nextstep("rm -f /me/InstallTablet.app")
    kiosk(f"xdotool mousemove {SHELF_HOME[0]} {SHELF_HOME[1]}; sleep 0.3; xdotool click --repeat 2 --delay 90 1")
    time.sleep(4)
    kiosk("xdotool mousemove 103 105")
    time.sleep(1)
    after = frame("tablet-04-restored")
    delta = diff_px(pristine, after)
    if delta > 4000:
        raise SystemExit(f"desktop is not back on its fixture: {delta} pixels differ")
    log(f"desktop restored to the fixture ({delta} px differ, cursor included)")
    log("PASS: tablet attached, pointer absolute, fixture intact")


main()
