# NeXTSTEP 3.3 on a COLOR NeXT machine (Previous, headless)

**Status:** PROVEN in sandbox `/data/vms/sandbox/prev-color/` — a colour NeXTSTEP 3.3
Workspace, 1120x832, reached with **zero input**, captured from the IFB1 shm export.
Nothing in this doc has been applied to the live `nextstep` station.

**Recommendation: non-Turbo NeXTstation Color, 32 MB.** One-line change of intent
against today's station (`nMachineType 1 -> 2`, `bColor FALSE -> TRUE`,
`bNBIC TRUE -> FALSE`, memory banks `16/16/16/16 -> 8/8/8/8`); same ROM, same disk
image, same geometry, same input path.

---

## 1. What was proven

- The **same, unmodified** `NS33.dd` (the NeXTSTEP 3.3 m68k disk the mono station
  uses) boots on the colour machine. **No in-guest reconfiguration of any kind.**
  NeXTSTEP 3.3 is universal for black hardware: the kernel probes the framebuffer
  at boot and the WindowServer comes up on the colour one by itself. There is no
  "colour depth" preference to set, no login-window change, no driver to install.
- Boot lands **straight on the Workspace** — File Viewer open, dock populated —
  with no keystroke and no click.
- The display stays **1120x832**. `NeXT_SCRN_W`/`NeXT_SCRN_H` in
  `src/gui-sdl/sdlscreen.c` are `const int` **1120 / 832**, not machine-dependent;
  colour only changes which blit function fills the same-sized texture
  (`blitColor` vs `blitBW`, `blitScreen()` switching on `bColor`). The SPA geometry
  and the 1:1 pointer map are therefore untouched.
- The IFB1 shm export needed **no change**: `blitColor` writes the same 32-bit
  texture that `fbshm_publish` copies, so the existing spike patch carries colour
  through unmodified.

### Colour pipeline (for the encoder's sake)

The colour NeXT framebuffer is **16 bpp, big-endian RGBX 4-4-4-4** — 4096 colours.
`sdlscreen.c:col2rgb()` expands each nibble by `* 0x11`, so **every channel value
the station can ever emit is a multiple of 17** (0x00, 0x11, ... 0xFF). The captured
desktop used 602 distinct colours out of that palette. Mono is 2 bpp — four greys
(0/85/170/255) — which is why the mono station's stream is so cheap.

## 2. Evidence

`/data/vms/sandbox/prev-color/evidence/`

| file | what |
|---|---|
| `color-desktop-raw.png` | the acceptance shot: colour Workspace at 1120x832 |
| `color.shmsnap`, `color-idle.shmsnap` | raw IFB1 mappings behind the PNGs |
| `mono.shmsnap` | the mono baseline for the same disk |

Non-grey pixels in the colour shot: **628 794 of 931 840 (67.5%)**. The desktop root
is `#555577` (nibbles 5-5-7 — NeXTSTEP's blue-grey colour root, not the mono
`#555555`); the dock NeXT logo renders in its yellow/magenta/cyan, the folder icons
in tan, the clock in green-on-black, the house icon with a red roof and a green tree.
Channel order was cross-checked against those known-colour icons.

## 3. The machine matrix (`src/configuration.c`, `includes/configuration.h`)

`MACHINETYPE` is `{ NEXT_CUBE030=0, NEXT_CUBE040=1, NEXT_STATION=2 }`.
`Configuration_SetSystemDefaults()` **forces `bColor = false` for both cube types** —
colour exists only on `NEXT_STATION`. Today's station is `nMachineType = 1`
(NeXTcube 68040), so colour is not a flag flip on the current machine: it is a move
to the NeXTstation.

`Configuration_CheckMemory()` quantises the four banks per machine class:

| machine | legal bank sizes | ceiling |
|---|---|---|
| non-Turbo mono | 0 / 1 / 4 / 16 MB, **banks 2+3 forced to 0 on NEXT_STATION** | 64 MB cube, 32 MB slab |
| **non-Turbo colour** | **0 / 2 / 8 MB, all four banks usable** | **32 MB** |
| Turbo (mono or colour) | 0 / 2 / 8 / 32 MB | 128 MB |

So 32 MB is not a choice on a non-Turbo colour slab, it is the ceiling — and it is
what the real hardware took. NeXTSTEP 3.3 is comfortable there; the station is a
single-user Workspace exhibit, not a build box.

## 4. Recommended cfg stanzas (proven, copy verbatim)

```ini
[System]
nMachineType = 2
bColor = TRUE
bTurbo = FALSE
bNBIC = FALSE
bADB = FALSE
nSCSI = 1
nRTC = 0
nCpuLevel = 4
nCpuFreq = 25
bCompatibleCpu = TRUE
bRealtime = TRUE
nDSPType = 2
bDSPMemoryExpansion = TRUE
n_FPUType = 68040
bCompatibleFPU = TRUE
bMMU = TRUE

[Memory]
nMemoryBankSize0 = 8
nMemoryBankSize1 = 8
nMemoryBankSize2 = 8
nMemoryBankSize3 = 8
nMemorySpeed = 3

[ROM]
szRom040FileName = <media>/Rev_2.5_v66.BIN
bUseCustomMac = FALSE
```

`bNBIC = FALSE` is not optional: `Configuration_CheckPeripheralSettings()` forces it
off on `NEXT_STATION` (a slab has no NeXTBus). Write it into the cfg so the file the
build script emits matches what the emulator actually runs. Everything else —
`[Tablet] nTabletType = 2`, `[Boot]`, `[HardDisk]`, `[Screen]` — is **unchanged**
from the current station.

## 5. Turbo vs non-Turbo — measured, and the answer is non-Turbo

Three machines, same binary, same disk image, same headless launch, run **back to
back on labhost** (SDL dummy video/audio, `PREVIOUS_SHM_PATH` export on, no
`taskset`). "Boot" is cold power-on to the Workspace menu appearing at 0,0,
detected from the shm mapping. "Idle CPU" is `utime+stime` of the emulator process
over a 180 s window, 30 s after the Workspace appeared, with nothing happening.

| variant | machine | ROM | RAM | boot → Workspace | idle %CPU | host load during |
|---|---|---|---|---|---|---|
| `mono` (today's station) | NeXTcube 68040, 25 MHz | Rev 2.5 v66 | 64 MB | **137.8 s** | **146.3 %** | 24.6 |
| `color` (**recommended**) | NeXTstation Color, 25 MHz | Rev 2.5 v66 | 32 MB | **134.4 s** | **148.5 %** | 16.8 |
| `turbocolor` | NeXTstation Turbo Color, 33 MHz | Rev 3.3 v74 | 128 MB | **140.4 s** | **164.5 %** | 18.8 |

Read it as: **colour is free.** 148.5 % vs 146.3 % is inside the noise of a box
carrying a load average of 17–25 from other agents; boot is if anything a hair
faster. The 16 bpp `blitColor` inner loop is one table lookup per pixel against
`blitBW`'s four-pixels-per-byte unpack, and both feed the same 1120x832x4 texture
and the same shm copy — the emulated 68040 dominates, not the blit.

**Turbo buys nothing and costs ~11 % CPU.** Its nominal 33 MHz does not shorten
boot (140.4 s vs 134.4 s) because `bRealtime = TRUE` paces the emulation and the
host is the bottleneck; the extra cycles just burn host CPU. It also drags in three
changes to a proven machine for no exhibit-visible gain:

- a **different ROM** (`Rev_3.3_v74.BIN`) — a second ROM to source, hash and ship;
- `kms.c:730` sets `kms.rev = REV_NEW` on Turbo — the keyboard/mouse controller
  the NeXT input path talks to changes revision;
- `Configuration_SetSystemDefaults()` turns **ADB on** for Turbo (`bADB = true`),
  adding a second input controller (`adb.c`) that does not exist on the current
  station.

For a Workspace exhibit whose whole input story is already proven against
`REV_OLD` + no ADB, that is risk with no upside. **Take the non-Turbo colour slab.**

For the record, Turbo Color *does* work: it booted to a pixel-identical colour
Workspace (`evidence/turbocolor-desktop.png`, differing from the non-Turbo shot only
in the dock clock reading 8:41 vs 8:39). If 32 MB ever becomes the binding
constraint, Turbo is the proven way to 128 MB.

## 6. Risks and open items

- **Pointer not re-proven on colour.** `src/tablet.c` (the SummaGraphics digitiser
  on SCC serial port B) contains **no** `nMachineType` / `bColor` / `bTurbo`
  branch, and the only Turbo-conditional code anywhere near the input path is
  `kms.c:730` and `scc.c:589` — both of which the **non-Turbo** colour slab leaves
  byte-identical to today's machine. So the 1:1 absolute map should carry over
  untouched. It was **not** re-measured here: the tablet kernel server is loaded by
  `/NextAdmin/InstallTablet.app` and does not survive a cold boot, so proving it
  needs an input session and a disk mutation — which this task deliberately did not
  do. **The station rebuild must re-run `nextstep-tablet-install.py` and re-prove
  the 1:1 map on the colour machine before the golden is baked.** Expected to pass;
  not yet evidence.
- **The golden must be recaptured.** Machine type, colour flag and memory banks are
  all part of the checkpoint's device set — golden + binary + device set are one
  combination. A colour station is a **new** golden, not a cfg edit against the
  existing one, and the current mono golden must not be retired until the colour
  one is restore-proven.
- **Stream cost is untested.** The exhibit goes from a 4-grey framebuffer to a
  602-colour one over the same 1120x832. Nothing about the emulator got more
  expensive, but the *encoder* now has real chroma to carry. Worth one look at the
  station's bitrate after cutover; nothing here measures it.
- **`bNBIC` and the memory banks are forced, not requested.** If the build script
  writes `bNBIC = TRUE` or `16/16/16/16` on `nMachineType = 2`, Previous silently
  rewrites them (`Configuration_CheckPeripheralSettings`, `Configuration_CheckMemory`).
  Emit the corrected values so the cfg on disk is the truth.
- **The disk copies used here are throwaway.** Boots wrote to them (fsck, clock).
  No modified image is being handed over; the retronet worker owns disk mutations.

## 7. Reproducing

```sh
S=/data/vms/sandbox/prev-color
setpriv --reuid=1000 --regid=1000 --clear-groups env HOME=$S/home-color \
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy PREVIOUS_SHM_PATH=$S/fb-color.shm \
  $S/build/src/previous
python3 $S/dumpfb.py $S/fb-color.shm out.png    # IFB1 -> PNG + colour statistics
```

Emulator: `github.com/Wnt/previous` branch `kernel-hive` (Previous SVN r1847 /
release 4.4 plus the no-WM-decoration fix and the IFB1 shm export), built
`-DCMAKE_BUILD_TYPE=Release -DENABLE_RENDERING_THREAD=1`. `bash $S/run-all.sh`
re-runs the whole three-machine comparison into `$S/results.txt`.
