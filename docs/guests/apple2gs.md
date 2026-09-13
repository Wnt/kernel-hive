# Apple IIGS (ROM 3, 1986) — GS/OS 6.0.1 Finder station (:54204)

**Guest:** a **host-native** MAME 0.289 station — the daemon runs the emulator
directly on the host (drawshm frames, ctlsock keys, FIFO audio), no bridge VM,
no guest OS process, no QMP. MAME's **`apple2gs`** driver
(`src/mame/apple/apple2gs.cpp`, `SUBTARGET=apple2gs`) emulates an **Apple
IIGS, ROM 3 (1986)**. Scaffolded `--like apple2e` — same `apple/` driver
family, same host-native `stations/mame-native/x11-runtime.sh` launcher, same
CFFA 2.0-in-slot-7 ProDOS hard-disk approach — but the GS is a different
machine with a different input path; see below.

**The Machine and the OS:** the Apple IIGS is the 16-bit Apple II, a 65C816
machine with a GUI-capable "GS" toolbox on top of the 8-bit Apple II's bus and
software lineage. This station boots **GS/OS System 6.0.1** (1992), the final
mature System-6-line release, into the **Finder** — the GS's icon-driven
desktop, not the //e's text-mode ProDOS menu the sibling `apple2e` station
shows.

## License / provenance
- **MAME `apple2gs`** — emulation driver in `src/mame/apple/apple2gs.cpp`,
  GPLv2 licensed.
- **ROM set `apple2gs` (ROM 3)** — four files, read off stock MAME 0.276 on
  labhost (`-listxml apple2gs`) and confirmed against the pinned 0.289 tree:
  `341-0728` (128 KiB, sha1 `c0f4704233ead14cb8e1e8a68fbd7063c56afd27`,
  `maincpu`), `341-0748` (128 KiB, sha1
  `c70576869deec92ca82c78438b1d5c686eac7480`, `maincpu`), `341s0632-2.bin`
  (4 KiB, `adbmicro` — the M50741 ADB controller's own firmware), and
  `megaii.chr` (16 KiB, `gfx1`, flagged `baddump` upstream but still the set
  MAME expects).

## Device set
- **Slot 7:** CFFA 2.0 (`-sl7 cffa2`) — a 32 MB pre-installed ProDOS `.2mg`
  hard-disk volume (`-hard1 <hive.hdv>`) boots GS/OS from here, the same
  CFFA-in-7 approach as `apple2e`; `-listslots apple2gs` lists `cffa2` under
  every slot `sl1`..`sl7`, so the //e's trick carries over unchanged.
- **No `-sl4 mouse` and no `-sl6 diskiing`.** Those are Apple II *cards* the
  //e needs because its keyboard and mouse are add-in peripherals. The GS
  needs neither: its ADB keyboard and ADB mouse are handled by the **`macadb`
  HLE device on the motherboard** (the same ADB controller family the
  Macintosh line uses), and its 3.5"/5.25" drives are on the **built-in IWM**
  — not a slot card. The GS is a different hardware generation from the //e
  even though both run under the `apple/` MAME driver family.

## Checkpoint
`apple2gs` carries `MACHINE_SUPPORTS_SAVE`, so the golden is a plain MAME save
state and the shared host-native launcher's checkpoint restore applies with no
per-station patch. Measured: `SAVEST golden` wrote **474700 bytes in 152 ms**;
a relaunch with `-state golden` produced a framebuffer **byte-identical** to
the cold-boot Finder desktop frame (33.8 s settle, throttled, real time) —
`ImageChops.difference` bbox `None`.

## Keyboard
ADB via a **96-key keymap dumped from the machine's own `KEYDUMP`** over the
`:macadb:KEY0..KEY7` ioports (125 fields seen) — not `apple2e`'s matrix; the
scaffold's initial copy of the //e's `:X0..` keymap was wrong for this driver
and was replaced. Pacing is the fleet floor, **`SH_KEY_MIN_HOLD_MS=40`**,
**`SH_KEY_MIN_GAP_MS=40`**, same as `apple2e`.

## Pointer — 1:1 absolute (closed loop on the guest's cursor words)
`stream.pointer.transport` is `"abs"`, method `mame-guestram-readloop`, since
2026-09-13. The GS's input is the `macadb` HLE device: `:macadb:MOUSE0`
(buttons — the GS mouse reports **two**, unlike the //e card's one),
`:macadb:MOUSE1` (X) and `:macadb:MOUSE2` (Y), both 8-bit analog ioports
(`mask="255"`), so **`MAME_CTL_PTR_MOD=256`**. `ctlsock: setup btns=1 axes=1`
is not a count — both fields are C++ bools, and that line means "button 0
bound AND both axes bound".

**The wire is 7-bit signed.** `macadb_device::adb_talk()` packs the
accumulated delta as `(button << 7) | (mouse & 0x7f)`, so any per-poll delta
outside `-64..+63` reaches the guest sign-flipped: a 100-count step lands as
−28 and the arrow walks the wrong way. `MAME_CTL_MOVE_STEP=48` is mandatory;
the module's inherited default of 120 is always wrong here.

**The cursor position is in guest RAM — and it is an output.** `$E1/00E9` (X)
and `$E1/00EB` (Y) are 16-bit little-endian **guest** pixels that track the
arrow exactly. Poking them sticks but never redraws, and the next ADB poll
republishes them from an accumulator that is in neither banks
`$00/$01/$E0/$E1` nor the ADB micro's 256 bytes — so the `macsys1`
absolute-**write** route (`MAME_CTL_ABS_RAM`) does not work on this machine.
The **read** loop does.

**How the module addresses it.** `mame-ctlsock-ram-cursor.patch` (last in this
station's chain) lets a `MAME_CTL_CURSOR_ITEMS` entry be
`suffix@offset[:width]` — a little-endian integer *inside* a byte-sized save
item. `m_megaii_ram` is `size=1 count=131072` over banks `$E0/$E1`, so
`$E1/00E9` is byte `0x100E9`. `MAME_CTL_CAL_SX`/`CAL_SY` (new, beside
`CAL_X`/`CAL_Y`) turn the guest-pixel reading into a published one:
`published = CAL + guest * CAL_S`, here `47 + gx*1.4531` and `53 + gy*3.325`.

**The raster is letterboxed.** The 640x200 SHR raster occupies published
`x 47..976`, `y 53..717`; everything outside is SHR border the guest cursor
can never enter, so the fleet's usual corner targets `(20,20)`/`(1000,740)`
are not satisfiable on this station and the proven set is the reachable one.

**Proof** (rig restored from the golden, five targets x two laps, arrow tip
located on the framebuffer as the median of 9 frames — the GS cursor is XORed
in per VBL, so no single frame is evidence):

| target | landed | err |
|---|---|---|
| (50,56) | (51,57) | +1,+1 |
| (973,56) | (972,57) | −1,+1 |
| (50,714) | (51,715) | +1,+1 |
| (973,714) | (972,715) | −1,+1 |
| (512,384) | (513,386) | +1,+2 |

Lap 2 was byte-identical to lap 1. **Resolution bound:** one ADB count is
exactly one guest pixel, so the loop can only land on guest-pixel centres —
±0.73 px on X and ±1.66 px on Y in published pixels. The 2 px on Y *is* that
bound, not drift. A click reacts: `MOVEA 105 60` + `DOWN1` drops the Finder's
File menu (41769 changed pixels), `UP1` closes it.

**Binary, golden and fixture move together** (AGENTS.md rule 6): the golden
was recaptured on the ram-cursor binary. Rolling the pointer back means
putting all three back.

## Retronet — OPEN, deliberately
No in-guest TCP/IP stack, browser and IM client for GS/OS 6.0.1 was judged
worth an install-floppy hour in this wave (Marinetti plus a GS-side IM client
is its own wave). No `rn-tapnet.sh` is committed for this station.

## Reset / checkpoint
`SH_RESET_MODE=relaunch`, restoring the MAME savestate captured at the Finder
desktop. See §Checkpoint above for the measured restore numbers.

## Build status (2026-09-13)
- Golden: cold boot reaches the Finder desktop (HARDDISK volume, Trash, full
  Finder menu bar) in 33.8 s (throttled, real time); the golden save-state
  restore is byte-identical to that frame.
- Keyboard: the 96-key ADB keymap is dumped and live; pacing is the fleet
  floor 40/40 ms (not independently re-measured on this station beyond the
  keymap dump — treat as inherited from the shared launcher's contract until
  a dedicated keyboard proof runs).
- Pointer: OPEN, ships keyboard-only, `stream.pointer.transport: "none"` —
  gains unmeasured.
- Retronet: OPEN (see above).
