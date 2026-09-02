# Amiga UNIX (AMIX) 2.1 — gallery station notes

Status: **LIVE AND LISTED** — deployed to the box 2026-09-01
(`main@fa9e78b3`), promoted out of dark launch 2026-09-02. The two ready-scene
defects found that morning (a nondeterministic scene, and no keyboard focus on
arrival) are fixed in the `golden-scene-20260902` golden — see "Ready scene /
golden"; the cutover is the operator's. Both things that
were open at the first landing are closed: the **pointer is absolute and 1:1**
(`x11warp` into the guest's own X server — see "The pointer", 0 px residual),
and the exhibit **ships in colour** (the A2410 driven by `X -tiga` at
1024x768x8 — see "Colour"). Those two were baked into SEPARATE goldens by
parallel work; the shipping golden (below) is the unified one carrying BOTH,
and neither half was shippable alone.

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
| `amix-system.hdf.golden-color-20260901` | `X -tiga` on the A2410 | 1024×768, depth 8 | `/data/vms/sandbox/amix-color/golden/` — baked from a copy of the mono golden; colour only, no pointer network |
| `amix-system.hdf.golden-20260901-x11warp` | `X` on the chipset | 640×512, depth 1 | `/data/vms/sandbox/amix/rig/` — mono plus the pointer network (hosts, aen0, xhost) |
| `amix-system.hdf.golden-unified-20260901` | `X -tiga` on the A2410 | 1024×768, depth 8 | `/data/vms/sandbox/amix/rig/`, sha256 `0da364ed…` — shipped 2026-09-01: the colour golden plus the pointer network, `xhost +slirphost` in both `/etc/kh-xsession` and `/etc/kh-xsession.mono`; halted per the bake rule |
| **`amix-system.hdf.golden-scene-20260902`** | `X -tiga` on the A2410 | 1024×768, depth 8 | `/data/vms/sandbox/amix/rig/`, sha256 `8c2e175c…` — **the one to ship**: the unified golden with the deterministic `/etc/kh-xsession` (olwm first, xterm frame over the origin); the previous session kept as `/etc/kh-xsession.20260901`; halted per the bake rule |

- Ready state (both): the OPEN LOOK desktop, up **without a login**, holding an
  xterm titled `Amiga UNIX 2.1` that opens with
  `UNIX_System_V amix 4.0 2.1 0800430 Amiga (Unlimited) m68k` over a root shell,
  `xcalc` — stock X11, but wearing OPEN LOOK's rounded buttons rather than the
  square Athena ones it has elsewhere in the gallery — and `xclock`.
- Started from `/etc/inittab` (entry `xw`, run level 2, `respawn`):
  `xinit /etc/kh-xsession -- /usr/bin/X11/X` (mono) or
  `... -- /usr/bin/X11/X -tiga` (colour). `/etc/kh-shell` prints `uname -a`
  and `exec /bin/sh`. `scripts/build-guests/tiles/amix.sh scene` prints every
  scene file byte for byte.
- **`/etc/kh-xsession` starts olwm FIRST and the clients only once olwm is
  managing.** It does `xrdb -merge /etc/kh-xres` (`*windowFrameColor: gray82`,
  `*inputWindowHeader: SteelBlue4`, `*pointerFocus: true`) and
  `xsetroot -solid SteelBlue`, then `exec olwm` with a background subshell
  that polls `xprop -root OL_MANAGER_STATE` — the property this olwm
  publishes on the root once it owns SubstructureRedirect — and only then
  runs `xclock -bg LightYellow -hd black -hl red -geometry 120x120+860+30`,
  `xcalc -bg gray85 -geometry +640+60`, the xterm (black on white, **86x30 at
  `+0+0`**) and `xhost +slirphost`, each client with its stderr in
  `/tmp/<client>.err` (olwm's in `/tmp/olwm.err`) for the next investigator.
  A condition, not a sleep; bounded at
  120 s so a broken olwm still leaves a screen. The two rules baked in here
  were both paid for on the live station on 2026-09-02:
  1. **Clients started before olwm race it.** The previous script spawned the
     three clients and `exec olwm` three seconds later (the guest's own log:
     clients at :01, olwm at :04). On a 25 MHz emulated 68030 that is exactly
     the window in which a client maps, so each boot rolled the dice per
     window: one that mapped before olwm's adoption scan was ADOPTED — client
     kept at its requested spot, frame header stacked 27–30 px above it —
     while one that mapped later went through MapRequest and had its FRAME
     placed at the requested spot. Same script, two placements (xterm frame
     at row 89 or 119, Calculator at row 29 or 59, seen on separate fresh
     sessions), and about one boot in five lost `xclock` outright. With olwm
     managing first, every window takes the MapRequest path, every time.
  2. **The xterm's frame covers the origin AND the screen centre.** Focus
     follows the pointer, and where the pointer is on arrival is decided
     outside the guest: the X server starts it at the centre `(512,384)`, and
     the daemon's x11warp worker restates its browser-truth target — zero
     until a visitor moves — on every (re)connect, so on the live station the
     first thing streamhost does after `xhost` lets it in is warp to `(0,0)`.
     Over the root, nothing has the keyboard. olwm's pointer focus treats the
     whole frame as the client (proven: keys typed with the pointer on the
     header, the resize corner and the bottom edge all landed in the shell;
     on the root they landed nowhere), so an xterm whose frame includes both
     points holds the keys whichever way the pointer arrives — and the guest
     never warps or grabs anything itself, so nothing fights the daemon.
     Click-to-type was measured and rejected: at arrival the Calculator took
     the keys, and a click in the xterm's **pane** did not move focus (only a
     header click does), so a visitor who touched the Calculator once would
     have lost the shell. The mono session is kept as
     `/etc/kh-xsession.mono`, which is what makes monochrome a one-line
     revert rather than a rebuild.
- **Shipping colour changes three things outside the guest:**
  1. `streamhost/stations/amix/x11-runtime.sh` passes `--gfxcard_type=A2410
     --gfxcard_size=2` and **drops `--stretch=1`** (the board surface is
     already window-sized; stretching would only matter during the boot
     console);
  2. `runtime.x11.geometry` / `FSUAE_NATIVE_GEOM` become **`1024x768`** (or
     `800x600` with `-tm 3` on the X line, if the tile wants a smaller stream);
  3. `disk/amix-system.hdf.golden` is replaced by the colour golden (keep the
     mono one alongside, dated -- never retire a golden before its replacement
     is proven on the live station, rule 6).
  During the boot the visitor sees the Amiga console text, then FS-UAE switches
  the window to the board surface the moment `X -tiga` programs the mode.
- On the MONO build only: `stretch = 1` (`FSE_STRETCH_FILL_SCREEN`) -- without
  it FS-UAE letterboxes the 640x512 screen inside its own 640x512 window and the
  capture carries bars -- **and `zoom = 640x512`**, without which the default
  `692x540` crop scales the X root by 0.925/0.948 and the pointer is not 1:1 in
  the capture even though `XQueryPointer` agrees exactly (see the pointer
  section: the readback is not sufficient proof on its own).
- Reset mode: `relaunch`, **no statefile** -- a cold boot of a fresh work HDF
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

## The pointer is absolute, through the guest's own X server

Motion is **1:1 and closed-loop**, and it never touches the emulated mouse.
`amigaos35` gets its pointer from the UAE **mousehack**, an AmigaOS-level trap:
the guest OS registers a block and UAE writes host coordinates into it. AMIX
never registers — it drives the Amiga mouse hardware itself — so any XTEST
motion into the host Xvfb, absolute or relative, reaches the guest as
**accelerated relative deltas** (measured on the first rig: host (160,120) →
guest ~(82,92), host (480,380) → guest ~(331,345), history-dependent; 3 px
steps are 1:1, 5 px steps are already ~1.2×). No mapping through that path is
invertible, so the path is not used for motion at all.

Instead the station does what `sunos414` does: **the guest's own X11R4 server
is both actuator and sensor.** `XWarpPointer` moves the pointer to an absolute
root coordinate and `XQueryPointer` reads the guest's own answer back. Three
pieces make the server reachable, and none of them is a retronet join:

1. **The A2065 on slirp.** `--uae_a2065=slirp` autoconfigures the Z2 Ethernet
   card the A3000UX shipped with; AMIX's `aen` driver attaches it as `aen0`.
   `/etc/inet/rc.inet` already runs ``ifconfig aen0 `uname -n` `` at boot, so
   the interface takes whatever `/etc/inet/hosts` says `amix` is — in the
   stock install that was `127.1` (which is why `netstat -in` showed `aen0`
   at 127.0.0.1). The golden now carries `10.0.2.15 amix` and
   `10.0.2.2 slirphost`; **no default route is added**, so nothing off
   10.0.2.0/24 ever leaves the guest.
2. **A loopback-only redirect.** Stock FS-UAE 3.2.35 *parses*
   `slirp_redir` and then drops it (`uae_slirp_redir` is a stub under the
   vendored libslirp — the source says `FIXME: Add redir functionality!`).
   `scripts/build-guests/emulators/fsuae-native.d/fsuae-slirp-hostfwd.patch`
   forwards it to `slirp_add_hostfwd`, **bound to 127.0.0.1 by construction**
   — the LAN cannot reach the guest's X server whatever the config says. The
   launcher passes `--uae_slirp_redir=tcp:6072:6000:10.0.2.15` (host port =
   6000 + the display number in `SH_X11WARP_DISPLAY=127.0.0.1:72`), and the
   emulator logs `[SLIRP] hostfwd tcp 127.0.0.1:6072 -> 10.0.2.15:6000 rc=0`
   when the guest driver opens the card. **This is a binary change**: the
   station's own copy under `assets/amix/fsuae-native` must be built with
   the patch (`FSUAE_STATION=amix build-fsuae-native.sh`), and golden +
   binary + device set move together (rule 6).
3. **The X grant.** X11R4 listens on TCP `*:6000` by default and keeps
   access control on; `/etc/kh-xsession` runs `/usr/bin/X11/xhost +slirphost`
   before `exec olwm` — scoped to the one peer that can reach it, never
   `xhost +`.

### How the daemon uses it

`SH_INPUT_BACKEND=x11test` still, with **`SH_X11TEST_MOTION=warp`**: the
`x11test` sink sends *no* XTEST motion at all and hands every target to an
inner `x11warp` sink (`streamhost/streamhost/src/x11_warp.rs`) on
`SH_X11WARP_DISPLAY`. Buttons and keys keep riding XTEST into the Xvfb (the
Amiga mouse buttons and keyboard work fine that way), which makes this a
two-channel pointer like sunos414's — so the pacer holds every **button edge**
on the warp sink's gate until the guest's `QueryPointer` confirmed the pointer
is at the target, injects it, and only then signals `edge_done()` to release
the armed motion hold. A warp the guest refuses to confirm is a counted
give-up and the click is rejected loudly, never landed somewhere else.

**Single injector.** Nothing else may move this guest's pointer: no
`xdotool mousemove` on the live Xvfb, no relative fallback. The relative path
still exists in the emulator and would silently desynchronise the readback.

**Degraded mode.** The pointer exists only while the guest X server does —
about two minutes of cold boot, and never at the console. The launcher's
`x11warp-check.log` says `ok`, `STALE GOLDEN` (the server refused the slirp
peer: the hosts/xhost state is missing → re-bake) or `TIMED OUT`; the daemon's
sink reports `BackendDown` independently and drops motion, counted.

### Evidence — shipping binary, unified colour golden, 1024×768 (2026-09-01)

Binary `assets/amix/fsuae-native/bin/fs-uae` sha256 `38c54495…`, built from
the merged source; guest `X -tiga` on the A2410 (the board's X server listens
on the same TCP `:6000` the redirect targets). Every target warped through the
loopback redirect, read back with `XQueryPointer`, and the frame captured from
the 1024×768 Xvfb.

**Readback:** exactly the target at all 16 points — corners `(0,0) (1023,0)
(0,767) (1023,767)`, centre `(512,384)`, and `(1,1) (20,20) (160,120)
(480,380) (100,400) (600,50) (330,266) (1000,740) (1022,766) (5,500)
(1018,300)`.

**Framebuffer:** the colour arrow's bounding box starts at `(target, target+1)`
in every root-area frame (its first opaque row is one below the hotspot), the
clipped corner remnants sit exactly in the corners, and the I-beam over the
xterm is centred on the target:

| target | readback | sprite bbox origin | glyph |
|---|---|---|---|
| (600,50) | (600,50) | (600,51) 16×15 | arrow, hotspot on target |
| (1000,740) | (1000,740) | (1000,741) | arrow |
| (5,500) | (5,500) | (5,501) | arrow |
| (20,20) | (20,20) | (20,21) | arrow (montage) |
| (1018,300) | (1018,300) | (1018,300) 6×10 | arrow, clipped right |
| (1023,0) / (0,767) / (1023,767) / (1022,766) | exact | (1023,0) / (0,767) / (1023,767) / (1022,766) | corner remnants |
| (160,120) | (160,120) | (157,114) 7×13 | I-beam centred on (160,120) |
| (330,266) | (330,266) | stem at x=330, y 260–271 | I-beam centred on (330,266) |

**Residual error: 0 px.** xterm hides its pointer after keystrokes until real
motion, so four interior targets show no sprite at all — the readback and the
two I-beam frames stand for them. **Buttons:** a warp to xcalc's `7` key at
`(701,236)` plus an XTEST click (held 300 ms) put `7` on the calculator's
display. **Keys:** with the pointer warped into the xterm (`*pointerFocus:
true`), `echo ok-KEYS` printed `ok-KEYS`. Frames, `sweep.csv`, `montage.png`
and the raw-X probe are retained in `/data/vms/sandbox/amix-cursor/rig3/`
(the earlier mono proof, identical in method and also 0 px, in `rig/` and
`rig2/`).

### The capture must be 1:1 too

On the mono chipset screen the first sweep had every readback exact and the
sprite still off by up to 45 px at the far edge: FS-UAE's non-legacy *default*
zoom is the fixed `692x540` mode, so the 640×512 root was drawn at 0.925/0.948
scale, offset `(24,13)` — and the visitor clicks in capture space. **In RTG
mode (the A2410) no zoom mode applies and the board surface is shown 1:1 in a
window of its own size**, which the sweep above measured; `--stretch` is
dropped for the same reason. `--zoom=640x512` stays only for the chipset
console the visitor sees during boot (its own rectangle, `74 36 640 512`,
measured with a one-off diagnostic build). `stream.pointer.scale=1.0 /
offset=[0,0]` is therefore true, not decorative.

### Probing the pointer channel: standby looks EXACTLY like a dead channel

**A connect timeout on `127.0.0.1:6072` is most often the station working
correctly.** The station SIGSTOPs its emulator after ~60 s idle
(`SH_IDLE_PAUSE_SECS=60`, `SH_IDLE_PAUSE_WARMUP_SECS=200`), and a frozen
`fs-uae` cannot service the slirp redirect it owns. So the socket stops
answering, `xwarp.py` times out, and the symptom is indistinguishable from a
pointer channel that has died — while `systemctl is-active` says `active`, the
daemon logs `backend-down=0`, and `x11warp-check.log` still shows its last
`ok`. Check `/proc/<pid>/status` for `State: T (stopped)` before concluding
anything. Either probe inside the warmup window after a restart, or wake the
station first. This is the lab's recurring shape — a frozen guest answering
nothing while every upstream indicator stays green.

Two more things that make a healthy pointer look broken:

- **`xdotool` cannot drive this guest at all.** X11R4 (1992) predates the XTEST
  extension; `xdotool` warns `XTEST extension unavailable` and then
  **segfaults** rather than falling back to `XWarpPointer`. This says nothing
  about the station: the daemon never uses XTEST for motion either — it calls
  `XWarpPointer` directly, which is the whole design. Use
  `/data/vms/sandbox/amix-cursor/rig3/xwarp.py` (~30 lines, stdlib sockets,
  speaks the X protocol directly — no `python-xlib`, nothing to install).
- **Do not test over the xterm.** `xterm` hides its pointer sprite after
  keystrokes, so a warp into it can produce an exact `QueryPointer` readback and
  a frame with no visible cursor — a correct station that reads as a regression.
  Test on the root background (RGB `70,130,180`); `(700,600)`, `(300,600)`,
  `(900,650)` and `(850,450)` are clear of every window in the ready scene.
  Correct is sprite bbox origin at **`(target_x, target_y + 1)`** — the arrow's
  first opaque row sits one pixel below the tip. That IS the 0 px baseline.

### Acceptance of the scene golden (2026-09-02)

`golden-scene-20260902`, cold-booted from a fresh copy on the shipping binary
in the `amix-scene` rig (`/data/vms/sandbox/amix-scene/rig/`, `fixboots.log`
and the `fb*.png` frames): **12 consecutive boots, 12/12 with all three
clients in the framebuffer** — xclock in its region, Calculator frame at row
59, xterm frame at row 0 — the desktop condition (steel-blue root at two probe
points plus the three windows) met 62–81 s after launch, X answering the
redirect 4–8 s earlier. On every boot `echo typed-fbN` was typed through the
host Xvfb **without moving the pointer** and landed in the shell (the
`fb*k.png` frames). Pointer sweep on the same golden: readback exact at all
ten targets, sprite bbox origin at `(target, target+1)`, 16×15, at
`(700,600) (300,600) (900,650) (850,450) (5,500) (600,50)`; corner remnants
at `(1023,0) (0,767) (1023,767)`; `(0,0)` sits on the xterm's frame corner —
0 px residual, unchanged from the 2026-09-01 sweep.

The honest count behind it: across every boot of the fixed session (two
harness runs) it is 14 complete scenes in 15. The one loss — `fb3` of the
first run, before the session wrote stderr files — came up with xclock and
the Calculator and **no xterm process at all**: the client exited during
startup, with olwm already managing (so not the placement race). The stderr
files were added for exactly that case and have been empty in every boot
since. The hypothesis tested next — that the slirp peer's connection attempts,
**refused** by the server until `xhost` runs (the harness and the live daemon
both knock from the moment X answers), hit X11R4's refusal path while the
clients are connecting — did not hold: 8 boots knocking every 250 ms
(`stressboots.log`, ~8× the rate) were 8/8 complete. So the fixed session
stands at 22 complete scenes in 23 boots, the last 20 consecutive, against
the old session's ~1 loss in 5; the single early-exit remains an open item
below, with the stderr files in the golden as the trap for it.

### Two emulators on one Xvfb look like a console with the desktop running

A frame showing the chipset console (`The system is coming up. Please wait.`)
while the guest's own process list shows X, olwm and all three clients alive
is not a flapping session — it is a **second emulator** painting its boot
console over the first one's window on the same display. It happened on the
`amix-scene` rig on 2026-09-02 when two copies of the acceptance loop were
started against one rig: both claimed `:83`, the second's `hostfwd` on 6083
failed silently, and every "desktop" query answered from the first while
every frame came from the second. Before reading such a frame, list the
emulators by `/proc/<pid>/exe` and their config path; one rig, one `fs-uae`.

### Boot behaviour, and the console-VT anomaly

The unified golden, cold-booted **8 times in a row** from a fresh copy on the
shipping binary: the board's X server answered the redirect at 45, 52, 51, 53,
52, 51, 52, 52 s after launch, and a frame 40 s later showed the colour desktop
(steel-blue root at two probe points) **8/8 times**. During the first ~50 s the
visitor sees the chipset console text by design — that is "still booting", not
the anomaly below.

**The console-VT anomaly (mono goldens only, so far).** On the mono x11warp
golden, 1 boot in 4 had the chipset X server answering queries while the
display showed the console VTs (`cons`/`con5`/`con7 login:`) instead of the
desktop — X did not own the visible VT; the launcher's handshake check passes
in that state. It did not recur in 5 further mono boots on the shipping binary
(6/6 clean including the sweep boot) nor in any of the 8 colour boots, where
the board owns the display and the chipset VTs are irrelevant to what the
visitor sees. Rate observed: mono 1/10 overall, colour 0/8. If a visitor ever
sees a login banner with a working pointer on the colour exhibit, this is it —
reset the station, and raise the count here.

**Hero image:** `/data/vms/sandbox/amix-cursor/rig3/hero-1024x768.png`, a
clean 1024×768 capture of the finished colour desktop (pointer parked in the
bottom-right corner).

### Driving this guest by hand (what the bring-up taught)

- **Focus follows the pointer** (`*pointerFocus: true`), and olwm counts the
  frame as the window. Under click-to-type (the mono era) a click in an
  xterm's text area did not move keyboard focus; only a click on its header
  did — which is why the colour session does not use it.
- **Relative XTEST motion clamps at the host edge**, and the guest never sees
  the clamped part. To put the guest pointer somewhere known without the warp
  channel: warp the *host* pointer into a corner (the guest pointer clamps
  into the same corner), then walk in 3 px steps, which are 1:1.
- `xdotool type` does not transmit newlines; one `type` per line plus
  `key Return`. The SVR4 shell has no `$( )`; SVR4 `grep` has no `\|`.

## Open

1. **The daemon restates `(0,0)` on connect.** `x11_warp.rs` seeds its
   browser-truth target at zero and warps there the moment it reaches the
   guest X server, on every reconnect. The scene absorbs it (the xterm's frame
   covers the origin), but it is the daemon deciding where a visitor's pointer
   starts; a centre default would match what the X server itself does.
2. **One client exit in 23 boots of the fixed session is unexplained.** `fb3`
   of the first acceptance run (`fixboots-v1.log`, `fb3.png`): olwm managing,
   xclock and the Calculator up, and no xterm process — it exited during
   startup and left nothing (no stderr capture yet on that disk; the golden
   now writes `/tmp/xterm.err` etc.). Not the placement race (olwm was first)
   and not refused peer connections (stress-tested 8/8). If a visitor ever
   meets a two-client scene on the new golden, read those files before the
   next reset overwrites the disk, and raise the count here.
3. **Instrumented boots of the OLD session are in
   `/data/vms/sandbox/amix-scene/rig/diagboots.log`** (per-client exit status
   and stderr, frame classification per boot) for anyone re-deriving the race.
4. **The 2.1p2a patch disk** (archive.org, 872 196 B) is not applied. VOM runs
   2.1c/2.1p2a; this install is stock 2.1 (`0800430`).
5. **Retronet.** The A2065 is up on slirp for the pointer only (host-only,
   loopback-bound, no default route). A web-plane join is a real follow-up;
   note `in.telnetd` listens on 23, so an exec channel is cheap. But see
   `museum.periodBrowser`: a 1992 SVR4 machine has no browser and no ICQ
   client, so a retronet join would show a visitor nothing.
6. **The golden is ~150 MB larger than it needs to be** — package set (2) pulled
   in the `amigasrc`/`gnusrc`/`Xsource`/`X11r5src` trees, which the exhibit does
   not use. A custom selection would trim it if the size ever matters.
