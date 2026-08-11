# Adding a PDP-11 to the gallery — backend, OS and integration research

Status: **research only, 2026-08-08.** Nothing is built, no registry entry
exists, no slot is claimed. This document is the feasibility study that
[`ADD-NEW-OS-PLAYBOOK.md`](../ADD-NEW-OS-PLAYBOOK.md) §1 expects before a
candidate enters the backlog table.

Verdict: **feasible, Tier 2 (bridge)**. SIMH inside a captured Debian-X kiosk,
the same shape as `c64`/`atarist`/`apple2`/`amstradcpc`/`mpf2`.

## 1. Why it is worth doing

The DEC PDP-11 (1970–1997) is the missing ancestor in a lineup that already
runs its descendants. It would become the **oldest machine in the collection**
— the current floor is `apple2` (1977) — and it is the direct prehistory of two
stations already live:

- `openvms` — VMS was written by the RSX-11M team, for the VAX, as the PDP-11's
  successor. Putting RSX-11M or RSTS/E next to DECwindows closes that arc.
- Every Unix tile — V6 and V7 *are* PDP-11 operating systems. The C language
  and the Unix filesystem were shaped by this machine's address space.

## 2. Backend: SIMH is the only real option

| Candidate | Finding |
|---|---|
| **QEMU** | No PDP-11 target exists. Closed. |
| **MAME** | Emulates only the **T-11** single-chip PDP-11 (VT240, Elektronika MS 0515). The K1801 Soviet machines and the real 11/xx CPUs are not emulated. The `irix`/`mpf2` MAME route does not apply. Confirmed against labhost's own MAME 0.276 driver list. |
| **SIMH** | Simulates the full PDP-11 line (11/20 … 11/93) plus RK05/RL02/RP06/TM11 peripherals, DZ11/DL11 terminals, and — via its `display/` subsystem with SDL2 — the **VT11/GT40 vector display**, including the in-tree `PDP11/lunar11` Lunar Lander. This is the backend. |

**Which SIMH.** The project forked in May 2022 when the licence on `simh/simh`
v4 was changed; Supnik withdrew his endorsement and now recognises only the
"classic" 3.x line (3.12-5, July 2024). [Open SIMH](https://github.com/open-simh/simh)
(MIT) is the maintained free-software continuation and is what a builder should
pin. Note that **Debian's packaged `simh` is 3.8.1-6.1 and is built without
SDL/video** — it is too old for the terminal tile and useless for the graphical
one, so the builder must compile Open SIMH from source with `libsdl2-dev`
(`USE_SIM_VIDEO`, `HAVE_LIBSDL`). That is exactly what `bridge-base.sh` already
does for VICE, cap32 and LinApple.

## 3. Streaming path — three options

| Path | Mechanism | Verdict |
|---|---|---|
| **A. Kiosk** | Thin qcow2 overlay on the frozen `bridge-base.qcow2`, own `/etc/bridge/launch.sh` running SIMH full-screen (an xterm for the console station; the SDL window for a GT40 station). Capture = dbus, reset = `loadvm golden`, input = PS/2 keyboard. | **Recommended.** Proven five times; inherits the whole checkpoint/reset/labctl/exec machinery. |
| **B. Host-native + `SH_CAPTURE=x11`** | SIMH under Xvfb on labhost, `x11test` input backend, `fifo` audio. No QEMU at all. | The daemon supports it (`streamhost/src/x11_input.rs`, `streamhost/docs/CONFIG.md`) but **no station uses it today**, X11 capture was measured at 32–43 % of a host core, and `loadvm golden` is lost — reset would fall back to `restart` plus SIMH's own `SAVE`/`RESTORE`. Interesting second attempt, not the first. |
| **C. `SH_CAPTURE=shm` (the `irix` route)** | Patch SIMH to publish a shm framebuffer. | Only if the station ever proves too expensive. Not now. |

**The one wrinkle in path A.** `bridge-base.qcow2` is explicitly frozen and
ships five emulators, none of them SIMH. The builder must therefore install and
build SIMH **into the station's writable overlay**, exactly as `amiga.sh` already
does for FS-UAE ("FS-UAE is NOT baked into the frozen bridge base … this script
`apt-get install -y fs-uae` INTO THE OVERLAY"). Follow that precedent, record
the deviation in `docs/guests/pdp11.md`, and — as `amiga.sh` did — also add
SIMH to `bridge-base.sh` so a from-scratch NVMe rebuild bakes it in.

Window fitting follows the playbook's bridge rule: do not force a
`-resolution` to a raw pixel count; either let the emulator fill the X root, or
shrink the root to the smallest advertised mode that contains a fixed window.

## 4. Which PDP-11, and what runs on it

This decision sets both the media licensing and the exhibit's look.

| Option | Media / licence class | Exhibit |
|---|---|---|
| **Unix V6 / V7** (11/40, RK05) | **Ancient Unix under the 2002 Caldera licence — freely redistributable.** The cleanest legal story in the whole collection. | `#` prompt, `ed`, `cc`, the 1976 source tree. Text only. |
| **2.11BSD** (11/70, RQ disks) | TUHS `2.11BSD_patch457/tape0.bz2`; prebuilt `.dsk` images from sergev.org and ak6dn. Root, empty password. Preservation class. | The most *usable* PDP-11: `vi`, `csh`, man pages, TCP/IP. Text only. |
| **RT-11 5.3 / RSX-11M 4.3 / RSTS/E 9.6** | **Mentec hobbyist licence**: no-cost, non-commercial, **emulation only, not on real hardware**. Mentec hosts nothing; images come from third parties. Same "private collection" stance the repo already takes for OS/2, Win9x and Kickstart — but note the gallery is publicly viewable at `gallery.example.com`. | RT-11's `.` prompt is the iconic DEC minicomputer feel; RSX-11M is the VMS ancestor. |
| **GT40 / VT11 Lunar Lander** | In the SIMH tree (`PDP11/lunar11`); see also [Isysxp/GT40](https://github.com/Isysxp/GT40). Needs the SDL2 display build, `SET CPU 11/70`, DLI + VT enabled. | **The visual showpiece** — 1973 vector graphics, unlike anything else in the lineup. |
| *(bonus)* **PiDP-11 blinkenlight panel** | Jörg Hoppe's BlinkenBone panelsim, a photorealistic 11/40 front panel driven by SIMH. | Could share the kiosk root with the console. Extra scope; park it. |

**Recommendation.** Ship **2.11BSD on an 11/70** as the primary station: best
interactivity, verified ready-made images, boots to a real login. Treat **GT40
Lunar Lander** as an optional second station later — it is a different device set
and therefore a different checkpoint, so it cannot share one. Unix V6 is the
sentimental and legally safest pick but gives a visitor less in 30 seconds.

## 5. Concrete integration sketch

```bash
python3 scripts/tiles-registry.py new pdp11 --tier 2 --archetype mono-terminal --slot auto
# slots 81–124 are taken (gaps at 85–88, 109, 111, 115); next free is 125 → UDP 54125
make tile-registry-check
```

- **Archetype** `mono-terminal` (as `helenos`, `ninefront`) — a glass-TTY
  exhibit. `pointer: none`, keyboard-only, `SH_INPUT_BACKEND=disabled`.
- **Key pacing.** The `SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS` frame-sampling
  trap in playbook §5.1 is an *emulator-frame* problem (MAME, VICE). SIMH's
  console is a pty behind X, so default pacing should be fine — but prove it
  through the UI path, never with `labctl type`, which drops characters while
  printing `ok: typed N chars`.
- **Exec channel.** Copy the kiosks: sshd in the Debian kiosk on a
  namespaced hostfwd (bridge key, root), then reach the SIMH console through
  its pty. 2.11BSD itself has only telnet/rsh, so exec lands in the kiosk, not
  in the guest.
- **Checkpoint.** `resetMode: loadvm`, snapshot `golden`, captured from a **cold boot,
  untouched**, via `scripts/lib/golden-verify.sh pdp11 --bake` then re-verified
  without `--bake`. The internal snapshot covers the disk too, so visitor
  writes to the 2.11BSD filesystem — and any unclean-shutdown fsck — vanish on
  reset.
- **Hand-managed surfaces the registry does not generate**:
  `scripts/build-guests/tiles/pdp11.sh`, `docs/guests/pdp11.md`,
  `docs/lab/ASSETS-MANIFEST.md` + `check-assets.sh` rows (hash the TUHS tape
  locally; a size-only check is a reproducibility gap),
  `scripts/coldboot/bootrec-tiles.conf` arm, and the three compiled-in UI
  files — `spa/src/ui/keyboard/keyboardProfiles.ts` (`OS_FAMILY`),
  `spa/src/scene/machines.ts` (`ASSEMBLIES_BY_TILE`, **registry order, not
  alphabetical**) and `spa/src/scene/machineIdentity.ts`, whose exhaustiveness
  check fails only under `npm run build`, never under vitest.
- **Capacity.** Negligible: a SIMH 11/70 is a rounding error beside the MAME
  stations. Measured kiosk RSS on labhost is 0.7–1.65 GB, all of it QEMU
  kiosk rather than emulator.

## 6. Open questions for the operator

1. **Which OS** — 2.11BSD (recommended), Unix V6, or a Mentec-licensed
   RT-11/RSX image, accepting the hobbyist terms on a publicly reachable
   gallery.
2. **One station or two** — terminal PDP-11 now, GT40 vector Lunar Lander later?
   They cannot share a checkpoint.
3. **The overlay deviation** — confirm SIMH is built into the station overlay
   (with a matching `bridge-base.sh` update for future rebuilds) rather than
   reopening the frozen base.

## Sources

- [PDP-11 — Wikipedia](https://en.wikipedia.org/wiki/PDP-11)
- [Open SIMH](https://github.com/open-simh/simh) ·
  [SIMH fork/licence history](https://en.wikipedia.org/wiki/SIMH) ·
  [Open SimH PDP-11 docs](https://opensimh.org/simdocs/pdp11_doc.html)
- [simh `PDP11/lunar11`](https://github.com/simh/simh/tree/master/PDP11/lunar11) ·
  [simh `display/`](https://github.com/simh/simh/tree/master/display) ·
  [Isysxp/GT40](https://github.com/Isysxp/GT40)
- [MAME and SIMH — MAMEDEV wiki](https://wiki.mamedev.org/index.php/MAME_and_SIMH) ·
  [Driver: Soviet PDP-11s](https://wiki.mamedev.org/index.php/Driver:Soviet_PDP-11s)
- [SIMH software kits / Mentec hobbyist licence](https://simh.trailing-edge.com/software.html) ·
  [RSTS/E — Computer History Wiki](https://gunkies.org/wiki/RSTS/E)
- [2.11BSD on SIMH (sergev.org)](https://sergev.org/pdp11/211bsd) ·
  [ak6dn 2.11BSD images](https://ak6dn.github.io/PDP-11/2.11BSD/)
- [Debian bookworm `simh` package](https://packages.debian.org/bookworm/simh)
- [PiDP-11 manual](https://obsolescence.dev/pidp11/PiDP-11_Manual.pdf) ·
  [BlinkenBone simulated panels](https://retrocmp.com/projects/blinkenbone/simulated-panels/252-blinkenbone-playing-with-the-pdp11-40)
