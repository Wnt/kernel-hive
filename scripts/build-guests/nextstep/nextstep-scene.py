#!/usr/bin/env python3
"""Drive the host-native `nextstep` guest to its acceptance scene, headless.

Runs ON LABHOST against a RUNNING Previous (the station or a sandbox rig), using
only the two host-native planes: the IFB1 shm framebuffer and the mamectl/1
control socket. There is no X server and no window anywhere, so the kiosk-era
scripts/build-guests/nextstep-tablet-install.py (xdotool + QMP screendump) does
not apply; this is its replacement.

What the scene is, and why each part is here:

  * the SummaGraphics tablet ATTACHED AND STREAMING. /etc/rc.local loads the
    kernel server on every boot, but nothing puts the digitiser into stream mode
    except /NextAdmin/InstallTablet.app -- measured on the colour NeXTstation,
    2026-08-25 -- so a cold boot has a dead-reckoned pointer and the golden is
    what carries the absolute one. This script runs the app.
  * OmniWeb 2.7b3 OPEN on the corpus home page. The golden is a RAM image, so
    one launch before the bake is what every visitor sees forever after.
  * nothing else. No InstallTablet symlink, no torn-off menus, no panels.

Usage:  nextstep-scene.py [--shm P] [--ctl P] [--evidence DIR]
                          [--telnet-host H] [--telnet-port N]
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "lib"))
from guest_wake import WakeLease  # noqa: E402
from nextstep_rig import RETURN, Rig, log  # noqa: E402

# Probe points that miss the Install Tablet panel and the extreme corners, where
# NeXTSTEP swaps the arrow for an I-beam or clips the glyph and the locator --
# correctly -- finds nothing.
PROBE = [(8, 8), (1111, 823), (60, 760), (300, 700), (1000, 620), (900, 780)]


def attach_tablet(r):
    worst, _ = r.absolute_error(PROBE[:3])
    if worst is not None and worst <= 2:
        log(f"pointer already absolute (worst {worst} px)")
        return
    log("pointer is dead reckoned; running /NextAdmin/InstallTablet.app")
    r.guest("rm -f /me/InstallTablet.app", "ln -s /NextAdmin/InstallTablet.app /me/InstallTablet.app", "sync")
    # Refresh the listing with Workspace -> View -> Update Viewers, whose keyboard
    # equivalent is Command-u. The Workspace does NOT re-read a directory just
    # because its contents changed, and double-clicking the row to re-open it is
    # unreliable at this stage -- the injector's button-hold floor stretches a
    # double click far enough that NeXTSTEP sometimes scores it as two singles,
    # which selects the row without re-opening it and leaves the listing (and so
    # the type-select) silently one edit behind. Command-u needs no pointer at
    # all, which is the whole point before the tablet exists.
    box = None
    for attempt in range(4):
        r.command("u")
        time.sleep(3)
        r.type("Install")
        time.sleep(1.5)
        r.tap(RETURN)
        for _ in range(8):
            time.sleep(4)
            box = r.install_panel()
            if box:
                break
        if box:
            break
        log(f"no panel on attempt {attempt}; updating viewers and retrying")
    if not box:
        r.png("scene-FAIL-nopanel.png")
        raise SystemExit("the Install Tablet panel never appeared")
    x0, y0, x1, _y1 = box
    button = (x1 - 34, y0 - 70)
    log(f"panel {box}; Install button {button}")
    r.park()
    landed = r.walk(*button)
    if max(abs(landed[0] - button[0]), abs(landed[1] - button[1])) > 8:
        r.png("scene-FAIL-walk.png")
        raise SystemExit(f"could not put the pointer on the Install button: {landed}")
    r.click()
    time.sleep(25)
    worst, rows = r.absolute_error(PROBE)
    if worst is None or worst > 2:
        r.png("scene-FAIL-probe.png")
        raise SystemExit(f"tablet did not attach: worst={worst!r} rows={rows}")
    log(f"tablet attached; absolute pointer, worst error {worst} px over {len(PROBE)} targets")
    r.command("q")  # quit InstallTablet
    time.sleep(6)
    r.guest("rm -f /me/InstallTablet.app", "sync")
    r.command("u")  # Update Viewers: forget the symlink
    time.sleep(4)


# OmniWeb's toolbar Home button, in this window's own geometry.
HOME_BUTTON = (289, 188)
# The miniaturise box of OmniWeb's SampleBookmarks window.
BOOKMARKS_MINI = (17, 240)


def page_blank(r):
    """True when the content area is a sheet of white -- OmniWeb has chrome and
    a title but never painted the document."""
    band = r.fb.rgb()[260:650, 160:770]
    return bool((band == 255).all(axis=2).mean() > 0.97)


def wait_settled(r, tries=80):
    last = None
    stable = 0
    for _ in range(tries):
        time.sleep(4)
        sig = r.fb.rgb()[240:660, 150:780].tobytes()
        if sig == last:
            stable += 1
            if stable >= 3:
                return True
        else:
            stable = 0
            last = sig
    return False


def open_browser(r):
    """Launch OmniWeb by TYPE-SELECT, and make sure the home page actually
    arrives. The Workspace's File Viewer is fully type-selectable and this is the
    one leg that never needed a pointer."""
    r.type("omni")
    time.sleep(1.5)
    r.tap(RETURN)
    # Wait for the LOAD to finish, not for the window to appear: OmniWeb puts up
    # its chrome in seconds and then spends a minute on "SGMLToRTF: Waiting for
    # images" against the corpus, and a scene baked in that gap is a golden of a
    # half-drawn page, forever.
    if not wait_settled(r):
        log("WARNING: the page never stopped changing")
    # The FIRST load after a launch reliably stalls on this station -- the window
    # settles blank with the status line still reading "SGMLToRTF: Running" --
    # and pressing Home fetches it correctly every time. Measured repeatedly,
    # 2026-08-25; the corpus itself answers 200 to the same request throughout,
    # so this is the browser's own first-request behaviour, not the network's.
    for attempt in range(3):
        if not page_blank(r):
            log("home page rendered")
            break
        log(f"blank page after load (attempt {attempt}); pressing Home")
        r.click_at(*HOME_BUTTON)
        wait_settled(r)
    else:
        log("WARNING: the home page never rendered")
    # Miniaturise OmniWeb's SampleBookmarks window, which it opens at every
    # launch half off the left edge. Its miniaturise box is the small square at
    # the left end of its title bar; a miss lands on the empty desktop and does
    # nothing.
    r.click_at(*BOOKMARKS_MINI)
    time.sleep(3)


def main():
    ap = argparse.ArgumentParser()
    # $BASE/fb.shm, NOT $BASE/run/fb.shm: the launcher creates the mapping in the
    # station dir (where the emit puts SH_SHM_PATH and where the rest of the
    # fleet keeps it) and hands it over by owner; only the control socket, which
    # the emulator must bind itself, lives in the writable run dir.
    ap.add_argument("--shm", default="/data/vms/streamhost/stations/nextstep/fb.shm")
    ap.add_argument("--ctl", default="/data/vms/streamhost/stations/nextstep/run/ctl.sock")
    ap.add_argument("--evidence", default="/data/vms/streamhost/stations/nextstep/evidence")
    ap.add_argument("--telnet-host", default="10.99.0.25")
    ap.add_argument("--telnet-port", type=int, default=23)
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("--pidfile", default="/data/vms/streamhost/stations/nextstep/mame.pid")
    ap.add_argument(
        "--station",
        default="nextstep",
        help="hold this station's wake lease for the whole run; '' to skip. Without it the "
        "daemon's idle pauser SIGSTOPs the guest 60 s in and the scene stops half-built, "
        "with no error anywhere -- the framebuffer simply stops changing.",
    )
    a = ap.parse_args()
    if a.station:
        with WakeLease(a.station):
            return build(a)
    return build(a)


def wait_awake(pidfile, timeout=180):
    """Block until the emulator is not SIGSTOPped.

    The daemon's idle pauser freezes an unwatched station after 60 s, and the
    launcher freezes it a few seconds after every launch, so a driver that
    connects to the control socket the moment it is asked to will time out on
    the HELLO banner: the ctlsock thread is stopped with everything else, the
    socket is there, and nothing ever answers. The wake lease this runs under
    releases the guest, but only on the daemon's own 5 s reconcile tick.
    """
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            with open(pidfile) as fh:
                pid = int(fh.read().strip())
            with open(f"/proc/{pid}/stat") as fh:
                state = fh.read().rsplit(") ", 1)[1].split(" ", 1)[0]
        except (OSError, ValueError, IndexError):
            time.sleep(2)
            continue
        if state != "T":
            if time.time() - t0 > 2:
                log(f"guest awake after {time.time() - t0:.0f}s")
            return True
        time.sleep(2)
    log("WARNING: the guest is still SIGSTOPped; is the wake lease reaching the daemon?")
    return False


def build(a):
    if a.pidfile:
        wait_awake(a.pidfile)
    r = Rig(a.shm, a.ctl, a.evidence, (a.telnet_host, a.telnet_port))
    if not r.wait_workspace():
        r.png("scene-FAIL-noworkspace.png")
        raise SystemExit("no NeXTSTEP Workspace on the framebuffer")
    attach_tablet(r)
    if not a.no_browser:
        open_browser(r)
    r.c.cmd("MOVEA 560 760")  # park off every window
    time.sleep(1)
    log("scene: " + r.png("scene.png"))
    r.c.close()  # a bake cannot dump a connected client
    log("PASS")


if __name__ == "__main__":
    main()
