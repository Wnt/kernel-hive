# Commodore VIC-20 (PAL) — gallery tile notes (udp/54085)

**Guest:** a captured **Debian 13 (trixie) x86_64 kiosk** running **VICE `xvic`**,
emulating a **PAL Commodore VIC-20** that boots its ROM to the **CBM BASIC V2**
`READY.` prompt. An **"emulator bridge"** tile — streamhost captures the Linux
framebuffer + AC97 audio (the VIC-I sound routed through ALSA) exactly like
every other tile. See **`streamhost/docs/BRIDGE.md`**.

**Shared base:** `/data/vms/bridge/bridge-base-trixie.qcow2` (read-only backing; built
by `scripts/build-guests/lib/bridge-base.sh --suite trixie`). It already contains the whole VICE
family, `xvic` included — the base builds VICE from source for the `c64` tile
and `make install` ships every emulator in the suite.
**Build script (tile):** `scripts/build-guests/tiles/vic20.sh` — thin overlay + kiosk
`launch.sh` + quiet console + golden bake + framebuffer/keyboard proof, fully
automated, ~2–4 minutes.
**Tile dir (host):** `/data/vms/streamhost/tiles/vic20/` — `overlay.qcow2`
(thin, on the shared base; holds the INTERNAL `golden` snapshot),
`qemu-streamhost.sh`, `tile.env`, `evidence/`.
**Registry entry:** `registry/tiles/vic20.json` (slot 85, udp 54085, VMID 221,
ssh hostfwd 127.0.0.1:5821).

## Media and license — there is none to stage

This is the cheapest tile in the lineup to reproduce: **no ISO, no cartridge, no
disk image, no licensed ROM to fetch.** VICE bundles the Commodore ROMs (which
is exactly why Debian cannot ship VICE and why the bridge base builds it from
source), and an unexpanded VIC-20 needs nothing beyond them. Consequently there
is no `docs/lab/ASSETS-MANIFEST.md` row and no `check-assets.sh` entry: the
builder's only external input is the frozen bridge base.

- **VICE 3.9** — GPLv2; bundles the VIC-20 BASIC/KERNAL/character ROMs for
  emulation use.

## Acceptance criteria

- **Ready framebuffer:** the PAL power-on screen — `**** CBM BASIC V2 ****`,
  `3583 BYTES FREE`, `READY.` — in blue on white paper inside a cyan border,
  drawn double-size (`-VICdsize`) on an 800×600 X root, with the cursor block
  present. No Linux console, no X log, no pointer.
- **Reset mode:** `loadvm`, internal snapshot `golden`. No post-restore keys.
- **Pointer:** none. `--pointer none --input-backend disabled`; X runs with
  `-nocursor`. The real machine had no pointing device (its other input was a
  joystick), so there is nothing to emulate and nothing to calibrate.
- **Keyboard:** PS/2 only, paced at 80 ms hold / 80 ms gap (measured — see
  "Why four frames" below).
- **Login:** none. `credentialsRef` is `guest/vic20` for form only; the guest
  Debian kiosk is reached with the shared bridge key, never a password.

## Device set

Identical in shape to its bridge siblings (`c64`, `apple2`, `atarist`, `amiga`,
`mpf2`), which is what makes the golden portable and the launcher parity claim
honest:

```
qemu-system-x86_64 -name streamhost-vic20
  -enable-kvm -machine pc-i440fx-11.0,vmport=off -m 1536 -smp 2 -cpu host
  -rtc base=localtime
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c
  -vga std
  -display dbus,p2p=on,audiodev=snd0
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16
  -device AC97,audiodev=snd0
  -usb
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5821-:22 -device e1000,netdev=n0
  [-loadvm golden] -qmp unix:$BASE/qmp.sock,server=on,wait=off
  -pidfile $BASE/qemu.pid
```

`vmport=off` and the absence of a tablet are part of the device set: adding
either invalidates `loadvm golden`.

## The kiosk launcher

```
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
xrandr --output <first connected> --mode 800x600
exec xvic -sounddev alsa -VICdsize -VICborders 0 -pal
```

- **800×600, not the base's stock 1024×768.** VICE's SDL window is a fixed size
  and cannot grow; SDL real fullscreen (`-VICfull`) renders **black** under
  std-VGA capture (the trap `scripts/build-guests/tiles/amstradcpc.sh` records). So
  the root shrinks to the smallest advertised mode that contains the window,
  exactly as the `c64` tile does. The captured frame is then mostly picture,
  with thin black bands top and bottom.
- **`-pal`.** The exhibit is the European machine: 1.108 MHz, 50 Hz, and the
  familiar `3583 BYTES FREE`.

## THE TRAP THAT COST THIS ADD ITS FIRST TWO HOURS

**VICE 3.9 segfaults at startup whenever its stdout is not a terminal**, and it
prints nothing at all when it does.

The mpf2 overlay starts its kiosk with `exec startx -- -nocursor
>"$HOME"/startx.log 2>&1` to keep console text off the visible VT, which is
correct and harmless for MAME. Copy that line for a VICE tile and the emulator
dies instantly: `vice_banner()` → `log_message(" ")` → `log_helper()` hands a
NULL string to `log_archdep()`, and `strlen(NULL)` kills the process before a
single byte of output. Confirmed by gdb backtrace on the tile, 2026-08-08:

```
#0  __strlen_evex () at ../sysdeps/x86_64/multiarch/strlen-evex.S:79
#1  log_archdep (logtxt=0x0, pretxt=0x0) at log.c:610
#2  log_helper (..., format=" ") at log.c:757
#3  log_message (log=-1, format=" ") at log.c:809
#4  vice_banner () at main.c:140
```

What you observe instead is X dying about a second after it starts and
`getty@tty1` looping until `start-limit-hit`, with an Xorg log containing no
`(EE)` lines and a startx log containing nothing from the emulator. Nothing in
that picture points at VICE. The same command under a pty (`script -qec …`)
runs perfectly, which is the fastest way to confirm the diagnosis.

**Therefore the vic20 kiosk profile leaves stdout on tty1** — the stock bridge
base profile and the `c64` tile do the same, which is precisely why they work.
X's own log still goes to `/var/log/Xorg.0.log`, and once X owns the display no
VT text reaches the captured framebuffer.

### The second trap: an incomplete ROM set

`bridge-base.sh` already records that VICE's `make install` **skips** some ROM
data files and that the emulator then segfaults on startup with no output; the
`c64` tile hit it on the C64 BASIC ROM. The frozen base's
`/usr/local/share/vice/VIC20` is missing `basic-901486-01.bin` the same way, so
`vic20.sh` repairs the set from the source tree the base retains
(`/usr/local/src/vice-3.9/data/VIC20`) and then asserts that BASIC, KERNAL and
the character generator are all present rather than trusting the copy.

Two different faults with the same signature — silent segfault, dead X, looping
getty — is why the builder asserts both conditions explicitly.

## Keyboard

- **Pacing: `SH_KEY_MIN_HOLD_MS=80`, `SH_KEY_MIN_GAP_MS=80`** — four PAL frames
  each way, twice the playbook's usual two. See "Why four frames" below; the
  short version is that the failure this guards against is a host scheduling
  stall, not frame quantisation, so it does not scale with the frame period.
- **`demoProgram.perCharMs: 170`.** The SPA typist waits `line.length *
  perCharMs` before submitting the next line, and this tile drains typed keys at
  hold+gap = 160 ms/char — more than twice the fleet default's assumed 70.
  `validate_demo_pacing` in `scripts/tiles-registry.py` fails the build if the
  budget that applies is below a tile's drain rate, so the two cannot drift.
- **No `SH_KEY_MAP`.** Unlike the MPF-II, this matrix does not have to be
  re-derived: VICE's default SDL **symbolic** keymap (`sdl_sym.vkm`) already
  maps host ASCII onto the Commodore key that produces that character.
- **`keyboard.letterCase: upper-only`.** A *shifted* letter on a VIC-20 is a
  graphics glyph, not a capital, so the SPA typist sends letters unshifted.
- **On-screen keyboard:** the `c64` profile, because it is literally the same
  keyboard — Commodore reused the VIC-20's case, keyboard and ports for the C64
  — and the same VICE bindings drive it (RUN/STOP = Esc, RESTORE = PageUp,
  C= = Tab).

## Why four frames, not two — the pacing bisect (2026-08-08)

The tile shipped at 40/40 (the playbook's two frames) and a visitor's type-in
came back corrupted: `PRINT CHR(147)` for `CHR$(147)`, `GOTO 0` for `GOTO 20`,
and therefore `?BAD SUBSCRIPT ERROR IN 10`. Two characters lost out of ~85.

Bisected on a `/data/vms/soltest` clone with
`scripts/dev/emu-key-pacing-bisect.py`: restore golden, type one fixed 40-character
line (`print chr$(147)+int(rnd(1)*8)-abcdefghij`, which exercises the same
shifted set the listing uses) with explicit press → hold → release → gap
events, screendump, compare against a slow-paced reference.

| hold / gap | corrupted lines (40 chars each) |
|---|---|
| 40 / 40 | **1 of 22** — intermittent, and it tracks host load |
| 60 / 60 | 0 of 14 |
| 80 / 80 | 0 of 22 |

**The mechanism is not frame quantisation.** Two frames covers that, which is
why 40/40 works most of the time. This box runs 30+ emulators; when VICE's
thread is starved for longer than the hold, the press *and* the release both
land between two of its input pumps and the key is never observed at all. The
margin has to cover a worst-case host stall, so it does not scale with the
machine's frame period the way playbook §5.1's rule of thumb assumes.

Two measurement traps cost most of the time here, and both made the instrument
lossier than the thing being measured:

- **`send-key` with `hold-time` releases asynchronously.** QEMU returns as soon
  as the press is queued and releases on its own timer, so back-to-back calls
  overlap on that timer — at 250 ms hold with a 250 ms sleep this harness still
  lost 6 of 40 characters. Use explicit `input-send-event` press/release pairs
  with real sleeps, which is what the daemon does.
- **The cursor blinks**, so a raw frame compare calls every trial corrupt.
  Capture the reference several times and mask the pixels that differ between
  those captures.

**`labctl type` has the first bug too, and one of its own.**
`send_chords_paced` issues `send-key` with `hold-time=hold_ms` and then sleeps
only `gap_ms`, so the true release→press gap it leaves is `gap - hold` = **0 ms**
at any tile that declares hold == gap (vic20, amstradcpc, mpf2). That is a
second, independent reason the playbook is right that `labctl type` is not a
fair test of a guest's keyboard — it is not merely unpaced, it actively
overlaps keys. Not fixed here; recorded so the next person does not measure
with it.

## Verification (2026-08-08)

All evidence is real QEMU framebuffer dumps in
`/data/vms/streamhost/tiles/vic20/evidence/`:

| Artifact | Shows |
|---|---|
| `ready-before-golden.png` | the untouched cold-boot power-on screen that was baked |
| `keyboard-print3.png` | `PRINT 3` typed through QMP at the tile's production pacing, with `3` printed back by BASIC |
| `golden-restored-after-keyboard.png` | `loadvm golden` returning to the exact baked fixture after the keyboard test dirtied it |

The golden is baked from an **untouched** cold boot and the keyboard proof runs
**after** the bake, against the restored fixture, so nothing the proof types can
ever reach the snapshot — the mpf2 add shipped a golden carrying its own
verification output and had to be re-baked.

## Cold boot

Zero input is genuine: the ROM prints its banner and stops, and the Debian
kiosk underneath auto-logs in and execs `startx`. See
`scripts/coldboot/vic20-zero-input-prep.md` and the `vic20)` arm in
`scripts/coldboot/bootrec-tiles.conf`. No boot clip is published, so
`spa.bootVideo` is unset.

## Rollback

The tile is a thin overlay on a read-only base and touches nothing else. To
withdraw it: `systemctl stop streamhost@vic20`, set `enabled: false` in
`registry/tiles/vic20.json`, regenerate, and republish the two runtime JSON
documents. To rebuild it: `scripts/build-guests/tiles/vic20.sh --force`, which
replaces `overlay.qcow2` — and therefore **destroys the golden snapshot inside
it** — then bakes and proves a new one. Never delete `overlay.qcow2` by hand.
