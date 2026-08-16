# VICE frame plane — getting a headless VICE's screen into a shared mapping

**Status 2026-08-16: PROVEN on the lab box.** A host-native, headless VICE
(no X server, no DISPLAY, no SDL at all) publishes the emulated C64 screen into
a file-backed mapping in the **same wire format streamhost's `SH_CAPTURE=shm`
already speaks** — read back by the *unmodified* consumer-side dumper written
for the IRIX/MAME producer (`scripts/build-guests/irix/irix-bench/shmpng.py`,
md5 `87b075929c097d35240ebca30bb65f8b`). This is the VICE analogue of
`scripts/build-guests/patches/mame-drawshm.patch`, and it is the frame half of
the per-emulator plane [`DEBRIDGE-CONVERSION-BRIEF.md`](../DEBRIDGE-CONVERSION-BRIEF.md)
§scope names as the precondition for converting the VICE kiosks.

Scope of this research: **frames only.** Input (the ctlsock analogue), audio,
and checkpoints are untouched and unproven for VICE.

Rig (namespaced, nothing live touched): `/data/vms/soltest/vice-vid/` on
labhost.

---

## 1. The recipe — host-native headless VICE on labhost

Upstream is the VICE team's git mirror; `vice/` is the source root inside it.
`main` today is **VICE 3.10** (`configure.ac`: 3.10.0), not the 3.9 that the
bridged kiosks carry.

```sh
# 1. source (50 MB shallow; the mirror tags every SVN revision, so no tag fetch)
git clone --depth 1 --no-single-branch \
    https://github.com/VICE-Team/svn-mirror /data/vms/soltest/vice-vid/vice-src

# 2. two build tools labhost does not have, obtained WITHOUT touching the host:
#    - dos2unix: a 5-line sed shim in the rig's own bin/ satisfies configure
#    - xa65:     apt-get download + dpkg-deb -x into the rig, never installed
mkdir -p /data/vms/soltest/vice-vid/bin
printf '%s\n' '#!/bin/sh' \
  'for a in "$@"; do case "$a" in -*) continue;; esac; [ -f "$a" ] && sed -i "s/\r$//" "$a"; done' \
  'exit 0' > /data/vms/soltest/vice-vid/bin/dos2unix
chmod +x /data/vms/soltest/vice-vid/bin/dos2unix
cd /data/vms/soltest/vice-vid && apt-get download xa65 &&
  dpkg-deb -x xa65_*.deb pkg && cp pkg/usr/bin/* bin/

# 3. configure + build (out-of-tree), headless UI: no GTK, no SDL, no X
export PATH=/data/vms/soltest/vice-vid/bin:$PATH
cd /data/vms/soltest/vice-vid/vice-src/vice && ./autogen.sh
mkdir -p /data/vms/soltest/vice-vid/build && cd /data/vms/soltest/vice-vid/build
../vice-src/vice/configure --enable-headlessui \
    --prefix=/data/vms/soltest/vice-vid/install
make -j12          # ~4 min on the box (gcc 14.2, trixie), zero warnings added
```

Binaries land in `build/src/` (`x64sc`, `xplus4`, `xvic`, `x128`, …). Debian
trixie's stock toolchain is enough; **no new package was installed on labhost.**

### The two documented landmines, re-checked

* **`make install` SKIPS the ROM data files** (`scripts/build-guests/tiles/plus4.sh`).
  Still true — and irrelevant here, because a host-native station should never
  `make install`: point the binary at the source tree's own data dir,
  `-directory <src>/vice/data`. That directory holds `C64/`, `PLUS4/`,
  `VIC20/`, `DRIVES/` … with every ROM the emulators loaded in the proofs
  below. The 3.9-era "repair the ROM set from the retained source tree" dance
  disappears with the guest.
* **"VICE 3.9 segfaults when stdout is not a terminal"** — **did not reproduce**
  in 3.10 headless. Every run recorded here had `stdout`/`stderr` redirected to
  a file and `stdin` from `/dev/null`, ~15 runs, no crash. 3.10's `vice_banner()`
  goes through `log_message()`; the only `isatty()` checks left in the tree are
  the monitor console (`arch/shared/console_unix.c`, which declines cleanly) and
  the GTK3 UI. Do not carry the 3.9 "stdout MUST stay on tty1" rule into a
  host-native station without re-testing it on the version you ship.

### Two argument traps that cost time

* `-sound none` is **wrong** and silently poisons the rest of the line: `-sound`
  is a boolean *enable*, so `none` becomes a positional argument and everything
  after it is reported as `Extra arguments on command-line`. Sound off is
  **`+sound`**.
* VICE writes its log under `$HOME/.local/state/vice/` and **exits(255)** if it
  cannot. A station launcher must set `HOME` to a writable per-station dir (or
  `-logfile`), exactly like the MAME stations set `-homepath`.

---

## 2. The seam

**One function: `video_canvas_refresh()` in `src/arch/headless/video.c`.**

It is the single arch-side call the emulator core makes when a rectangle of the
emulated screen is finished — `raster/raster-canvas.c: refresh_canvas()` for the
dirty rectangle each frame, `video_canvas_refresh_all()` for a whole frame — and
it is where **every** UI port publishes: gtk3 and sdl2 both call the
machine-independent `video_canvas_render()` from there with a 32bpp destination.
In the headless port it is an empty stub. Give it the mapping as its
destination and the frame plane exists.

This is a *better* seam than MAME's drawshm got:

* **It is above every machine.** Nothing in the new code names a machine, a
  video chip or a driver; the only types touched are `video_canvas_t` and its
  draw buffer. One binary set serves x64sc / xplus4 / xvic / x128 (proof: §4).
* **Damage comes for free.** The core hands us the refreshed rectangle in the
  call itself, so the published dirty rect is the emulator's own. drawshm has to
  flag every frame whole-frame dirty and let streamhost's `SH_SHM_DAMAGE` diff
  it back down on the consumer's core; VICE does not.
* **No pixel conversion.** `video_canvas_render()` writes whatever layout the
  render tables were programmed with, so programming them as XRGB8888 (red at
  bit 16, green at 8, blue at 0 — the layout SDL2 selects for `rmask 0x00ff0000`)
  produces B,G,R,X in memory, byte-identical to the BGRA the encoder consumes.

Three supporting hooks are needed in the same file, and each one is a real
finding, not boilerplate:

| Hook | Why |
|---|---|
| `video_init()` / `video_shutdown()` | pick up `VICE_SHM_PATH`, unmap on the way out |
| `video_canvas_set_palette()` | the headless stub only *stored* the palette. Every physical colour is 0, so a render through the untouched stub would be **black**. This is the trap: the seam alone is not enough. |
| `video_canvas_can_resize()` | upstream headless returns 0, which makes `video_viewport_resize()` keep `canvas_physical_width/height` at **zero** — a canvas with no size publishes nothing. Returning 1 (only when publishing) lets the canvas adopt the emulated screen's size. |

### The gating covenant

Everything is gated on `VICE_SHM_PATH`. Unset ⇒ every hook above is the upstream
no-op, `can_resize` included. **Measured, not asserted:** the patched `x64sc`
with the variable unset writes no file, logs nothing, and its `-exitscreenshot`
is byte-identical (md5 `3f91057a6e973bd21b1ae0c177ca7bc5`) to the **pre-patch**
binary's screenshot of the same run.

### The commits

Local clone `/data/vms/soltest/vice-vid/vice-src`, branch `kernel-hive/shmfb`,
on top of upstream `223e31ac` (`main`). Two commits, ready to become a fork
submodule in the shape of `third_party/mame-irix`:

| SHA | Subject | Files |
|---|---|---|
| `c6dbc179` | headless: a shared-memory framebuffer publisher (`VICE_SHM_PATH`) | new `src/arch/headless/shmfb.{c,h}` (+`Makefile.am`) |
| `a8d430a8` | headless: publish from `video_canvas_refresh()`, the one video seam | `src/arch/headless/video.c` (5 stubs, ~30 lines) |

There is no lab fork remote yet, so the branch is local to the rig — creating
`third_party/vice-headless-shm` and pushing it is the next step, not this one.

### Wire format — unchanged, byte for byte

64-byte header (`IFB1`, version 1, w, h, stride, bpp 32, u64 seqlock, dirty
rect) then `w*h` host-endian XRGB8888 pixels. Seqlock discipline is drawshm's:
odd before the pixels are touched, even after, release ordering both times.
**One publisher per mapping** — a two-chip machine (x128: VICII + VDC) has two
canvases, and the first to refresh claims the mapping while the other is
ignored, so the single-producer premise holds.

Environment: `VICE_SHM_PATH` (required; unset = inert), `VICE_SHM_TRACE`
(optional log of the mapping + a publish count).

---

## 3. The proof — the framebuffer, not the log

All runs: **no `DISPLAY`, no X server**, stdout to a file, `-directory` at the
source data tree, `+sound`. `ldd` on the binary shows **no SDL and no GTK** at
all; `libX11` is still there, pulled in transitively by pulse/usb/ffmpeg
dependencies, but nothing on this path opens a display — unset `DISPLAY` and the
emulator runs and publishes exactly as recorded here.

| Run | Machine | Mapping bytes | Geometry | 64 + w·h·4 |
|---|---|---|---|---|
| default (2× CRT) | `x64sc` | 1,671,232 | 768×544 | ✓ 64 + 768·544·4 |
| `+VICIIdsize -VICIIfilter 0` | `x64sc` | 417,856 | 384×272 | ✓ 64 + 384·272·4 |
| default | `xplus4` | 1,769,536 | 768×576 | ✓ |
| default | `xvic` | 2,035,776 | 896×568 | ✓ |

**Content.** `shmpng.py` (unmodified, the IRIX producer's own tool — that it
reads this producer with no edit *is* the contract check) renders the C64 boot
screen from the mapping: `**** COMMODORE 64 BASIC V2 ****` / `64K RAM SYSTEM
38911 BASIC BYTES FREE` / `READY.` in light blue on dark blue inside a light
blue border, with CRT scanlines at 2×. `frame-compare.py --frame` on the 1×
frame: 384×272, 2 distinct colours, entropy 0.9727 bits, **42,090 of 104,448
non-dominant pixels (40.3%)** — 42× the emptiness floor, so a black or flooded
frame could not have passed.

**Fidelity, to the pixel.** Run at 1× with no filter so the two are directly
comparable, the published mapping versus VICE's **own** `-exitscreenshot` from
the same run — an independent code path that renders from the draw buffer and
never touches an arch renderer — `frame-compare.py` says
**`UNCHANGED — not one pixel differs` (0 of 104,448 changed, max channel delta
0).** (drawshm's equivalent check on MAME differed by 96 pixels, one blinking
cursor cell.)

**Live, not just at exit.** A running `x64sc` (throttled, no cycle limit) was
sampled through the mapping from another process at t≈1 s (all black, still
booting) and t≈5 s (the full boot screen, mean/sd identical to the exit-time
frame), then killed by a pid whose `/proc/<pid>/exe` was verified to be the rig
binary. The mapping is live while the emulator runs.

Artefacts on labhost (`/data/vms/soltest/vice-vid/run/`): `shm.png`,
`shm1x.png`, `shot1x.png`, `live-t1.png`, `live-t5.png`, `xplus4.png`,
`xvic.png`, `base.png` / `base2.png` (the gating covenant pair).

### Cost

20 emulated seconds at real time, `x64sc`, CPU seconds (user+sys):

| Configuration | CPU | Δ |
|---|---|---|
| publishing off (upstream headless renders **nothing**) | 5.01 s | — |
| publishing on, 1×, no filter (384×272) | 5.14 s | +0.13 s ≈ **0.7% of a core** |
| publishing on, 2× CRT filter (768×544) | 7.18 s | +2.17 s ≈ **11% of a core** |

The frame plane itself is nearly free; the CRT filter at 2× is what costs. A
station that wants the CRT look pays ~0.11 core for it — a knob worth setting
deliberately per exhibit, not inheriting. (Note the baseline is *no video at
all*: upstream headless never rasterises, so these numbers are the full cost of
having a picture, not an increment over a windowed build.)

---

## 4. What makes VICE harder than MAME was

1. **The stub is a trap, not a hook.** MAME's `-video` module registry meant
   drawshm was a *new peer* to `drawnone`/`drawsdl`, with the render path
   already wired. VICE's headless port has the calls but they are empty, and two
   of the three "empty" ones (`set_palette`, `can_resize`) are **load-bearing** —
   fill only the obvious one and you publish a correctly-sized black rectangle,
   or nothing at all. Neither failure is visible in a log.
2. **No arbitrary output resolution.** `MAME_SHM_SIZE=WxH` lets a MAME station
   publish any surface and letterbox the machine inside it. VICE has no such
   concept: the surface is the emulated screen times the integer
   `<CHIP>DoubleSize` scale (and `<CHIP>Filter`), so the published geometry is
   whatever the chip and those two resources produce — 384×272 or 768×544 for a
   C64, 896×568 for a VIC-20. A station that needs a fixed published size must
   either accept consumer-side scaling or grow a scaler in the producer, which
   would be a second, worse feature. **Recommendation: publish native, scale in
   streamhost/the encoder.**
3. **Geometry changes under you.** Different chips, different sizes, and the C128
   has two canvases at once. The mapping re-`ftruncate`s and re-`mmap`s on any
   geometry change (the consumer already handles that — it is what IRIX's VC2
   reprogramming forced), and the two-canvas case is resolved by
   first-canvas-wins. An x128 station that wants the **VDC** (80-column) screen
   has no way to say so today: add `VICE_SHM_CHIP` when a station needs it.
4. **Version fork in the fleet.** The bridged kiosks run VICE **3.9**; upstream
   `main` is **3.10**, and that is what these commits are against and what the
   proofs ran on. Converting a live VICE station is therefore also a version
   bump (with its own resource/keymap surface), not only a de-bridging. The
   headless port's stubs are old and stable, so a 3.9 backport is likely
   mechanical — but it is untested.
5. **Everything else is still missing.** Input, audio and checkpoints have no
   VICE equivalent of the ctlsock module, the `-audiodriver disk` FIFO or
   `SAVEST`. VICE has a binary monitor and a keyboard-event API that are the
   obvious candidates, but nothing here proves them. **A VICE station is not
   convertible on this work alone.**

## 5. Teardown

Rig left in place at `/data/vms/soltest/vice-vid/` (220 MB) **because it holds
the fork clone with the commits**; there is nowhere to push it yet. Nothing
else was touched: no live station, no `/data/vms/streamhost/`, no packages
installed on labhost, no shared claims taken (no display, tap, port, VMID or
chain — a headless emulator writing one file in its own rig needs none). The one
process started in the background was killed by pid after verifying
`/proc/<pid>/exe`, and a `/proc` sweep for executables under the rig path
afterwards found none.
