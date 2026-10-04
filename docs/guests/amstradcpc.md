# Amstrad CPC 6128 + Locomotive BASIC — gallery station notes (:8119)

Status: **LIVE production streamhost station, HOST-NATIVE since 2026-10-04.**
MAME 0.289's `cpc6128` driver runs on labhost itself and boots **Locomotive
BASIC 1.1** to the yellow-on-blue `Ready` prompt. There is no QEMU, no guest
Linux and no X: frames come from MAME's drawshm surface, keys go into the CPC's
own keyboard matrix through the ctlsock module, and the AY-3-8912 plays through
a FIFO the daemon clocks. Until that date the station was a Caprice32 kiosk
inside a Debian guest; [Why the kiosk was retired](#why-the-kiosk-was-retired)
says what went wrong and what the conversion measured.

## Identity and source

| | |
|---|---|
| Public ID / station directory | `amstradcpc` |
| Slot / UDP | 119 / 54119 |
| Emulator | MAME **0.289** (tag `mame0289`, `f34f0250`), driver `cpc6128`, subtarget `cpc6128` |
| Builder | `scripts/build-guests/emulators/build-mame-native.sh amstradcpc` + stanza `native.d/amstradcpc.sh` |
| Binary | `/data/vms/streamhost/assets/amstradcpc/mame-native/cpc6128` (patches: ctlsock, drawshm, kiosk-no-ui) |
| Launcher | the shared `streamhost/stations/mame-native/x11-runtime.sh` (despite the name, no X) |
| Station env | `streamhost/stations/amstradcpc/station.env.fixture` |
| Keymap | `streamhost/stations/amstradcpc/amstradcpc.keymap` (generated, see [Keyboard](#keyboard)) |
| Archetype | `beige-tower-crt` (ideal: a bespoke CPC 6128 + CTM640 monitor) |
| Credentials | none: the machine has no login |

## ROMs

The romset is two files, the Amstrad ROMs that Caprice32 bundles: `cpc6128.rom`
(32 KB, the OS and Locomotive BASIC 1.1) and `amsdos.rom` (16 KB, AMSDOS, which
MAME calls `cpcados.rom`). They are fetched by a pinned commit of
`github.com/ColinPitrat/caprice32` (`66a4a7af`, `rom/`) and staged on labhost at
`/data/assets-staging/amstradcpc/` with a `MANIFEST.sha256`. The stanza checks
the manifest and `stage-romset.py` matches both files by SHA-1 against the
shipped binary's own `-listxml cpc6128`, so the file names do not matter and a
MAME upgrade that re-hashes a ROM fails the build. Hashes and provenance are in
[`docs/lab/ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md).

The Amstrad ROMs are **redistributable by Amstrad's permission** (Cliff Lawson,
on behalf of Amstrad): emulator writers may include them as long as the
copyright messages are not altered and nobody charges for them. The exhibit's
idle screen is the unaltered copyright banner. The bits are still never
committed; the repo records the URL and the hashes only.

## Curated metadata (for the UI placard)

- **Year:** CPC 6128 = **1985**.
- **Lineage:** Amstrad's British all-in-one home micro (Zilog **Z80A** at
  4 MHz, **128 KB** RAM, built-in 3-inch disk drive, its own colour or green
  monitor). Boots to **Locomotive BASIC 1.1**, the yellow-on-blue `Ready`.
- **Iconic era software:** Locomotive BASIC, AMSDOS / CP/M Plus, Protext, The
  Advanced OCP Art Studio.

## The scene and reset

A cold boot reaches `Ready` in about 1.1 emulated seconds: the
"Amstrad 128K Microcomputer (v3)" banner, the 1985 copyright lines, `BASIC 1.1`,
`Ready` and the block cursor. MAME is deterministic, so every boot draws the
same frame pixel for pixel. Reset is a relaunch, and the station has **no
savestate** (`MAME_NATIVE_CHECKPOINT=0`):

- The driver does not declare `MACHINE_SUPPORTS_SAVE`, and in 0.289 neither
  `amstrad.cpp` nor `amstrad_m.cpp` registers any state of its own. The gate
  array's pens and mode and the ROM and RAM paging live in `amstrad_state`
  with no `save_item`, so a savestate carries the Z80, the CRTC, the PPI, the
  AY and the RAM, but not them.
- A savestate taken at `Ready` on a rig did restore to `Ready`, and a program
  that changed MODE, INK and BORDER and drew a line ran correctly after it. That
  works only because, at `Ready`, the unsaved members happen to equal their
  reset values: luck, not a contract.
- The cold boot costs about a second, so a checkpoint would buy nothing, and
  without one there is no `golden.sta` that has to stay in step with the binary
  (rule 6). bbcmicro and zxspectrum run the same way for the same reason.

The launcher freezes MAME 8 s after start (standby, ~0 CPU), and the daemon
resumes it when a visitor connects.

## Keyboard

The CPC is a keyboard exhibit: there is no pointer (`stream.pointer` none). The
firmware scans a ten-row key matrix (`:kbrow.0` to `:kbrow.9` in MAME) once per
50 Hz frame, 20 ms, and reads Shift and Control from row 2 of the same matrix.

**The keymap is generated, then pinned by an override.** `mame-keymap.py`
dumps the running binary's keyboard with `KEYDUMP` and binds each PC scancode
to the field whose MAME default assignment is that PC key, so the CPC's keys sit
where MAME puts them on a PC keyboard. Regenerate it with

    scripts/dev/mame-keymap.py <rig>/ctl.sock --tags :kbrow \
      --override scripts/build-guests/emulators/native.d/amstradcpc.keymap-override \
      --out streamhost/stations/amstradcpc/amstradcpc.keymap

- `--tags :kbrow` matters. The driver also has a Cheetah 125 joystick port whose
  fields share `LCONTROL`, `LALT`, `SPACE` and the arrows with real keys; an
  unfiltered dump bound Space, Left Ctrl, Left Alt and the arrows to the
  joystick.
- **Shift and Control are mapped**: Left and Right Shift to `Shift`, Left and
  Right Ctrl to `Control` (`:kbrow.2`). Checked in the generated file, unlike
  apple2e's first keymap, which had no Shift.
- The override changes only what should mean something else here: Backspace is
  the CPC's DEL (delete left) and PC Delete is CLR; the backtick key is the CPC's
  `\` key (MAME puts `\` on Right Ctrl and Esc on the backtick key as well as
  Esc); Right Ctrl is Control; keypad Enter is the small ENTER; F10 is f0. F1-F9
  reach f1-f9 by name and the keypad reaches f0-f9 by position, which is where
  they are on a 6128.
- The generator had never matched a keypad key by token: its table spelled them
  `KEYCODE_7_PAD`, MAME's macro names, while `KEYDUMP` prints `KEYCODE_7PAD`.
  Fixed on 2026-10-04 for every station's next regeneration.

**A visitor's physical keys follow the CPC's own layout.** On a CPC, Shift+2 is
`"`, `:` and `;` are unshifted keys with `*` and `+` above them, `@` and `[` are
unshifted, and `=` is Shift+`-`. A US-layout visitor pressing Shift+' gets `+`,
as they would on the real machine. The type-in editor, the demo typist and
`labctl type` translate instead: registry `keyboard.charMap` sends each of 20
characters through the key that makes it on the CPC (`"` through Shift+2, `(`
through Shift+8, `*` through Shift+`;`, `\` through the backtick key), and
`SH_KEY_MAP` in the fixture is the same map for labctl. `~` has no key on the
CPC and is `typeIn.unreachable`.

### Pacing, measured

The ctlsock module paces each key in **emulated** time: a key stays down
`SH_KEY_MIN_HOLD_MS`, a re-press of the same key waits `SH_KEY_MIN_GAP_MS`
after its release, exclusive-scan (`MAME_CTL_KEY_EXCL=:kbrow.`) lets only one
non-modifier key be down at a time, and a key press waits `SH_KEY_MOD_LEAD_MS`
after the last Shift or Control edge. Host load can delay the emulator, but it
cannot compress these dwells, which is the whole difference from the kiosk.

Measured 2026-10-04 on a rig of this binary through a sandbox daemon of the
fleet's daemon (`streamhost-98f78ebf`): the type-in editor's own key edges,
recorded from the SPA's `typeListing()` and played with
`scripts/e2e/key-burst-proof.mjs --edges` over WebTransport, at `perCharMs`
120 with `NEW` first, exactly as the editor sends them. The listing was 15
lines with 251 shifted symbols (`" ( ) * $ + & ! < > ' = _ | { } # % ?`), 110
capitals (Shift+letter, as typed) and `@ [ ] ^ \ ;`. Each run booted a fresh
rig, typed with the rig at nice 0, then typed `CLS:LIST` and read the frame back
cell by cell against the 6128 ROM's own font, which turns the LIST into text
exactly. Emulated/wall speed was 0.98-1.0 in every run counted (below 0.95
would have been invalid).

| Hold/gap | Lead | Result |
|---|---|---|
| 10/10 | 20 | nearly every key lost, Enters included: one garbage line and `Syntax error` |
| 20/20 | 20 | exact |
| 30/30 | 20 | exact, at a 1-minute load of 63 to 86 |
| 40/40 | 0, 1, 2, 5, 10 | exact, one run each |
| **40/40** | **20** | **exact, see the proof below** |

- **Hold and gap 40/40**: a key shorter than one 20 ms scan can fall between
  two scans, which is exactly what 10/10 shows, and 20/20 is the measured
  floor. 40/40 is two scan periods, twice the floor, as on sinclairql.
- **Lead 20 ms**: this binary showed no Shift tear at all, at lead 0 included,
  so there is no threshold to multiply. 20 ms is one full scan by
  construction: Shift has been seen by a complete scan before its key can be,
  whatever phase the module's drain has against the firmware's scan. It costs a
  shifted character at most 40 ms.
- **`perCharMs` 120** (typeIn and demo): the validator's worst case is
  HOLD + max(GAP, LEAD) + LEAD = 100 ms per character. 120 types a listing
  half again as fast as the kiosk's 180, and in emulated time nothing is lost
  if the host is slow, the queue just drains later.

The proof at the shipped values is in
`/data/vms/streamhost/stations/amstradcpc/evidence/cpc-native-2026-10-04/`
(`INDEX.txt`).

## Ports

- streamhost UDP (WebTransport): **54119** (slot 119). UI web port 8119.
- No ssh, no QMP, no `labctl exec`: there is no guest OS. `labctl type`
  writes through the ctlsock socket.

## Why the kiosk was retired

From 2026-07-27 to 2026-10-04 the station was a Debian 12 kiosk overlay on the
bookworm bridge seed, running Caprice32 (`cap32`) in a scale-3 SDL/X11 window,
captured like any QEMU guest. Keys travelled QMP -> the guest kernel's PS/2
driver -> X -> SDL -> Caprice32, and Caprice32 sampled them once per emulated
frame. Whenever labhost descheduled the kiosk's vCPU, a key's press and release
(or a repeated key's release and re-press) reached Caprice32 in the same frame
and the CPC never saw the key.

- The daemon's pacing could only widen the gaps in wall time. At 40/40 every
  stress pass lost 1 to 11 keys at a 1-minute load of 25 to 60 (`$$` as `$`,
  `110` as `10`). 80/80 with a 20 ms lead was exact in 5 of 6 passes at load 35
  to 54 on a clone, and nothing held at load 70 and above.
- Through the real editor on the live station, `draw.bas` lost 6, 9 and 4 keys
  in three runs at load 31 to 80 (`X,400` as `X,40`, `FOR I=0` as `FOR 10`),
  and 2, 0 and 2-3 keys even at low load.
- A shifted key also tore once in about 4,500 (`"` as `2`), because Caprice32
  set Shift and the key in one matrix update.

The evidence is in `evidence/daemon-mod-lead-2026-10-04/` and
`evidence/lowload-retest-2026-10-04-*/` in the station directory, and the
measurements in [`../TYPE-IN-EDITOR.md`](../TYPE-IN-EDITOR.md#shifted-characters-the-modifier-lead).
Host-native MAME removes the guest, and its key module paces in emulated time.

**Rollback.** The kiosk's overlay (`overlay.qcow2.debridged-bak`, which holds
its internal `golden`) and launcher (`qemu-streamhost.sh.debridged-bak`) stay
in the station directory, and the bridge builder `tiles/amstradcpc.sh` is
unchanged. To roll back: stop the unit, rename both back, restore the previous
`station.env` (`station.env.pre-native-20261004`), start the unit. Launcher and
disk go back together or not at all.
