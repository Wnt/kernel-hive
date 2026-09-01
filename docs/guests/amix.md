# Amiga UNIX (AMIX) 2.1 — gallery station notes

Status: **BUILT AND PROVEN ON THE SANDBOX RIG** (2026-08-30), registry entry
landed `listing.state=hidden`. Not yet deployed: the golden lives in the `amix`
sandbox, and two things are open (the pointer, and the monochrome-vs-colour
call) — see "Open" at the bottom.

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
  640×512 screen inside its own 640×512 window and the capture carries bars.
- Reset mode: `relaunch`, **no statefile** — a cold boot (~2 min to the desktop)
  of a fresh work HDF copied from `disk/amix-system.hdf.golden`. The standby
  SIGSTOP keeps visits instant; only a reset pays the boot.
- **BAKE RULE: halt the guest with `/sbin/shutdown -y -g0 -i0` before copying the
  golden.** UFS carries no dirty flag the host can repair, so a golden captured
  from a killed emulator makes *every* visitor's boot run a full fsck — about
  4 minutes instead of 2. Note `/usr/ucb/shutdown` is a different, BSD-flavoured
  command that rejects `-y -g0 -i0`; use the absolute path.
- The proof gate is the captured framebuffer through streamhost, never logs.

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
2. **Monochrome or colour** — operator's call. Monochrome is authentic and ships
   today; colour costs a new pinned emulator build with working A2410 emulation
   and is unverified.
3. **The 2.1p2a patch disk** (archive.org, 872 196 B) is not applied. VOM runs
   2.1c/2.1p2a; this install is stock 2.1 (`0800430`).
4. **Retronet.** AMIX has an SVR4 TCP/IP stack and FS-UAE emulates the A2065
   Ethernet card the A3000UX used, so a web-plane join is a real follow-up. The
   install deliberately declined the hosts-file step.
5. **The golden is ~150 MB larger than it needs to be** — package set (2) pulled
   in the `amigasrc`/`gnusrc`/`Xsource`/`X11r5src` trees, which the exhibit does
   not use. A custom selection would trim it if the size ever matters.
