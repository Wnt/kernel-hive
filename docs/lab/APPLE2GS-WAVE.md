# Apple IIGS integration wave — 2026-09-13

GS/OS **System 6.0.1** (1992) with the Finder, on the **Apple IIGS** (ROM 3,
1986), Tier 1, host-native under the fleet MAME 0.289 (`SUBTARGET=apple2gs`,
driver `apple2gs`, `src/mame/apple/apple2gs.cpp`). Scaffolded
`--like apple2e` — the same `apple/` family, the same host-native
`stations/mame-native/x11-runtime.sh` launcher, the same CFFA 2.0-in-slot-7
ProDOS hard disk. Runs beside four other stations tonight
(`macsys1`, `minix2`, `xenix`, `os213`); coordination contract in
`WAVE-COORDINATION.md`, landing through `scripts/dev/station-land.sh` which
takes the landing lock.

## Ledger — from `scripts/dev/wave.sh alloc apple2gs`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 204 / 54204 / 204 |
| x11warp display | — (not allocated: host-native MAME, no in-guest X) |
| retronet address / MAC / tap / chain / UIN | — (none this wave, see below) |
| sibling (`--like`) | `apple2e` |
| hardware tuple | `pizzaBoxB\|homeCrtD\|none\|paramMouseD` (the //e's `eightBitWedgeA` body is the wedge case; the IIGS is a pizza box) |
| render orders | as scaffolded by `stations-registry.py new --like` — never hand-edited |
| device set | `-sl7 cffa2 -hard1 <hive.hdv>`; ADB keyboard + ADB mouse are on the motherboard (`macadb` HLE), 3.5"/5.25" drives on the built-in IWM. NO `-sl4 mouse`, NO `-sl6 diskiing` (those are //e cards the GS does not need) |
| media | staged by `apple2gs-media` under labhost `/data/assets-staging/apple2gs/`; URL + sha256 + byte size in that dir's `SOURCES.md` and in `scripts/build-guests/tiles/apple2gs.sh` |

**Retronet: OPEN, deliberately.** No in-guest TCP/IP + browser + IM client on
GS/OS 6.0.1 is worth an install-floppy hour tonight (Marinetti + a GS IM client
is a wave of its own). No `rn-tapnet.sh` is committed for this station — rule 15.

## Sandbox verdict

**No container.** `apple2gs` is an EMULATED MACHINE under the fleet MAME
binary; the visitor's reach ends at the emulated Apple IIGS. The launcher line
is the shared host-native one:

```
streamhost/stations/mame-native/x11-runtime.sh
  MAME_NATIVE_BIN=/data/vms/streamhost/assets/apple2gs/mame-native/apple2gs
  MAME_NATIVE_DRIVER=apple2gs
  MAME_NATIVE_ARGS=-sl7 cffa2 -hard1 /data/vms/streamhost/assets/apple2gs/media/hive.hdv
```

No 9p/virtfs/smb/`fat:` host drive, no `-netdev user` hostfwd, no
guest-reachable QMP/monitor, no virtio-serial host channel. Same verdict and
same reasoning as `apple2e`, which needs no nspawn either.

## Facts measured in the spine (coordinator, alone)

Read off **stock MAME 0.276 on labhost** (`/usr/games/mame -listxml apple2gs`)
and confirmed against the pinned 0.289 tree at
`/data/vms/sandbox/apple2gs/build/work/mame`:

- **ROM set `apple2gs` (ROM 3)** is four files:
  `341-0728` (128 KiB, sha1 `c0f4704233ead14cb8e1e8a68fbd7063c56afd27`),
  `341-0748` (128 KiB, sha1 `c70576869deec92ca82c78438b1d5c686eac7480`) — both
  `maincpu`; `341s0632-2.bin` (4 KiB, `adbmicro`, the M50741 ADB controller);
  `megaii.chr` (16 KiB, `gfx1`, flagged `baddump` upstream — it is still the
  set MAME expects).
- **The GS's input is the `macadb` HLE device, not the //e's cards.** Ports:
  `:macadb:MOUSE0` (buttons, `PORT_NAME("Mouse Button 0")` / `("Mouse Button 1")`
  — the GS mouse reports TWO buttons, unlike the //e card's one),
  `:macadb:MOUSE1` = X, `:macadb:MOUSE2` = Y, both 8-bit analog (`mask="255"`,
  `PORT_SENSITIVITY(100)`), and `:macadb:KEY0..KEY7` for the Apple Extended
  ADB keyboard. **`MAME_CTL_PTR_MOD=256`** follows from the 8-bit axes, exactly
  as on `apple2e`.
- `apple2gs` carries `MACHINE_SUPPORTS_SAVE`, so no skip-warnings patch and the
  shared launcher's checkpoint restore applies unmodified (to be confirmed by
  the restore proof).
- CFFA 2.0 is available in every GS slot (`-listslots apple2gs` lists `cffa2`
  under `sl1`..`sl7`), so the //e's `-sl7 cffa2 -hard1 <image>` trick carries
  over unchanged.

## Two `stations-registry.py new --like` bugs fixed in this wave

Both cost the scaffold a failed run, both are in
`scripts/stations_registry/scaffold_like.py`, and both bite ANY host-native
sibling — this is the second wave in two days to hit this class
(`win98se --like magiccap`, 2026-09-13):

1. **Only `runtime.qemu.auxFiles` was copied.** A host-native x11-runtime
   station keeps its keymap under `runtime.x11.auxFiles`, and `validate`
   checks BOTH lists — so the scaffold wrote a row referencing a keymap it
   never copied and rolled itself back. Fixed: aux files are gathered from
   both runtime nodes.
2. **Aux files named after the sibling were not renamed**, and the fixture
   still pointed at the SIBLING's asset tree and binary. `stations/{sib}/`
   rewrote only the directory, so the row asked for
   `stations/apple2gs/apple2e.keymap`, and `MAME_NATIVE_BIN` still read
   `assets/apple2e/mame-native/apple2e` — the scaffolded station would have run
   the //e's binary, ROMs and disk image. Fixed with three new rewrite
   patterns (`{sib}.keymap|env|ini|cfg`, `assets/{sib}/`,
   `mame-native/{sib}`) and by taking destination basenames from the REWRITTEN
   row instead of the sibling's.

## Streams

| Stream | Owns | Model | Status |
|---|---|---|---|
| `apple2gs-media` | `/data/assets-staging/apple2gs/` + `SOURCES.md` + `MANIFEST.sha256` | — | running (coordinator-spawned) |
| `apple2gs-spa` | poster, hero, scene prose | — | running (coordinator-spawned) |
| `golden` (lead) | native build, smoke boot, dark launch, golden bake + framebuffer proofs | Opus | in progress |
| `docs` (after golden) | `docs/guests/apple2gs.md`, `GUEST-TIERS.md`, release-notes facts | `sonnet-low` | queued |

## Walls hit

(filled as they happen — each one: the step, what the framebuffer showed, the
theories raced on `rig-clone.sh` clones, which won, and the frame that proved it)

## Open items

- **Pointer**: gains unmeasured. The fixture ships the neutral 1.0/1.0, NOT
  apple2e's 1.547/1.674 — a copied gain is a guess, and this is a different
  ADB path with a different `PORT_SENSITIVITY`. `stream.pointer.transport`
  stays `none` until a two-target readback on the Finder desktop proves it.
- **Retronet**: OPEN (above).
