# De-bridging conversion brief — MAME bridge tiles to host-native

**The campaign this file starts.** The de-bridging spike answered its question:
running the same emulator host-native costs **69% of running it in a bridge
kiosk** (~half a core per tile, streamhost at a third of its bridged cost;
handover 2026-08-10 §3). The operator has decided to convert on that verdict —
the latency curve ([`DEBRIDGE-SPIKE-MEASUREMENT.md`](DEBRIDGE-SPIKE-MEASUREMENT.md))
remains designed and runnable if the number is ever wanted for the record, but
it is not a gate. This brief assumes [`AGENTS.md`](../../AGENTS.md) and the
spike rig docs ([`scripts/debridge-spike/README.md`](../../scripts/debridge-spike/README.md)).

**Scope: the nine MAME bridge tiles.** Non-MAME bridge tiles (VICE, SIMH,
hatari, FS-UAE, …) are out of scope until a per-emulator frame/input plane
exists for them. The live `atarist` tile stays hatari — swapping a live
exhibit's emulator is an operator decision this campaign does not make.

---

## 1. What a converted tile is

The spike's arm B shape, promoted to a production tile. No QEMU, no guest
Debian, no X server, no kiosk getty loop:

| Plane | Mechanism | Status |
|---|---|---|
| Frames | `drawshm` (`-video shm`, `MAME_SHM_PATH/SIZE`) → `SH_CAPTURE=shm` | **proven** (arm B; module gate asserts 64+w*h*4) |
| Audio | `-sound sdl -audiodriver disk` → FIFO → `SH_AUDIO_SOURCE=fifo` | **proven** (irix tile, `x11-runtime.sh` §audio) |
| Keys | ctlsock `KEY <0|1> <port> <field>` + per-tile keymap | verb **proven**; keymap plumbing is **Phase 0, the one gap** |
| Pointer | ctlsock ptr-tags/grid/quad | **not needed — all nine tiles are keyboard-only** |
| Reset/golden | ctlsock `SAVEST` + instant-restore | **proven** (irix pattern) |
| Build | host-native 0.289 subtarget, `build-mame-atarist.sh` pattern | **proven** (ccache ≈98% warm; host and chroot gcc-14 identical) |
| Launcher | tiny, no X (`SDL_VIDEODRIVER=dummy`), `armB-mame.sh` shape | **proven** |

Identity does not change: same registry id, poster, SPA scene, keyboard
profile, `/data/vms/streamhost/tiles/<tile>/` directory and cert path. Only
the runtime plane changes; `gen_tiles_json.py` already models a non-QEMU
runtime (the irix/w2kalpha `x11-runtime` rows are the precedent — this
campaign adds the no-X variant of that shape).

## 2. Phase 0 — generic keys (the enabler, before any tile)

The ctlsock module is machine-generic (`KEY` resolves port/field by name at
apply time), but streamhost's `KEY_MATRIX` (`mame_input.rs:95`) is a
compiled-in XT-scancode → IRIX-matrix table shared by both MAME sinks. Arm B's
log shows the failure every conversion would hit:
`ERR noport no port/field P1.0 | Left Win`.

- **`SH_MAMESOCK_KEYMAP=<file>`** — per-tile map, same pattern as
  `SH_MAMESOCK_PTR_GRID`: `scancode-hex<TAB>port<TAB>field` rows, loaded at
  sink construction, `KEY_MATRIX` remains the unset-default so irix is
  untouched. A scancode absent from the map is rejected, never guessed.
- **Keymap generation is mechanical, not authored.** The module's `KEYDUMP`
  verb enumerates every keyboard port/field of the running machine (it is how
  the IRIX table itself was made). One generalization: its `:kbd:` tag filter
  must become configurable (`MAME_CTL_KBD_TAGS`), since every machine names
  its keyboard ports differently.
- **`scripts/dev/mame-keymap.py`** — runs the tile's host-native binary
  headless, issues `KEYDUMP`, matches field names against the XT scancode
  name table (MAME's names are descriptive: `Q`, `Left Shift`, `Enter`), and
  emits the map plus a loud list of unmatched fields for a small per-tile
  override block. The SPA's per-machine keyboard profiles
  (`spa/src/data/keyboards.ts`) say which keys the exhibit actually needs —
  the acceptance bar is that list, not every field MAME exposes.
- Acceptance for Phase 0: the ST spike arm types into GEM through a generated
  keymap (it is keyboard-bearing and already running), and irix behavior is
  byte-identical with the env unset.

## 3. The fleet, in conversion order

Survey 2026-08-11, from the golden builders + `registry/bridge-suites.json`.
All nine: keyboard-only, audio-bearing, `-video soft` today.

| # | Tile | MAME | Driver | Base | Why this position |
|---|---|---|---|---|---|
| 1 | `dragon32` | 0.289 lab-built | `dragon32` | trixie | **The template.** Pristine upstream (no patch), simple ROM story, and `drawshm` was literally first proven on this driver. Convert end-to-end, alone, and the write-up becomes the playbook. |
| 2 | `bbcmicro` + `armeval` | 0.289 | `bbcb` (+`-tube arm`) | trixie | One binary serves both (armeval copies bbcmicro's today). skip-warnings already in the host patch stack. Their 800×600 kiosk-root speed hack dies with the kiosk — measure host-native speed before assuming `-prescale`. |
| 3 | `zx81` | 0.289 | `zx81` | trixie | Mechanical. `-bios 2nd -ramsize 1K`, romset already derived from the shipped binary's own `-listxml`. |
| 4 | `oricatmos` | 0.289 | `orica` | trixie | Mechanical. `-bios ver11` pinned; carries its own cfg/nvram dirs. |
| 5 | `mpf2` | 0.289 | `mpf2` | bookworm | **De-bridging IS the fix.** Its trixie rollback was a second-cold-boot kiosk/getty failure — host-native has no kiosk, no getty, no guest. Trixie binary already built. Skip-warnings required. |
| 6 | `kc854` | 0.289 | `kc85_4` | bookworm | Same shape and same reasoning as `mpf2`; batch them. `-bios caos42`. These two conversions retire the bookworm-chroot dependency for MAME builds. |
| 7 | `zxspectrum` | apt 0.251 → **0.289 host build** | `spectrum` | bookworm | The 0.251 guest-apt pin does not exist in trixie; host-native dissolves the pin. Romset must be re-derived from 0.289's `-listxml` (`-bios en`) — the wave-7 work, done once, against the binary that ships. |
| 8 | `sinclairql` | apt 0.251 → **0.289 host build** | `ql` | bookworm | Hardest last. Re-derive the `js` BIOS romset from 0.289; `hal16l8.ic38 NOT FOUND` must remain the only complaint; the warning panel is dismissed by a LETTER (`x`), and the golden must show zero leaked green glyphs. Audio-fragile today under dbus — the FIFO path removes that failure mode, but prove it. |

Every conversion banks ~0.5 core and removes one bridge overlay, one kiosk to
babysit, and one guest OS from the update surface.

## 4. Per-tile procedure (the template `dragon32` will refine)

1. **Clone first, never the tile.** Namespaced rig under
   `/data/vms/soltest/debridge-<tile>/`, arm-B layout. The live tile keeps
   serving until step 6.
2. Host-native build: generalize `build-mame-atarist.sh` into
   `build-mame-native.sh <tile>` (subtarget/driver/patches from a per-tile
   stanza; skip-warnings + ctlsock + drawshm; drawshm size gate at the tile's
   published geometry — mind the 800×600 tiles).
3. Keymap: `mame-keymap.py` → keymap file; prove the exhibit's demo keystrokes
   (the type-in demo from the tile's keyboard profile) land on the real
   framebuffer.
4. Audio: FIFO path, assert RMS above the silence floor during the machine's
   own boot beep/loader sound where the exhibit has one.
5. Golden: `SAVEST` at the tile's documented fixture (the same ACCEPT frame
   the migration brief's table describes), instant-restore on reset, and the
   frame — not the log — is the proof.
6. Cutover: stop the bridge tile, point the tile's directory at the new
   launcher + `stream.env`, per-tile canary streamhost binary, `labctl gen`,
   registry runtime-type update, `tile-accept.sh`-equivalent bundle, operator
   eyeball of the URL. Keep the bridge overlay as
   `overlay.qcow2.debridged-bak` until the operator retires it.
7. Teardown stated in the report: rig killed by pidfile, claims released,
   ledger (`registry/bridge-suites.json` `_notes`) updated to `host-native`.

## 5. Rules inherited unchanged

Everything in [`AGENTS.md`](../../AGENTS.md) and the migration brief's
non-negotiables: never experiment on a live tile, kill only through
`clone-guard`, the framebuffer is the only proof, teardown is part of done,
one tile at a time until the template is written — then waves, serially
integrated. Darklaunch overlays (`serve/darklaunch.d/`) are available for
exposing a converted clone at `/os/<id>-native` style rows during side-by-side
checks without blocking anyone's push.
