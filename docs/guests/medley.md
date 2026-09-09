# medley guest — Interlisp Medley, host-native

Status: **LIVE 2026-09-09** (Tier 3 host-native, no emulated machine). Wave
record: [`../lab/MEDLEY-WAVE.md`](../lab/MEDLEY-WAVE.md).

## Identity and source

- Public ID / station dir: `medley`; slot 191, UDP 54191, VMID label 191,
  Xvfb `:91`.
- What it is: **Interlisp Medley**, the Xerox PARC Lisp environment (1987
  release) as maintained by the Interlisp project, running on **maiko**, its
  portable byte-code VM, as a plain X11 client. No ROM, no disk image, no
  emulated CPU.
- Media (MIT licence, public, safe to fetch anywhere):
  `https://github.com/Interlisp/medley/releases/download/medley-260826-3a14c9aa_260319-9259716e/medley-full-linux-x86_64-260826-3a14c9aa_260319-9259716e.tgz`
  — 185512952 bytes, sha256
  `9e163aaf87a30f0e14e721826172d22c680153bab597c57ef20f39bea3736f76`.
  It bundles `medley/` (loadups, greetfiles, library, fonts, docs) and
  `maiko/linux.x86_64/{lde,ldex,ldeinit}`. Reference only: the Virtual OS
  Museum runs the 2023-11-03 build of the same repo with the same
  `run-medley` shape (`vom-reference.md`); nothing was copied from it.
- Builder: `scripts/build-guests/tiles/medley.sh` — fetch, verify, unpack
  into `/data/vms/streamhost/assets/medley/{medley,maiko}`, then a throwaway
  Xvfb boot proof. `assets/medley/MANIFEST.sha256` pins the tarball.

## Runtime and device set

There is no device set in the QEMU sense. The station is:

| Part | Value |
|---|---|
| Lisp VM | `assets/medley/maiko/linux.x86_64/ldex` (needs libX11, libbsd, libmd — all on labhost trixie) |
| Sysout | `medley/loadups/full.sysout` (Interlisp + Common Lisp + all the tools) |
| Greet | `medley/greetfiles/MEDLEYDIR-INIT` (the release default) |
| Display | pinned Xvfb `:91`, `1024x768x24`; `-g 1024x768 -sc 1024x768 -noscroll` so window == Lisp screen == capture |
| Memory | `-m 256` (MB of Lisp virtual memory) |
| Capture | `SH_CAPTURE=x11` (X root) |
| Input | `SH_INPUT_BACKEND=x11test`, `SH_X11TEST_ABS=1`, `SH_X11TEST_BUTTONS=xtest`, `SH_X11TEST_KEYS=1`, `LDEKBDTYPE=X` |
| Audio | off (Medley has none) |
| Network | none (see OPEN) |

Launcher: `streamhost/stations/medley/x11-runtime.sh` (modelled on amix's,
minus the guest-X warp). It reaps a previous maiko by `/proc/<pid>/exe` under
the asset dir, claims the display through `xvfb-alloc`, wipes `work/`, and
execs `ldex` with `HOME`, `LOGINDIR` and `LDEDESTSYSOUT` all inside `work/`
so a visitor's `SaveVM`/`LOGOUT` can never touch the asset tree.

Measured on the smoke rig (2026-09-09): the Exec and logo are on screen at
the first 2 s capture and the frame is byte-identical (bar the caret blink)
through 60 s. **Boot ≤ 2 s.**

## Reset and fixture

`resetMode=relaunch`, no statefile: kill by `mame.pid`, `rm -rf work/`,
relaunch the release sysout. Fixture = the default greet scene: white root,
the `Exec (XCL)` listener top-left with the greet transcript ending in a
time-of-day greeting (`Hi.` / `Good evening.` — MEDLEYDIR-INIT picks it, so
two resets can differ by that one line) and the `2>` prompt, the Medley logo
top-right, the black status line across the top.

## Input proofs (framebuffer, 2026-09-09)

Live station, wake lease held: `(+ 40 2)` typed over XTEST returned `42` in
the Exec (`live/typed2.png`); pointer readback 900,700 exact; `labctl reset`
gave a new pid and the pristine Exec (only the greeting and clock differ).
Earlier, on the smoke rig on `:91`:

- **Pointer PASS**: `xdotool mousemove 200 300` and `900 700` read back
  exactly; the click at 200,300 gave the Exec keyboard focus.
- **Keyboard PASS**: `(PLUS 40 2)` typed over XTEST echoed byte-perfect and
  was evaluated (`typed.png`; the Exec is XCL so `PLUS` is undefined — the
  shipped demo uses Common Lisp forms).
- Key pacing shipped at the fleet floor 40/40; nothing dropped at xdotool's
  60 ms.

## Driving it by hand

There is no QMP and no exec channel. With no visitor attached the daemon
SIGSTOPs maiko after 60 s idle, so **hold the wake lease first** or every
keystroke silently queues (measured 2026-09-09: a typed form changed nothing
until the lease was held):

```bash
ssh lab 'touch /run/streamhost/wake/medley.lease   # TTL 90 s; re-touch for longer work
         grep State /proc/$(cat /data/vms/streamhost/stations/medley/mame.pid)/status   # want S, not T
         DISPLAY=:91 xdotool mousemove 200 300 click 1 type "(+ 40 2)"; DISPLAY=:91 xdotool key Return'
ssh lab 'labctl shot medley'      # reads the X root
ssh lab 'labctl reset medley'     # relaunch: new pid, pristine Exec in ~3 s
```

Never inject while a session is attached — the daemon is the single injector
on this display.

## OPEN

- **Network plane.** maiko can bridge Lisp TCP/IP to the host (its nethub /
  TAP options), which would let Medley's own TCP stack join the retronet at
  its reserved `10.99.0.39`; no period browser exists for it, so the value is
  an FTP/telnet demo at most. The reservation and tap name are held as the
  uniqueness ledger only; no `rn-tapnet.sh` is committed.
- **IM client**: none exists for Medley; by definition OPEN.
- **Richer rest scene**: a greet file that also opens an Inspector or a
  Sketch window would show more of the environment at first sight. The
  default greet was kept so the release image, not a local edit, is what
  ships.

## Rollback

`systemctl stop streamhost@medley`; delete `assets/medley` — nothing else on
the box was touched by this station. Claims re-home to `station-medley` at
landing.
