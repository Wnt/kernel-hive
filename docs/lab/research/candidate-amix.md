# Amiga UNIX (AMIX) 2.1 — bring-up recon

Status: **DONE — station built.** The narrative, the ready scene, the bake rule
and the open items now live in [`../../guests/amix.md`](../../guests/amix.md);
this file is kept only as the recon record that got there. Both unknowns in
[`../../catalog/candidates-90s-desktops.md`](../../catalog/candidates-90s-desktops.md)
§4 are closed — one of them **against** the candidate note's expectation.

OPEN LOOK on an Amiga 3000 — Commodore's SVR4 port, the "wait, that existed?"
tile. Genuinely a different desktop from the CDE/VUE stations (`hpuxvue`,
`solaris`, `tru64`, `aix432`): OPEN LOOK, not Motif.

## The two open questions, answered

**1. Which emulator, and can we already run it?** FS-UAE — yes for the machine,
**and yes for the colour desktop** (the latter corrected 2026-09-01; the first
answer here was "no", and it was wrong).

The Virtual OS Museum runs its AMIX 2.1c installation under **FS-UAE** on an
**A3000** with an **A2410** graphics board (read from their config as a fact;
nothing copied — see [`vom-reference.md`](vom-reference.md) for the licence
boundary). What that implies for us:

> The **pinned FS-UAE 3.2.35 build we already ship for `amigaos35`**
> (`build-fsuae-native.sh`) runs the A3000 with its 68030 MMU **and** its A2410:
> `uae_gfxcard_type = A2410` is a real, wired board in that tree.

So the **machine** needs no new emulator, no new build and no new patch: AMIX
installs and boots on the host-native x11-capture path `amigaos35` already
proved, and the station ships that way.

**The colour desktop needs no new emulator either.** The 2026-08-30 bring-up
concluded the opposite — "`gfxboard.cpp` has no A2410 reference, nothing calls
`a2410_*`" — and that conclusion came from a tool, not the tree: the agent
shell's `grep` is ugrep with `-I`, and `gfxboard.cpp` is ISO-8859 text, so it was
skipped as binary and every pattern returned nothing. `/bin/grep -a` shows the
`GFXBOARD_A2410` dispatch into the `tms_*` handlers (`gfxboard.cpp:359,491,501,
1739,1766`, `expansion.cpp:2238`). The second half of the mistake was in the
guest: `/usr/X/bin/X` and `X2410` are the same binary and pick the board only
with **`-tiga`**; the station's inittab ran `X` bare, so `A2410 ACTIVE` never
appeared because the board was never asked. With `X -tiga` the pinned binary
logs `TMS34010 started`, `A2410 1024*768`, `A2410 ACTIVE=1` and the framebuffer
shows the colour OPEN LOOK desktop (1024x768, depth 8 PseudoColor). Full chain
and costs in [`../../guests/amix.md`](../../guests/amix.md).

AMIX's own chipset X server is **640x512 depth 1 (StaticGray)**, measured with
`xdpyinfo`; its `-z <planes>` argument is ignored. On Amiga UNIX colour X means
a colour *board* — the installer offers A2410 / Resolver / 1600GX and nothing
else — and the shipped mono exhibit is what nearly every real A3000UX owner
saw.

**The lesson (AGENTS.md rule 9), as it actually reads now:** the framebuffer
was right both times; what was wrong was the *question* put to it (no `-tiga`)
and the *tool* used on the source (a grep that skips Latin-1 files). A `strings`
grep is not a capability test — and neither is a grep that returns nothing.

**2. Is the MMU configuration reachable?** Yes. `amiga_model = A3000` gives the
68030 + 68882 the installer requires, and the AMIX kernel enables the MMU itself
("68030 MMU enabled" is in the binary's own log strings).

## Media — sourced independently, never from VOM

All fetched from the origin, hash-recorded, staged outside the repo. Nothing
here is committed (`.gitignore` covers `*.adf`, `*.rom`).

| Artifact | Source | Bytes | sha256 |
|---|---|---|---|
| `amix_2.1_boot.adf.bz2` | amigaunix.com | 772 035 | `5b0a9d98…34ccbbb` |
| `amix_2.1_root.adf.bz2` | amigaunix.com | 252 823 | `adb24869…4ebf6621` |
| `amix_2.1_tape_part1.tar.bz2` | amigaunix.com | 28 890 337 | `1427f683…3b01cf59` |
| `amix_2.1_tape_part2.tar.bz2` | amigaunix.com | 76 205 339 | `ae7b0884…85abed4` |
| Kickstart 2.04 r37.175 (A3000) | archive.org `commodore-amiga-firmware` | 524 288 | md5 `b5e9a3bf…` (matches item metadata) |

The two tape parts unpack to **29 cpio segments `00`–`28` plus `seglist`**,
which names them in order: `amixlist unixcont core bsd Cdev lp man net public
sysadm terminfo text uucp Xcore Xbasic olcore Xtras Xdev oldev conf emacs games
amigasrc emacsrc gnusrc gnusrc2 pubsrc Xsource X11r5src`. `Xcore`/`Xbasic`/
`olcore` are the X11 + OPEN LOOK sets — the exhibit.

Note archive.org's `commodore-amiga-operating-systems-amix` item carries the 2.1
*floppies* but only the 2.01 and 2.03 *tapes*; the 2.1 tape comes from
amigaunix.com. The `amix-21-a-3000-ux-preconfig` item (a prebuilt 4 GB
SCSI2SD image) exists as a fallback but was **not** used — we install from media.

## The traps, found the hard way

**1. `index.tape` is mandatory — the directory fallback is broken.** UAE tape
emulation (`src/scsitape.cpp`) presents a host directory as a SCSI tape. With an
`index.tape` present it reads the files named there, one per line, in order.
Without one it falls into a directory-scan branch whose filename test is
inverted —

```c
if (_tcsicmp (filename, TAPE_INDEX))
        continue;          /* skips everything that is NOT index.tape */
```

— so it skips every real file and finds nothing. A tape directory without
`index.tape` looks like an empty tape, with no error. Ours is the 29 segment
names, in `seglist` order.

**2. There is no FS-UAE-level tape option.** FS-UAE's own config layer knows
`hard_drive_N` and `cdrom_drive_N` but nothing about tapes, so the drive has to
go in as a raw UAE passthrough. The format, read out of `cfgfile.cpp`:

```
uae_uaehf1 = tape4,ro,TAPE:<host-dir>,0,0,0,512,0,,scsi4
             │     │  │              └ sectors,surfaces,reserved,blocksize,bootpri,filesys
             │     │  └ devname:rootdir
             │     └ readonly
             └ tape<device_emu_unit>                              controller ┘
```

**3. The two SCSI IDs are hardcoded in the AMIX installer** and cannot be moved:
**ID 4 = installation tape**, **ID 6 = target disk**. Hence `scsi4` / `scsi6` as
the controller fields. A disk anywhere else is simply not found.

**4. Floppy swaps need a bound key, not the F12 menu.** The install asks for the
root floppy after the boot floppy. Binding the disk-swapper actions makes it
scriptable:

```
floppy_image_0 = <boot.adf>
floppy_image_1 = <root.adf>
keyboard_key_f9  = action_drive_0_insert_floppy_0
keyboard_key_f10 = action_drive_0_insert_floppy_1
```

## Install transcript (what the script asks, in order)

Keyboard `[12]` American → install (not repair) → insert tape → SCSI scan finds
the ID 6 disk → AmigaDOS megabytes `[0]` → root `[2015]` → swap `[30]` → root
filesystem type **`ufs`** (the default is `s5`; UFS is the better choice and what
the amigaunix.com wiki recommends) → package set. The set menu offers
**(1) Standard 67.4 MB / (2) Everything on the tape 296.7 MB / (3) Custom**;
we take **(2)**, which guarantees `Xcore`/`Xbasic`/`olcore` and the app set
(the cost is ~150 MB of source trees we do not need, on a 2 GB disk).

## Machine (as proven on the rig)

```
amiga_model            = A3000          # 68030 + 68882, MMU
kickstart_file         = kick37175.A3000.rom
motherboard_ram        = 16384          # 16 MB; guest reports 14.3 MB available
hard_drive_0_type      = rdb
hard_drive_0_controller= scsi6
uae_gfxcard_type       = A2410          # Lowell TIGA — driven by `X -tiga` (colour golden)
uae_gfxcard_size       = 2
```

Guest banner on boot: `UNIX(R) System V Release 4.0 AT&T Amiga (Limited)
Version 2.1 0800429`.

## How the "still open" list resolved

- **Geometry:** 640x512, the whole of the chipset X server's world. The Xvfb root
  is sized to it and `stretch = 1` removes FS-UAE's own in-window letterbox.
- **Savestates:** not used. Reset is a cold boot (~2 min) of a fresh work disk —
  `amigaos35`'s `relaunch` shape.
- **Pointer:** the guess was right. Mousehack is an AmigaOS trap, AMIX drives the
  mouse hardware, and motion arrives relative and accelerated. This is the
  station's one genuinely open item; see the guest doc.
- **The 2.1p2a patch disk** is still not applied — this install is stock 2.1
  (`0800430`).
