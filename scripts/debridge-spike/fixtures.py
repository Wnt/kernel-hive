#!/usr/bin/env python3
"""De-bridging spike: park the GEM pointer and validate the three fixtures on
either arm, proving each with a real framebuffer capture.

WHY THERE IS A CLOSED LOOP HERE. MAME emulates the ST mouse as a QUADRATURE
encoder (src/mame/atari/stkbd.cpp): a 500 Hz tick latches the axis ioport every
4 ticks, keeps only the DIRECTION of the change and emits one step per latch.
So the magnitude of any burst is discarded, and on top of that TOS applies its
own pointer acceleration -- measured here at roughly 4 surface pixels per
delivered count. Open-loop dead reckoning therefore cannot place this pointer,
and that is a property of the MACHINE, not of either arm: arm A feeds the same
8-bit axis through SDL and is throttled identically. Both arms are driven
through the same closed loop below so neither gets an advantage.

  fixtures.py <armA|armB> park          -- corner-park + reference frame
  fixtures.py <armA|armB> goto <x> <y>  -- closed-loop move, surface pixels
  fixtures.py <armA|armB> validate      -- all three fixtures + evidence PNGs
"""

import json
import socket
import subprocess
import sys
import time

RIG = "/data/vms/soltest/debridge-7f3a"
EV = RIG + "/evidence"
BENCH = {"armB": ("127.0.0.1", 57932)}
SHMPNG = "/data/vms/soltest/drawshm-9c1e/shmpng.py"
SURF = (1024, 768)

# Where things are on the published surface, read off a real capture.
DESKTOP = (500, 400)  # empty green desktop, away from icons and the menu bar
MENU_OPTIONS = (585, 74)  # the "Options" title in the menu bar
UNDER_MENU = (585, 150)  # directly below it, on the desktop
ICON_DISKA = (200, 155)  # the DISK A icon cell
ICON_CLEAR = (200, 330)  # empty desktop below it: a click here deselects


def state_path(arm):
    return f"{RIG}/{arm}/ptr.json"


def load_state(arm):
    try:
        with open(state_path(arm)) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"tx": 512, "ty": 384}


def save_state(arm, st):
    with open(state_path(arm), "w") as fh:
        json.dump(st, fh)


def bench(arm, lines, settle=0.3):
    host, port = BENCH[arm]
    with socket.create_connection((host, port), timeout=5) as s:
        for line in lines:
            s.sendall((line + "\n").encode())
            time.sleep(0.03)
    time.sleep(settle)


def qmp_abs(x, y):
    subprocess.run(
        [
            "python3",
            "/root/cdrv.py",
            RIG + "/armA/qmp.sock",
            "abs",
            str(int(x * 32767 / (SURF[0] - 1))),
            str(int(y * 32767 / (SURF[1] - 1))),
        ],
        check=True,
        capture_output=True,
    )


def qmp_btn(down):
    import json as _json

    ev = {
        "execute": "input-send-event",
        "arguments": {"events": [{"type": "btn", "data": {"button": "left", "down": down}}]},
    }
    s = socket.socket(socket.AF_UNIX)
    s.connect(RIG + "/armA/qmp.sock")
    f = s.makefile("rw")
    f.readline()
    f.write(_json.dumps({"execute": "qmp_capabilities"}) + "\n")
    f.flush()
    f.readline()
    f.write(_json.dumps(ev) + "\n")
    f.flush()
    f.readline()
    s.close()


def nudge(arm, dx, dy, settle=0.06):
    """One pointer step of (dx, dy) in the arm's own command space."""
    st = load_state(arm)
    st["tx"] = max(0, min(SURF[0] - 1, st["tx"] + dx))
    st["ty"] = max(0, min(SURF[1] - 1, st["ty"] + dy))
    if arm == "armB":
        bench(arm, [f"M {st['tx']} {st['ty']}"], settle=settle)
    else:
        qmp_abs(st["tx"], st["ty"])
        time.sleep(settle)
    save_state(arm, st)


def walk(arm, dx, dy, step=4, gap=0.03):
    """Many small steps. A single big jump delivers ONE quadrature step -- the
    magnitude is thrown away by the device -- so distance is walked, not sent."""
    n = max(abs(dx), abs(dy)) // step + 1
    sx = dx / n
    sy = dy / n
    for _ in range(int(n)):
        nudge(arm, round(sx), round(sy), settle=gap)


def button(arm, down):
    if arm == "armB":
        st = load_state(arm)
        verb = "D" if down else "U"
        bench(arm, [f"{verb} {st['tx']} {st['ty']}"], settle=0.12)
    else:
        qmp_btn(down)
        time.sleep(0.12)


def shot(arm, out):
    if arm == "armB":
        subprocess.run(["python3", SHMPNG, RIG + "/armB/fb.shm", out], check=True, capture_output=True)
    else:
        ppm = "/tmp/fx-armA.ppm"
        subprocess.run(
            ["python3", "/root/cdrv.py", RIG + "/armA/qmp.sock", "dump", ppm],
            check=True,
            capture_output=True,
        )
        subprocess.run(["convert", ppm, out], check=True)
    return out


def raw(path):
    data = subprocess.run(
        ["convert", path, "-depth", "8", "-colorspace", "sRGB", "rgb:-"],
        check=True,
        capture_output=True,
    ).stdout
    return SURF[0], SURF[1], data


def diff(ref, cur, exclude=None):
    w, h, a = raw(ref)
    _, _, b = raw(cur)
    xs = ys = n = 0
    x0 = y0 = 10**9
    x1 = y1 = -1
    for y in range(h):
        base = y * w * 3
        for x in range(w):
            o = base + x * 3
            if abs(a[o] - b[o]) > 40 or abs(a[o + 1] - b[o + 1]) > 40 or abs(a[o + 2] - b[o + 2]) > 40:
                if exclude and exclude[0] <= x < exclude[2] and exclude[1] <= y < exclude[3]:
                    continue
                xs += x
                ys += y
                n += 1
                x0 = min(x0, x)
                y0 = min(y0, y)
                x1 = max(x1, x)
                y1 = max(y1, y)
    if n == 0:
        return None
    return {
        "centroid": (round(xs / n, 1), round(ys / n, 1)),
        "bbox": (x0, y0, x1, y1),
        "changed": n,
        "pct": round(100.0 * n / (w * h), 3),
    }


CORNER = (860, 640, 1024, 768)


def park(arm):
    """Drive into the bottom-right clamp and keep that frame as the reference:
    every later locate() is a diff against it, so the cursor is the only thing
    that can have moved."""
    walk(arm, 1200, 1200, step=6, gap=0.03)
    time.sleep(1.5)
    ref = shot(arm, f"{RIG}/{arm}/ptr-ref.png")
    return ref


def locate(arm, ref):
    cur = shot(arm, f"/tmp/fx-{arm}-loc.png")
    return diff(ref, cur, exclude=CORNER)


def goto(arm, tx, ty, ref, tol=14, tries=18):
    """Closed loop, with SEPARATE per-axis gains and a per-step travel cap.

    The two axes are nothing like each other: the ST's 640x200 raster is
    letterboxed into 1024x768, so one delivered count is ~4 surface px across
    and ~12.8 down. A single shared gain sent the pointer through the menu bar
    on the first correction and dropped a menu, which then swamped the locator.
    The cap is on PREDICTED TRAVEL rather than on counts, for the same reason.
    """
    gain = [4.0, 12.0]
    last = None
    for _ in range(tries):
        blob = locate(arm, ref)
        if blob is None:
            walk(arm, -3, -3, step=3)
            time.sleep(0.4)
            continue
        if blob["changed"] > 3000:
            # A menu is open (hover-activated): the locator cannot see the
            # cursor through it. Step off the menu bar and look again.
            walk(arm, 0, 4, step=2, gap=0.05)
            time.sleep(0.9)
            last = None
            continue
        px, py = blob["centroid"]
        ex, ey = tx - px, ty - py
        if abs(ex) <= tol and abs(ey) <= tol:
            return blob
        if last is not None:
            for axis, (moved, issued) in enumerate(((px - last[0], last[2][0]), (py - last[1], last[2][1]))):
                if issued and abs(moved) > 2:
                    gain[axis] = max(0.8, min(20.0, abs(moved / issued)))
        step = [int(round(ex / gain[0])), int(round(ey / gain[1]))]
        for axis, err in ((0, ex), (1, ey)):
            cap = max(1, int(120 / gain[axis]))
            step[axis] = max(-cap, min(cap, step[axis]))
            if step[axis] == 0 and abs(err) > tol:
                step[axis] = 1 if err > 0 else -1
        last = (px, py, tuple(step))
        walk(arm, step[0], step[1], step=2, gap=0.05)
        time.sleep(0.6)
    return locate(arm, ref)


def validate(arm):
    out = {}
    ref = park(arm)
    print(f"parked; reference {ref}")

    # ---- fixture 1: cursor motion on empty desktop, minimum damage ----------
    goto(arm, DESKTOP[0], DESKTOP[1], ref)
    time.sleep(0.8)
    a = shot(arm, f"{EV}/{arm}-fx1-a.png")
    walk(arm, 14, 0, step=3, gap=0.04)
    time.sleep(0.8)
    b = shot(arm, f"{EV}/{arm}-fx1-b.png")
    out["fixture1_cursor"] = diff(a, b)
    print("fx1", out["fixture1_cursor"])

    # ---- fixture 3: Options menu drops on hover ----------------------------
    goto(arm, UNDER_MENU[0], UNDER_MENU[1], ref)
    time.sleep(0.8)
    c = shot(arm, f"{EV}/{arm}-fx3-closed.png")
    goto(arm, MENU_OPTIONS[0], MENU_OPTIONS[1], ref, tol=18)
    time.sleep(1.0)
    d = shot(arm, f"{EV}/{arm}-fx3-open.png")
    out["fixture3_menu"] = diff(c, d)
    print("fx3", out["fixture3_menu"])

    # ---- fixture 2: click an icon -> it inverts to black --------------------
    goto(arm, ICON_CLEAR[0], ICON_CLEAR[1], ref)
    button(arm, True)
    button(arm, False)
    time.sleep(0.8)
    e = shot(arm, f"{EV}/{arm}-fx2-before.png")
    goto(arm, ICON_DISKA[0], ICON_DISKA[1], ref, tol=10)
    time.sleep(0.6)
    button(arm, True)
    button(arm, False)
    time.sleep(0.8)
    f = shot(arm, f"{EV}/{arm}-fx2-after.png")
    out["fixture2_click"] = diff(e, f)
    print("fx2", out["fixture2_click"])

    with open(f"{EV}/{arm}-fixtures.json", "w") as fh:
        json.dump(out, fh, indent=2)
    print(json.dumps(out, indent=2))


def main():
    arm, verb = sys.argv[1], sys.argv[2]
    if verb == "park":
        print(park(arm))
    elif verb == "goto":
        ref = f"{RIG}/{arm}/ptr-ref.png"
        print(goto(arm, int(sys.argv[3]), int(sys.argv[4]), ref))
    elif verb == "validate":
        validate(arm)
    elif verb == "where":
        print(locate(arm, f"{RIG}/{arm}/ptr-ref.png"))
    else:
        raise SystemExit("unknown verb")


if __name__ == "__main__":
    main()
