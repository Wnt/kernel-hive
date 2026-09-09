# Amiga 3000 integration wave — 2026-09-09

Operator ask (2026-09-09): "Add the two Amigas" from the home-computer study
(`docs/lab/research/home-computer-candidates.md` §4.4). The study named the
A4000 second, but `amigaos35` already IS an A4000/040; the A3000 with
Workbench 2.04 is the exhibit the lineup lacks (Workbench 1.3 on `amiga`,
3.5 on `amigaos35`, AMIX on the same A3000 hardware in `amix`). This brief is
the Amiga 3000's; `A1000-WAVE.md` is its sibling wave, run in the same
session. Rule 13: host-native on the FS-UAE path from day one — `amigaos35` is
the shape sibling; its x11-runtime launcher, Xvfb capture, XTEST input and
host-composed FFS hardfile recipe are copied, its retronet cage is not (a 1991
guest has no web plane).

## Ledger (allocated by `wave.sh alloc a3000`, session `a3000`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet |
|---|---|---|---|---|
| a3000 | a3000 | 189 / 54189 / 189 | — (FS-UAE mousehack + XTEST abs, as amigaos35) | — (pre-web guest) |

| Fact | Value | Measured by |
|---|---|---|
| Xvfb display | `:89` (kh-claim `display/89`, session a3000) | spine |
| Scene tuple | `paramTower,crtC,keyboardA,paramMouseA` (scaffold refused the sibling's) | spine |
| Emulator | FS-UAE 3.2.35, pinned source build with the lab mousehack patch (`build-fsuae-native.sh`, `FSUAE_STATION=a3000` → `assets/a3000/fsuae-native/`, the station's OWN copy) | spine; smoke used amigaos35's binary |
| Model | `--amiga_model=A3000 --chip_memory=2048 --fast_memory=8192` (68030 + 68882, ECS, 32-bit addressing; FS-UAE defaults the A3000 to Kickstart 3.1 — we pass the 2.04 A3000 ROM explicitly) | spine from src/fs-uae/config-model.c |
| Kickstart | 2.04 r37.175 (A3000), 524 288 B — the same dump `amix` stages at `assets/amix/kick37175.A3000.rom`; this station keeps its own copy | spine |
| Window / X screen | 720x568 (`xwininfo`, same as amigaos35; PAL 640x256 desktop inside) | spine, measured on the smoke rig |
| Device set (target) | `hard_drive_0` = FFS hardfile composed host-side from the four 2.04 ADFs (as `tiles/amigaos35.sh` does for 3.1, amitools xdftool), no floppies, no statefile, no network | spine; the `build` stream composes it |
| Smoke boot | Workbench 2.04 floppy in DF0 boots to the disk's first-run "KeyMap Selection" script within 60 s (frame `smoke/now2.png`, 2026-09-09) — proves ROM + model + window; the HDF golden must not carry that script | spine |
| Media | `/data/vms/sandbox/a3000/media/` (MANIFEST.sha256; archive.org items `commodore-amiga-firmware` and `commodore-amiga-operating-systems-workbench`, TOSEC zips unpacked) — table below | spine |

| File | Bytes | sha256 |
|---|---|---|
| `Kickstart v2.04 r37.175 (1991-05)(Commodore)(A3000).rom` | 524288 | `563f948af19c09daed1f06b8760221ff4b2789c1690cdcfbce2c941157af23d1` |
| `Workbench v2.04 rev 37.67 (1991)(Commodore)(Disk 1 of 4)(Workbench).adf` | 901120 | `ac6b2529b2896474401ff51c4fcf79464a5f53331b6ad872f0bb721a0a63b8ab` |
| `Workbench v2.04 rev 37.67 (1991)(Commodore)(Disk 2 of 4)(Extras).adf` | 901120 | `3da86648e602f4e0916663d2b4893011423837b2f2b6885e421310338412c02a` |
| `Workbench v2.04 rev 37.67 (1991)(Commodore)(Disk 3 of 4)(Fonts).adf` | 901120 | `c04f0ed8016ff2aa458c977722ede02f5e607cdb206a384ae61b081fd694702e` |
| `Workbench v2.04 rev 37.67 (1991)(Commodore)(Disk 4 of 4)(Install).adf` | 901120 | `c98c97be15f52e25610ee2d4a1fe99807ba9fe11aa81fa0c81fd37cab725bcdd` |

## Proven in the spine (coordinator, alone)

- Stack, allocation, media, display and `/os/a3000` from the smoke rig within
  the first 15 minutes (`smoke-rig.sh` with a placeholder QMP socket and a
  hand-patched `stream.env`: display `:89`, `x11test` input).
- The A3000 model with the 2.04 A3000 ROM boots the Workbench 2.04 floppy to
  its first-run keymap prompt; the desktop itself is one `0` + Return away and
  is what the HDF golden ships.

## Streams

| Stream | Branch | Owns | Model |
|---|---|---|---|
| build | `a3000-build` | `scripts/build-guests/tiles/a3000.sh`: media gate, compose `a3000-system.hdf` host-side with xdftool from the four ADFs (Workbench root + Extras + Fonts:, a startup-sequence that boots straight to the desktop — no keymap prompt), stage ROM + HDF into `assets/a3000/` and the station `disk/`; `FSUAE_STATION=a3000 build-fsuae-native.sh` run; `check-assets.sh`, `ASSETS-MANIFEST.md`, `os-media-catalog.md` rows | sonnet |
| golden | `a3000-golden` (after build reports the HDF) | cold-boot proof with the station launcher on a sandbox clone, XTEST pointer + keyboard proof on the framebuffer, measured boot time, registry `reset` truth, staged station dir under `/data/vms/streamhost/stations/a3000/` | sonnet |
| spa | `a3000-spa` | `registry/posters/a3000.md`, hero + frames, `museum`/`spa`/`demoProgram`, `keyboardProfiles.ts`, `machineIdentity.ts` tints — the only stream that edits visitor-facing prose | opus |
| docs (after golden) | `a3000-docs` | `docs/guests/a3000.md` incl. §Checkpoint, `GUEST-TIERS.md`, release notes, `docs/README.md` | sonnet-low |

One owner per file; facts flow one way (the stream that measures corrects this ledger).

## Walls hit

None in the spine. Known trap for the build stream, inherited from amigaos35:
an FFS volume written by xdftool boots fine, but a golden captured from a
RUNNING session has a dirty root `bm_flag` (set only on flush/unmount) — compose
the golden host-side and never boot the golden file itself.

## Tooling debt found by this wave

See `A1000-WAVE.md` (same session): the scaffold's QEMU-sibling assumption
(fixed), `smoke-rig.sh`'s QMP requirement, root-umask rig files, and the
root-owned `/data/assets-staging` inside CT950.

## Timeline

Measured after landing with `scripts/dev/session-timeline.py`; filled in by the retro.
