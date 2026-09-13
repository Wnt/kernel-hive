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

## Pointer — OPEN
`stream.pointer.transport` stays `"none"`. The GS's input is the `macadb` HLE
device: `:macadb:MOUSE0` (buttons — the GS mouse reports **two** buttons,
unlike the //e card's one), `:macadb:MOUSE1` (X) and `:macadb:MOUSE2` (Y),
both 8-bit analog ioports (`mask="255"`, `PORT_SENSITIVITY(100)`), so
**`MAME_CTL_PTR_MOD=256`** follows the same way it does on `apple2e`. Unlike
`apple2e`, gains are **not measured** — the fixture ships the neutral
`1.0`/`1.0`, not a copied number, because this is a different ADB path with a
different sensitivity setting and a copied gain would be a guess.
`ctlsock: setup btns=1 axes=1` is seen on every launch with all three
`:macadb:` tags bound, but whether `axes=1` counts axis pairs or signals only
one axis bound was not chased — read it before the first `MOVEA` measurement.

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
