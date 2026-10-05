"""labctl reset for host-native MAME stations: the scene wait after a cold
relaunch, and the in-process Restore with fresh media."""

import os
import subprocess
import time


def scene_wait(tile_dir, env):
    """After a COLD relaunch, wait until the emulator is at its rest scene.

    The mame-native launcher writes <tile>/scene.state: `booting <pid>` at
    launch and `ready <pid>` once its standby freeze has landed on the scene.
    A relaunch is a boot, so an agent that types the moment `labctl reset`
    returns types into the boot (svi738's `MBASIC` vanished into the MSX
    banner, 2026-10-04). Same rule as serve/reset-tile.sh's scene_wait: no
    marker naming the new pid, or a scene delay over 90 s (newsos, palmos),
    means no wait; otherwise up to 3x the delay + 15 s, then return anyway.
    """

    def marker():
        try:
            with open(os.path.join(tile_dir, "scene.state")) as f:
                return (f.read().split() + ["", ""])[:2]
        except OSError:
            return ["", ""]

    try:
        with open(os.path.join(tile_dir, "mame.pid")) as f:
            pid = f.read().strip()
        delay = int(env.get("MAME_NATIVE_STANDBY_DELAY_S", "8"))
    except (OSError, ValueError):
        return ""
    if not pid or marker()[1] != pid or delay > 90:
        return ""
    t0 = time.monotonic()
    while time.monotonic() - t0 < 3 * delay + 15:
        st, spid = marker()
        if st == "ready" and spid == pid:
            return "scene ready in %.1f s" % (time.monotonic() - t0)
        time.sleep(0.2)
    return "scene NOT ready after %d s" % (3 * delay + 15)


def media_reset(tile_dir, sock, state):
    """In-process Restore of a station with MAME_NATIVE_DISK_TEMPLATE media.

    LOADST alone restores CPU, RAM and devices but leaves the visitor's disk
    (a saved file, a renamed icon) for the next visitor: no savestate carries a
    floppy's track data and a hard disk is the file itself (2026-10-05). The
    launcher's companion media-hook.sh pauses MAME, swaps fresh copies in,
    LOADSTs and resumes — the same path serve/reset-tile.sh takes — and only
    when <tile>/media-reset.armed names THIS emulator. Returns (ok, message);
    not ok means the caller relaunches, whose start copies fresh media anyway.
    The emulator must already be running (ensure_running): a SIGSTOPped one
    never reaches the hook's frame notifier.
    """
    try:
        with open(os.path.join(tile_dir, "mame.pid")) as f:
            epid = f.read().strip()
        with open(os.path.join(tile_dir, "media-reset.armed")) as f:
            armed = f.read().strip()
    except OSError:
        epid, armed = "", ""
    if not epid or armed != "armed " + epid:
        return False, "media hook not armed for pid %s" % (epid or "?")
    r = subprocess.run(
        ["bash", os.path.join(tile_dir, "media-hook.sh"), "--media-reset", tile_dir, sock, state],
        capture_output=True,
        text=True,
        timeout=150,
    )
    if r.returncode == 0:
        return True, r.stdout.strip()
    return False, "media reset failed (%s)" % (r.stdout or r.stderr).strip()
