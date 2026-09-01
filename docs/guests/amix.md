# Amiga UNIX (AMIX) 2.1 — gallery station notes

Status: **BUILT AND PROVEN ON THE SANDBOX RIG** (2026-08-30; pointer made
absolute 2026-09-01), registry entry landed `listing.state=hidden`. Not yet
deployed: the golden lives in the `amix` sandbox, and the monochrome-vs-colour
call is open — see "Open" at the bottom.

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
`amix`, and **Color X Administration → 1) A2410** (see below). The tape restore
runs about **two hours** under emulation; `mkfs` on the 2 GB UFS root is another
20 minutes before it.

## The A2410 dead end — why this exhibit is monochrome

AMIX's X server for the Amiga's own chipset is **640×512, depth 1, StaticGray** —
measured with `xdpyinfo`. The server accepts a `-z <planes>` argument but ignores
it on this display. That is not a misconfiguration: on Amiga UNIX, **colour X
means a colour graphics board**, and the installer's own "Color X Administration"
menu offers exactly three — **A2410** (Commodore), Resolver (Digital Micronics),
1600GX (Ameristar) — plus "no color card".

The A2410 is the one FS-UAE appears to offer (`uae_gfxcard_type = A2410`), and
the board does autoconfig: the log shows `Card 1: Z2 0x00e90000 64K IO A2410`.
**It does not work.** In FS-UAE 3.2.35 the TMS34010 core `src/mame/a2410.cpp` is
compiled in — its symbols are in the binary, which is what makes this look
supported — but **nothing anywhere in the tree calls a single `a2410_*`
function**; `gfxboard.cpp` has no A2410 reference at all, and `expansion.cpp`
only supplies the card's autoconfig *name*. Run the guest's `X2410` server and it
paints onto the Amiga chipset screen instead; `A2410 ACTIVE` never appears in the
log. `A2410` is not a documented `uae_gfxcard_type` value either.

**The lesson, and it is the point of AGENTS.md rule 9:** the symbol table said
"supported" and the framebuffer said otherwise. Only the framebuffer was right.

So the shipped exhibit is the monochrome chipset desktop — which is also what
almost every real A3000UX owner saw, since the A2410 was a rare, expensive
option. Getting the colour OPEN LOOK desktop needs an emulator that actually
drives an A2410 (a newer FS-UAE or a WinUAE-derived core such as Amiberry, both
unverified), i.e. a new pinned emulator build, not a config change.

## Ready scene / golden

- Ready state: the OPEN LOOK desktop, up **without a login**, holding an xterm
  titled `Amiga UNIX 2.1` that opens with
  `UNIX_System_V amix 4.0 2.1 0800430 Amiga (Unlimited) m68k` over a root shell,
  `xcalc` — stock X11, but wearing OPEN LOOK's rounded buttons rather than the
  square Athena ones it has elsewhere in the gallery — and `xclock`.
- It is started from `/etc/inittab` (entry `xw`, run level 2, `respawn`):
  `xinit /etc/kh-xsession -- /usr/bin/X11/X`. `/etc/kh-xsession` runs the three
  clients and `exec olwm`; `/etc/kh-shell` prints `uname -a` and `exec /bin/sh`.
- `stretch = 1` (`FSE_STRETCH_FILL_SCREEN`) — without it FS-UAE letterboxes the
  640×512 screen inside its own 640×512 window and the capture carries bars —
  **and `zoom = 640x512`**, without which the default `692x540` crop scales
  the X root by 0.925/0.948 and the pointer is not 1:1 in the capture (see
  the pointer section).
- Reset mode: `relaunch`, **no statefile** — a cold boot (~2 min to the desktop)
  of a fresh work HDF copied from `disk/amix-system.hdf.golden`. The standby
  SIGSTOP keeps visits instant; only a reset pays the boot.
- **BAKE RULE: halt the guest with `/sbin/shutdown -y -g0 -i0` before copying the
  golden.** UFS carries no dirty flag the host can repair, so a golden captured
  from a killed emulator makes *every* visitor's boot run a full fsck — about
  4 minutes instead of 2. Note `/usr/ucb/shutdown` is a different, BSD-flavoured
  command that rejects `-y -g0 -i0`; use the absolute path.
- The proof gate is the captured framebuffer through streamhost, never logs.

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

### Evidence (sandbox rig, 2026-09-01)

Guest booted from the re-baked golden on the patched binary; every target
warped through 127.0.0.1:6078, read back with `XQueryPointer`, and the sprite
located in the captured Xvfb frame with `scripts/dev/cursor-locate.py`.

**Readback:** `XQueryPointer` returned exactly the warp target at all 16
points — the four corners `(0,0) (639,0) (0,511) (639,511)`, the centre,
`(160,120)` and `(480,380)` (the two points the relative pointer had missed
by 60–150 px), and `(1,1) (20,20) (100,400) (330,266) (600,50) (610,480)
(638,510) (5,300) (634,300)`.

**Framebuffer:** in every frame where the sprite is not clipped by the
screen edge, the olwm arrow's bounding box starts at exactly
`(target−1, target−1)` — the X arrow's one-pixel outline around a hotspot at
its tip — and the I-beam over the xterm is centred on the target:

| target | readback | sprite bbox origin | glyph |
|---|---|---|---|
| (320,256) | (320,256) | (319,255) | arrow, tip on target |
| (480,380) | (480,380) | (479,379) | arrow |
| (100,400) | (100,400) | (99,399) | arrow |
| (330,266) | (330,266) | (329,265) | arrow |
| (610,480) | (610,480) | (609,479) | arrow |
| (5,300) | (5,300) | (4,299) | arrow |
| (634,300) | (634,300) | (633,299) | arrow, clipped right |
| (638,510) | (638,510) | (637,509) | arrow, clipped |
| (639,511) | (639,511) | (638,510) | 2×2 remnant in the corner |
| (160,120) | (160,120) | (157,113) 7×14 | I-beam centred on (160,120) |
| (0,0) (1,1) (20,20) (600,50) | exact | — | tip on target, verified by eye (`montage3.png`) |

**Residual error: 0 px.** Frames, `sweep.csv`, the montage and the raw-X
probe (`xwarp.py`) are retained in `/data/vms/sandbox/amix-cursor/rig/`.

### The capture must be 1:1 too — `zoom = 640x512`

The first sweep had every readback exact and the sprite still off by up to
45 px at the far edge. FS-UAE's non-legacy *default* zoom is the fixed
`692x540` mode (crop `48,22,692,540`), so the 640×512 X root was drawn at
0.925/0.948 scale, offset `(24,13)` in the capture — and the visitor clicks
in capture space. The launcher pins `--zoom=640x512` (crop `74,36,640,512`,
measured with a one-off diagnostic build that logs the DIW limits: AMIX's X
server programs exactly `74 36 640 514`), which is the identity mapping the
table above was measured under. `stream.pointer.scale=1.0 / offset=[0,0]` is
therefore true, not decorative.

**One anomaly to watch (1 boot in 4):** one boot of the re-baked golden had
the guest X server answering queries while the chipset display showed the
console VTs (`cons`/`con5`/`con7 login:`) instead of the desktop, i.e. X did
not own the visible VT. The launcher's handshake check passes in that state.
It did not recur across three further boots; if a visitor ever sees a login
banner with a working pointer, this is it — reset the station.

### Driving this guest by hand (what the bring-up taught)

- **olwm focus is click-to-type on the FRAME.** A click in an xterm's text
  area does not move keyboard focus; a click on its header does. The ready
  scene's Calculator holds focus after boot, so typed digits go into it.
- **Relative XTEST motion clamps at the host edge**, and the guest never sees
  the clamped part. To put the guest pointer somewhere known without the warp
  channel: warp the *host* pointer into a corner (the guest pointer clamps
  into the same corner), then walk in 3 px steps, which are 1:1.
- `xdotool type` does not transmit newlines; one `type` per line plus
  `key Return`. The SVR4 shell has no `$( )`; SVR4 `grep` has no `\|`.

## Open

1. **Monochrome or colour** — operator's call. Monochrome is authentic and ships
   today; colour costs a new pinned emulator build with working A2410 emulation
   and is unverified.
2. **The 2.1p2a patch disk** (archive.org, 872 196 B) is not applied. VOM runs
   2.1c/2.1p2a; this install is stock 2.1 (`0800430`).
3. **Retronet.** The A2065 is now up on slirp for the pointer only
   (host-only, loopback-bound, no default route). A web-plane join is a real
   follow-up; note `in.telnetd` listens on 23, so an exec channel is cheap.
4. **The golden is ~150 MB larger than it needs to be** — package set (2) pulled
   in the `amigasrc`/`gnusrc`/`Xsource`/`X11r5src` trees, which the exhibit does
   not use. A custom selection would trim it if the size ever matters.
