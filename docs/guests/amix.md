# Amiga UNIX (AMIX) 2.1 — gallery station notes

Status: **BUILT AND PROVEN ON THE SANDBOX RIG** (2026-08-30), registry entry
landed `listing.state=hidden`. **Colour proven 2026-09-01** (branch
`amix-color`): the same pinned binary drives the A2410, and a colour golden is
baked in the `amix-color` sandbox — not yet promoted (see "Ready scene / golden"
and "Open"). Not yet deployed: the pointer is still open.

**Guest:** an emulated **Amiga 3000** (Motorola 68030 + MMU + 68882, 16 MB,
Kickstart 2.04 r37.175) booting **Amiga UNIX 2.1** — Commodore's licensed
**AT&T System V Release 4** port — to the **OPEN LOOK** desktop. **HOST-NATIVE**
per the standing constraint: **FS-UAE 3.2.35 runs directly on labhost** (no
bridge kiosk) inside a pinned Xvfb sized to the emulator window, captured with
the daemon's generic `SH_CAPTURE=x11` backend, input over XTEST.

> Distinct from `amiga` (A500 / Workbench 1.3), `amigaos35` (A4000 / OS 3.5) and
> `aros`. This is the Amiga's Unix road not taken — and it is **OPEN LOOK, not
> Motif**, so it is a genuinely different desktop from `hpuxvue`, `solaris`,
> `tru64` and `aix432`.

## Identity and source

- Public ID / tile directory: `amix`
- Reserved slot / UDP port: `172` / `54172`; Xvfb display `:72`
- Archetype: `beige-tower-crt` (ideal: an Amiga 3000 desktop box)
- Media (staged in the `amix` sandbox, hash-verified, **never committed** —
  `.gitignore` already covers `*.adf` and `*.rom`):

  | Artifact | Source | Bytes | sha256 |
  |---|---|---|---|
  | `amix_2.1_boot.adf.bz2` | amigaunix.com | 772 035 | `5b0a9d98…34ccbbb` |
  | `amix_2.1_root.adf.bz2` | amigaunix.com | 252 823 | `adb24869…4ebf6621` |
  | `amix_2.1_tape_part1.tar.bz2` | amigaunix.com | 28 890 337 | `1427f683…3b01cf59` |
  | `amix_2.1_tape_part2.tar.bz2` | amigaunix.com | 76 205 339 | `ae7b0884…85abed4` |
  | Kickstart 2.04 r37.175 (A3000) | archive.org `commodore-amiga-firmware` | 524 288 | md5 `b5e9a3bf…` (matches item metadata) |

  Sourced from the origin, independently of the Virtual OS Museum — VOM was read
  only to learn *which emulator and machine*, per
  [`../lab/research/vom-reference.md`](../lab/research/vom-reference.md). Their
  prebuilt image was **not** used; this station was installed from media.
- License class: preservation-source, copyrighted (Commodore/AT&T). Fine to hold
  and run in this private, passkey-gated collection; never redistribute the bits.

## Emulator decision

**FS-UAE 3.2.35 — the build this lab already ships**, no new emulator and no new
patch. Built with `FSUAE_STATION=amix build-fsuae-native.sh` so the station gets
its **own copy** of the binary: golden + binary + device set are ONE combination
(AGENTS.md rule 6), and sharing `amigaos35`'s binary would mean a rebuild for one
station orphaning the other's golden.

`amiga_model = A3000` supplies the 68030 + MMU + 68882 the AMIX kernel needs. The
mousehack re-arm patch is irrelevant here (no statefile, and mousehack is an
AmigaOS trap) but stays in the shared build script.

## Installing it — the four traps

The install is a real from-tape install, the way an A3000UX did it. Four things
are not obvious and cost real time if you rediscover them:

**1. `index.tape` is mandatory; the directory fallback is broken.** UAE presents a
host directory as a SCSI tape (`src/scsitape.cpp`). With an `index.tape` it reads
the files named there, one per line, in order. Without one it takes a
directory-scan branch whose filename test is inverted —

```c
if (_tcsicmp (filename, TAPE_INDEX))
        continue;          /* skips everything that is NOT index.tape */
```

— so it finds nothing and the tape reads as **empty, with no error**. Ours lists
the 29 segments `00`–`28` in the order the tape's own `seglist` gives.

**2. There is no FS-UAE-level tape option.** FS-UAE's config layer knows
`hard_drive_N` and `cdrom_drive_N` but nothing about tapes, so the drive goes in
as a raw UAE passthrough:

```
uae_uaehf1 = tape4,ro,TAPE:<host-dir>,0,0,0,512,0,,scsi4
```

**3. The two SCSI IDs are hardcoded in the AMIX installer** and cannot be moved:
**ID 4 = tape**, **ID 6 = target disk**. A disk anywhere else is simply not found.

**4. Floppy swaps need a bound key.** The install asks for the root floppy after
the boot floppy; bind the disk-swapper actions so it is scriptable:

```
floppy_image_0 = <boot.adf>
floppy_image_1 = <root.adf>
keyboard_key_f10 = action_drive_0_insert_floppy_1
```

Answers that shaped this install: keyboard `usa`, **`ufs`** root (the default is
`s5`), 0 MB for AmigaDOS / 2015 MB root / 30 MB swap on a 2 GB disk, package set
**(2) "Everything on the tape"** (296.7 MB — it is the set that guarantees
`Xcore`/`Xbasic`/`olcore`), no passwords on any account, timezone EET, nodename
`amix`, and **Color X Administration → 1) A2410** (it configures the kernel's
`tiga` driver — the X server still needs `-tiga`, see below). The tape restore
runs about **two hours** under emulation; `mkfs` on the 2 GB UFS root is another
20 minutes before it.

## Colour: the A2410 works in the pinned build — the exhibit was monochrome by one flag

**Verdict (2026-09-01, framebuffer-proven):** the FS-UAE 3.2.35 binary this
station already ships **drives the A2410**. AMIX's X server comes up on it at
**1024×768, depth 8 PseudoColor (256 colours)**, and the colour OPEN LOOK
desktop renders — see the acceptance capture in the `amix-color` sandbox
(`/data/vms/sandbox/amix-color/rig/r4c.png`: SteelBlue workspace, grey OPEN LOOK
frames with a blue focus header, the Calculator and xclock in colour;
`xdpyinfo` on that display, read back from the guest disk: `dimensions:
1024x768`, `depths (1): 8`, `class: PseudoColor`, `size of colormap: 256`).
No new emulator, no backport, no patch.

The previous verdict ("compiled in, never called") was wrong, and it is worth
recording *how* it went wrong so nobody repeats it:

1. **The grep was lying.** `src/gfxboard.cpp` is ISO-8859 text (the board table
   spells "Ingenieurbüro Helfrich" in Latin-1). The agent shell's `grep` is
   **ugrep with `-I`**, which silently treats that file as *binary* and reports
   **no matches at all** — for any pattern. Run `/bin/grep -a` (or `awk`) and
   the dispatch is right there: `gfxboard.cpp:359/491/501/1739/1766` branch on
   `GFXBOARD_A2410` into `tms_toggle` / `tms_hsync_handler` /
   `tms_vsync_handler` / `tms_free` / `tms_reset`, and `expansion.cpp:2238`
   installs `tms_init` as the card's autoconfig init. The A2410 functions are
   named `tms_*`, not `a2410_*`, which is why the symbol-name grep found
   "nothing calls a2410_*" — literally true, and meaningless.
2. **Nobody had asked the X server for the board.** `/usr/X/bin/X` and
   `/usr/X/bin/X2410` are **byte-identical** (same size, same checksum on the
   tape, `cmp` clean): one server that drives the Amiga chipset by default and
   the A2410 only when started with **`-tiga`** (the amigaunix.com wiki's
   `olinit -- -tiga`; `-tm 3` selects 800×600 instead of 1024×768). The
   installer's "Color X Administration → A2410" step configures the kernel
   (`/dev/tiga0` + the `tiga` driver, `PRODUCT 0x04060000` = Lowell 1030/0,
   exactly what `tms_init` autoconfigs), but the inittab line this station
   wrote ran `X` with no `-tiga`, so it painted on the chipset — and then the
   log's missing `A2410 ACTIVE` line was read as "the emulator cannot", when it
   meant "the guest never tried".

So the chain that had to hold, and does: kernel sees the board (autoconfig
`Card 1: Z2 0x00e90000 64K IO A2410`; guest `tiopen` → `autocon(0x04060000)`)
→ `X -tiga` downloads `tigagm.coff` into the TMS34010 (log: `TMS34010
started`, `A2410 0*0 -> 1024*768`, `A2410 ACTIVE=1`) → the RTG path FS-UAE
already has for `uaegfx` shows the board's 8-bit CLUT surface
(`RTG conversion: Depth=4 … P96RGBF=1`) → clients draw in colour.

What it costs: the TMS34010 core runs per scanline, so the emulator sits at
**~155–170 % of a core with the board active versus ~120–128 % chipset-only**
(measured side by side on labhost, `top`, both stations idle at the desktop).
The standby `SIGSTOP` still applies, so only a live visit pays it. The board's
hardware cursor is a stub in FS-UAE (`-- stub -- setupcursor`) — irrelevant
here, the X server draws its own.

What the mono build got right: monochrome 640×512 *is* what almost every
A3000UX owner saw, since the A2410 was a rare option. The colour golden keeps
the mono session alongside as `/etc/kh-xsession.mono`; switching back is the
inittab `-tiga` flag and that file.

**Lesson, rewritten:** the previous section blamed the symbol table for lying.
It did not; the *tool* lied (ugrep's binary heuristic) and the *test* was wrong
(no `-tiga`). Rule 9 still stands — the framebuffer decided it both times — but
"the framebuffer says no" only closes a question when the guest was actually
asked to draw. Use `/bin/grep -a` on emulator sources; they are not UTF-8.

## Ready scene / golden

Two goldens exist, one combination each with the same binary and device set:

| golden | X server | screen | where |
|---|---|---|---|
| `amix-system.hdf.golden` (2026-08-30) | `X` on the Amiga chipset | 640×512, depth 1 | `/data/vms/sandbox/amix/rig/` — what the registry ships today |
| `amix-system.hdf.golden-color-20260901` | `X -tiga` on the A2410 | 1024×768, depth 8 | `/data/vms/sandbox/amix-color/golden/` — baked from a copy of the mono golden; **promotion pending** |

- Ready state (both): the OPEN LOOK desktop, up **without a login**, holding an
  xterm titled `Amiga UNIX 2.1` that opens with
  `UNIX_System_V amix 4.0 2.1 0800430 Amiga (Unlimited) m68k` over a root shell,
  the OPEN LOOK Calculator, and `xclock`.
- Started from `/etc/inittab` (entry `xw`, run level 2, `respawn`):
  `xinit /etc/kh-xsession -- /usr/bin/X11/X` (mono) or
  `… -- /usr/bin/X11/X -tiga` (colour). `/etc/kh-xsession` runs the three
  clients and `exec olwm`; `/etc/kh-shell` prints `uname -a` and `exec /bin/sh`.
- The colour session additionally does `xrdb -merge /etc/kh-xres`
  (`*windowFrameColor: gray82`, `*inputWindowHeader: SteelBlue4`,
  `*pointerFocus: true`) and `xsetroot -solid SteelBlue`; the clients carry
  their own colours (`xclock -bg LightYellow -hd black -hl red`,
  `xcalc -bg gray85`, xterm black on white at `+40+120`, 80×24, so the pointer's
  initial position — screen centre — is inside it and it has keyboard focus
  from the first frame). The mono session is kept as `/etc/kh-xsession.mono`.
- **To ship colour, three things outside the guest change** (not on this
  branch — the launcher and `runtime` are being edited by the pointer work and
  the operator coordinates the merge):
  1. `streamhost/stations/amix/x11-runtime.sh` passes `--gfxcard_type=A2410
     --gfxcard_size=2` and **drops `--stretch=1`** (the board surface is
     already window-sized; stretching would only matter during the boot
     console);
  2. `runtime.x11.geometry` / `FSUAE_NATIVE_GEOM` become **`1024x768`** (or
     `800x600` with `-tm 3` on the X line, if the tile wants a smaller stream);
  3. `disk/amix-system.hdf.golden` is replaced by the colour golden (keep the
     mono one alongside, dated — never retire a golden before its replacement
     is proven on the live station, rule 6).
  Until then the chipset screen (640×512) is what streams; during the ~2-minute
  boot the visitor sees the Amiga console text, then FS-UAE switches the window
  to the board surface the moment `X -tiga` programs the mode.
- `stretch = 1` (`FSE_STRETCH_FILL_SCREEN`) on the mono build — without it
  FS-UAE letterboxes the 640×512 screen inside its own 640×512 window and the
  capture carries bars.
- Reset mode: `relaunch`, **no statefile** — a cold boot of a fresh work HDF
  copied from the golden (~2 min to the mono desktop; the colour golden, booted
  unattended from a fresh copy on 2026-09-01, had the board active at 60 s and
  the full desktop by 90 s). The standby SIGSTOP keeps visits instant; only a
  reset pays the boot.
- **BAKE RULE: halt the guest with `/sbin/shutdown -y -g0 -i0` before copying the
  golden.** UFS carries no dirty flag the host can repair, so a golden captured
  from a killed emulator makes *every* visitor's boot run a full fsck — about
  4 minutes instead of 2. Note `/usr/ucb/shutdown` is a different, BSD-flavoured
  command that rejects `-y -g0 -i0`; use the absolute path.
- The proof gate is the captured framebuffer through streamhost, never logs.
- Driving the guest from the rig with `xdotool`: the OPEN LOOK xterm only takes
  keyboard focus from a click on its **header**, and a `click` that presses and
  releases within a millisecond is lost — use `mousedown; sleep 0.2; mouseup`.
  While `X -tiga` runs, **it owns the keyboard**; the chipset X's windows keep
  their focus but receive nothing until the board server exits. AMIX's
  ALT-F<n> console-group switch does not work from under X.

## The pointer is not 1:1 — OPEN

Motion reaches the guest, but not absolutely. `amigaos35` gets a 1:1 pointer from
the UAE **mousehack**, which is an AmigaOS-level trap: the guest OS registers a
block and UAE writes host coordinates into it. AMIX never registers — it drives
the Amiga mouse hardware directly — so host motion arrives as **relative,
accelerated deltas**, and the guest cursor's position depends on history.

Measured on the sandbox rig at a matched 640×512 Xvfb and window:

| host XTEST position | guest cursor |
|---|---|
| (160, 120) | ~(82, 92) |
| (480, 380) | ~(331, 345) |

The registry declares `x11test` / absolute because that is the **daemon's**
injection contract (`InputBackend::pointer_mode()` in
`streamhost/streamhost/src/config/backends.rs` makes `x11test` absolute, and the
registry validator enforces it) — it is not a claim about the guest. Closing this
needs one of:

- a **relative XTEST backend** in the daemon (`XTestFakeRelativeMotionEvent`),
  which would be the fleet's first x11-capture + rel-pointer station — no
  existing station pairs those; `dbus-rel` (`aux`, `sunos414`, `macos9`) is the
  QEMU path, and
- or FS-UAE **grab-mode** calibration, where the emulator warps the host pointer
  and feeds unaccelerated deltas.

Keyboard is unaffected and works (XTEST, paced).

## Open

1. **The pointer**, above. The tile stays `hidden` until it is closed.
2. **Promote the colour golden** — operator's call, but no longer a technical
   one: colour is proven on the pinned binary (above), the golden is baked, and
   what remains is the launcher/geometry/golden swap listed under "Ready scene".
   Monochrome stays the authentic fallback and is one flag away.
3. **The 2.1p2a patch disk** (archive.org, 872 196 B) is not applied. VOM runs
   2.1c/2.1p2a; this install is stock 2.1 (`0800430`).
4. **Retronet.** AMIX has an SVR4 TCP/IP stack and FS-UAE emulates the A2065
   Ethernet card the A3000UX used, so a web-plane join is a real follow-up. The
   install deliberately declined the hosts-file step.
5. **The golden is ~150 MB larger than it needs to be** — package set (2) pulled
   in the `amigasrc`/`gnusrc`/`Xsource`/`X11r5src` trees, which the exhibit does
   not use. A custom selection would trim it if the size ever matters.
