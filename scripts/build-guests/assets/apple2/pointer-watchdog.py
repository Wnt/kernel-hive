#!/usr/bin/env python3
"""apple2 bridge tile — in-guest pointer-wedge watchdog.

WHY: after multi-day continuous runtime the kiosk's Xorg stops applying
usb-tablet events — the kernel keeps receiving EV_ABS on the tablet's evdev
node while the X core pointer freezes (diagnosed 2026-07-12; ranked suspect is
systemd-logind pausing the libinput fd without a resume, but the X-internal
mechanism is unconfirmed). Restarting the kiosk (Xorg + linapple) clears it
instantly, so this watchdog detects the frozen-pointer condition and performs
that same restart, making the tile self-healing.

DETECTION (deliberately conservative — must never fire on a healthy session):
every SAMPLE_SECS we drain the tablet's raw evdev stream (a second reader does
not disturb Xorg's own evdev client) and sample the X core pointer position via
xdotool. We declare a wedge ONLY when, across WINDOW_TICKS consecutive samples:
  * the kernel saw >= EVENTS_MIN ABS events with >= DISTINCT_MIN distinct
    values spanning >= SPAN_MIN raw units on BOTH axes (i.e. a user/SPA is
    genuinely sweeping the pointer around), AND
  * the X pointer position was IDENTICAL in every sample.
A healthy X follows the tablet, so any applied motion breaks the condition;
an idle tile produces no kernel events and never triggers.

RECOVERY: log to /var/log/pointer-watchdog.log, restart the kiosk
(getty@tty1 respawn -> startx -> linapple cold boot), then best-effort dismiss
the two documented GEOS cold-boot dialogs (Return, then any key — see
docs/guests/apple2.md) so the tile returns to a usable deskTop. A long
cooldown prevents restart loops.

Runs as root (systemd unit pointer-watchdog.service), python3 stdlib +
xdotool only. Baked into the golden snapshot by scripts/build-guests/apple2.sh.
"""

import collections
import contextlib
import glob
import os
import re
import struct
import subprocess
import time

SAMPLE_SECS = 10  # tick interval
WINDOW_TICKS = 6  # consecutive samples that must all agree (60 s)
EVENTS_MIN = 20  # min raw ABS events in the window
DISTINCT_MIN = 3  # min distinct ABS values per axis in the window
SPAN_MIN = 800  # min (max-min) raw span per axis (tablet range 0..32767)
COOLDOWN_SECS = 900  # no re-trigger for 15 min after a recovery
BOOT_WAIT_SECS = 50  # kiosk restart -> GEOS boot dialogs on screen
LOG = "/var/log/pointer-watchdog.log"
TABLET_NAME = "QEMU QEMU USB Tablet"

EV_ABS, ABS_X, ABS_Y = 0x03, 0x00, 0x01
EVENT_FMT = "llHHi"  # struct input_event on 64-bit Linux
EVENT_SIZE = struct.calcsize(EVENT_FMT)


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def find_tablet_node():
    """Resolve the usb-tablet's /dev/input/eventN from /proc/bus/input/devices."""
    try:
        with open("/proc/bus/input/devices") as f:
            blocks = f.read().split("\n\n")
    except OSError:
        return None
    for b in blocks:
        if TABLET_NAME in b:
            m = re.search(r"Handlers=.*\b(event\d+)\b", b)
            if m:
                return "/dev/input/" + m.group(1)
    return None


def find_x_env():
    """DISPLAY + XAUTHORITY from the running Xorg's own cmdline (-auth file)."""
    for cmdline in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(cmdline, "rb") as f:
                argv = f.read().split(b"\0")
        except OSError:
            continue
        if not argv or b"Xorg" not in argv[0]:
            continue
        args = [a.decode("utf-8", "replace") for a in argv]
        display = next((a for a in args if re.fullmatch(r":\d+", a)), None)
        auth = None
        for i, a in enumerate(args):
            if a == "-auth" and i + 1 < len(args):
                auth = args[i + 1]
        if display:
            env = dict(os.environ, DISPLAY=display)
            if auth:
                env["XAUTHORITY"] = auth
            return env
    return None


def query_pointer(env):
    """(x, y) of the X core pointer, or None if X is unreachable."""
    try:
        out = subprocess.run(
            ["xdotool", "getmouselocation"],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    m = re.search(r"x:(\d+) y:(\d+)", out.stdout)
    return (int(m.group(1)), int(m.group(2))) if m else None


def xdo(env, *args):
    with contextlib.suppress(subprocess.TimeoutExpired, OSError):
        subprocess.run(["xdotool"] + list(args), env=env, capture_output=True, timeout=5)


def drain_events(fd):
    """Non-blocking drain; returns (abs_x_values, abs_y_values) lists."""
    xs, ys = [], []
    while True:
        try:
            buf = os.read(fd, EVENT_SIZE * 64)
        except BlockingIOError:
            break
        if not buf:
            break
        for off in range(0, len(buf) - EVENT_SIZE + 1, EVENT_SIZE):
            _, _, etype, code, value = struct.unpack_from(EVENT_FMT, buf, off)
            if etype == EV_ABS:
                if code == ABS_X:
                    xs.append(value)
                elif code == ABS_Y:
                    ys.append(value)
    return xs, ys


def axis_varied(vals):
    return len(set(vals)) >= DISTINCT_MIN and max(vals) - min(vals) >= SPAN_MIN


def restart_kiosk():
    log("WEDGE CONFIRMED -> restarting kiosk (getty@tty1)")
    subprocess.run(["systemctl", "reset-failed", "getty@tty1"], capture_output=True)
    subprocess.run(["systemctl", "restart", "getty@tty1"], capture_output=True)
    time.sleep(BOOT_WAIT_SECS)
    # Best-effort: dismiss the two GEOS cold-boot dialogs (docs/guests/apple2.md).
    env = find_x_env()
    if env:
        xdo(env, "mousemove", "512", "384")  # PointerRoot focus onto the SDL window
        xdo(env, "key", "Return")  # "No interrupt source found"
        time.sleep(4)
        xdo(env, "key", "space")  # "No mouse card found"
        log("kiosk restarted, GEOS boot dialogs dismissed (best-effort)")
    else:
        log("kiosk restarted, but X not found for dialog dismissal")


def main():
    log(f"pointer-watchdog starting (window={WINDOW_TICKS * SAMPLE_SECS}s, cooldown={COOLDOWN_SECS}s)")
    window = collections.deque(maxlen=WINDOW_TICKS)
    fd, node, cooldown_until = None, None, 0.0
    while True:
        time.sleep(SAMPLE_SECS)
        if fd is None:
            node = find_tablet_node()
            if node is None:
                window.clear()
                continue
            try:
                fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
                log(f"watching tablet node {node}")
            except OSError as e:
                log(f"cannot open {node}: {e}")
                fd = None
                continue
        try:
            xs, ys = drain_events(fd)
        except OSError:
            os.close(fd)
            fd = None
            window.clear()
            continue
        env = find_x_env()
        pos = query_pointer(env) if env else None
        if pos is None:
            window.clear()  # X down/restarting — never judge without a pointer fix
            continue
        window.append((xs, ys, pos))
        if time.time() < cooldown_until or len(window) < WINDOW_TICKS:
            continue
        all_x = [v for w in window for v in w[0]]
        all_y = [v for w in window for v in w[1]]
        positions = {w[2] for w in window}
        if (
            len(positions) == 1
            and len(all_x) + len(all_y) >= EVENTS_MIN
            and all_x
            and axis_varied(all_x)
            and all_y
            and axis_varied(all_y)
        ):
            log(
                f"frozen pointer at {pos} while kernel saw {len(all_x) + len(all_y)} ABS events "
                f"(x span {min(all_x)}..{max(all_x)}, y span {min(all_y)}..{max(all_y)}) "
                f"over {WINDOW_TICKS * SAMPLE_SECS}s"
            )
            restart_kiosk()
            window.clear()
            cooldown_until = time.time() + COOLDOWN_SECS


if __name__ == "__main__":
    main()
