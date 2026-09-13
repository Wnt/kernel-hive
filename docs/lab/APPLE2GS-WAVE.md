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

## Proven on the framebuffer

All frames on labhost, all at the published 1024x768:

| Proof | Frame | Measured |
|---|---|---|
| build boot gate (no media) | `/data/vms/sandbox/apple2gs/build/work/gate/fb.shm` | 786432 lit pixels — the GS's power-on raster fills the WHOLE surface, so the copied `native_gate_nonblack` floor of 1000 is meaningless here; the floor that means something is "the full raster", and the scene proof is the rig capture below, not this gate |
| GS/OS 6.0.1 boots | `/data/vms/sandbox/apple2gs/rig1/frame.png` | "Welcome to the IIGs / System 6.0.1" splash at 30 emulated s |
| **Finder desktop, cold boot** | `/data/vms/sandbox/apple2gs/rig3/finder.png` | HARDDISK volume + Trash + the full Finder menu bar, settled **33.8 s** after power-on (throttled, real time) |
| **golden restore** | `/data/vms/sandbox/apple2gs/rig3/restored.png` | `SAVEST golden` = 474700 B in **152 ms**; relaunch with `-state golden` gives a framebuffer **byte-identical** to `finder.png` (`ImageChops.difference` bbox `None`) — `apple2gs`'s `MACHINE_SUPPORTS_SAVE` is real |
| keymap | `streamhost/stations/apple2gs/apple2gs.keymap` | 96 keys dumped from the running machine's own `KEYDUMP` over `:macadb:` (125 fields seen). NOT apple2e's — the scaffold's copy was the //e's `:X0..` matrix |

The hero `spa/public/posters/apple2gs/desktop.webp` is the restored Finder
frame, not a placeholder.

## Walls hit

**The splash stall that did not reproduce.** The first ctlsock rig (`rig2`:
throttled, `-sound none`, ctlsock armed) stopped dead on the "Welcome to the
IIGs" splash with its progress bar half filled and did not move for 88 emulated
seconds — `fb-wait.py --tolerance 5 --settle 20` reported `last change at 0.0s`,
so this was a real freeze and not the default tolerance hiding a crawling
progress bar (checking that was worth the one command: a 400-pixel tolerance
does hide a progress-bar tick).

Four theories were raced on their own rigs (`theory.sh`, one MAME per theory,
90 emulated seconds each, all four in parallel at load 29):

| Theory | Result |
|---|---|
| `base` — a straight repeat, sound on | **Finder desktop** |
| `raw` — 2mg header stripped to a raw `.hdv` (`dd bs=64 skip=1`) | **Finder desktop** — so MAME's `cffa2` parses the `.2mg` header itself; the strip is unnecessary |
| `ram8` — `-ramsize 8M` (default is 2M) | **Finder desktop** — RAM was not it |
| `sl2` — CFFA 2.0 in slot 2 instead of 7 | **"Check startup device!"** — the GS boots slot 7; keep `-sl7 cffa2` |
| `ctrlnosnd` — control: `-sound none`, the one flag `rig2` had | **Finder desktop** — so `-sound none` was not it either |

So the stall is **NOT reproduced in five subsequent boots**, including one with
the exact flag suspected. The shipping configuration (throttled, sound on,
ctlsock armed — `rig3`) reached the Finder in 33.8 s on the first try and its
golden restores byte-identically. Recorded as an unexplained one-off rather
than a fix, because nothing was fixed: if a station ever hangs on that splash,
the first thing to know is that it is intermittent and a relaunch clears it.

**`-hard1` must come AFTER the slot option.** `apple2gs -hard1 x -sl7 cffa2`
dies with `Error: unknown option: -hard1` — MAME only learns the option once
the slot device is on the command line. Cost one whole 4-way race round.

**`stage-romset.py` hashes LOOSE FILES.** A romset staged as a `.zip` stages
ZERO members and the boot gate then dies `Required files are missing`. Unzip
`-j` into the staging dir. (Relayed to the `macsys1` lead mid-wave.)

## Open items

- **`ctlsock: setup btns=1 axes=1`** on every launch, with all three
  `:macadb:MOUSE0/1/2` tags bound. Whether `axes=1` is a count of axis PAIRS or
  a sign that only one axis bound is not established — it was not chased,
  because the pointer is open anyway. Read it before the first MOVEA
  measurement.
- **Pointer**: gains unmeasured. The fixture ships the neutral 1.0/1.0, NOT
  apple2e's 1.547/1.674 — a copied gain is a guess, and this is a different
  ADB path with a different `PORT_SENSITIVITY`. `stream.pointer.transport`
  stays `none` until a two-target readback on the Finder desktop proves it.
- **Retronet**: OPEN (above).
