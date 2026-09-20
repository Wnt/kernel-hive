# palmos wave — Palm III, host-native MAME, a genuinely absolute pen

## RESUME HERE (checkpoint written 2026-09-20 ~09:35Z — build still compiling)

Everything below is pushed to `origin/palmos-work` (HEAD `9427f35e` at
checkpoint time) — registry scaffold (candidate/disabled, see "Why candidate"
below), the new `mame-ctlsock-abs-fields.patch`, the fixture, keymap
placeholder, wave doc, all docs. **Nothing is at risk of loss.**

**Not yet done / not yet proven by framebuffer:**

- The MAME binary build (`build-mame-native.sh palmos`) was still compiling
  at checkpoint time — cold ccache for `src/mame/palm/palm.cpp`, box under
  heavy concurrent load from sibling waves (34 `cc1plus`/`gcc` processes
  observed via `ps aux` at 09:31Z). No compile error seen; just slow.
- `/os/palmos` is **NOT published**. No framebuffer capture exists yet at
  all — the pointer-route design is source-verified (read against
  `mame/palm/palm.cpp`) but UNPROVEN on a live rig. Do not report it working
  until a real frame shows it.

**Exact command to resume the build** (same work/out dirs — resumes
incrementally, does not restart):

```
cd /data/vms/sandbox/palmos-work/repo
JOBS=6 scripts/build-guests/emulators/build-mame-native.sh palmos \
  /data/vms/sandbox/palmos-work/BUILD-native-palmos \
  /data/vms/sandbox/palmos-work/build/palmos-mame \
  > /tmp/palmos-build.log 2>&1 &
# poll: tail -f /tmp/palmos-build.log ; grep -c Compiling /tmp/palmos-build.log
```

**Single next concrete step once the binary exists**
(`/data/vms/sandbox/palmos-work/build/palmos-mame/palmos`, or wherever the
above run lands it — check `[ -x ... ]` after the run):

```
cd /data/vms/sandbox/palmos-work/repo
mkdir -p /tmp/palmos-smoke && cd /tmp/palmos-smoke
MAME_SHM_PATH=$PWD/fb.shm MAME_SHM_SIZE=160x220 \
MAME_CTL_SOCK=$PWD/ctl.sock MAME_CTL_ABS=1 \
MAME_CTL_PTR_TAGS=:PENB,:PENX,:PENY MAME_CTL_BTN_NAMES=Pen Button,, \
MAME_CTL_SCREEN=160x220 \
  /data/vms/sandbox/palmos-work/build/palmos-mame/palmos palmiii \
  -rompath /data/assets-staging/palmos/roms -bios 3.3f \
  -video shm -sound none -skip_gameinfo -nothrottle -str 10 \
  -homepath . -cfg_directory ./cfg -nvram_directory ./nvram -inipath . \
  > mame.log 2>&1 &
# then read fb.shm (64-byte header + WxHx4 BGRA, see native_gate_nonblack in
# build-mame-native.sh for the exact struct) and save a PNG — THAT PNG is the
# framebuffer proof this wave still needs. Once non-black: connect to
# ctl.sock, send MOVEA <x> <y> for five points spread across 0..159 x 0..219,
# DOWN1/UP1, and diff frames before/after each to prove the pointer route.
```

Record-wave worker task, issue #48, Lane A. Prep branch `palmos`
(`docs/lab/integration-seeds/palmos.md`, `docs/lab/integration-drafts/palmos/`,
`docs/lab/spa-drafts/palmos.md`). Worked from `origin/palmos` in worktree
`palmos-work`, session `palmos-work` (`wave.sh alloc palmos`, no `--retronet`/
`--x11warp` — the seed's own call: "network/audio off for the first wave").

## Ledger (`wave.sh alloc palmos`, session `palmos-work`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet |
|---|---|---|---|---|
| palmos | palmos-work | 207 / 54207 / 207 | — | — |

| Fact | Value | Measured by |
|---|---|---|
| Scene tuple | `pizzaBoxB,none,none,none` | this worker — every `phoneA/B/C` handheld body is already taken (android, postmarketos, sailfishos); no PDA-shaped 3D asset exists yet, so this station borrows the smallest free peripheral-less body rather than block on new geometry. Genuinely OPEN: a real handheld model is spa/asset work, not something this wave can do inside its budget. |
| MAME driver | `palmiii` — `src/mame/palm/palm.cpp`. **NOT** `palmm505`: in MAME 0.289 `palmm505` (and `palmv`/`palmvx`/`palmm130`/`palmm515`/`visor`) all carry `MACHINE_NOT_WORKING`; `palmiii` is the only driver in the whole Palm family that ships `MACHINE_SUPPORTS_SAVE` with no working-flag caveat. The seed's own fallback order (Palm III first) is also, in this MAME version, the *only* option — this was not a race, `palmm505` never got the chance. | this worker, reading `mame/palm/palm.cpp:991-1006` before any build |
| ROM | `palmos33-fr-iii.rom`, 2 097 152 B, sha1 `c7c90df814d4f97958194e0bc28c595e967a4529` — a BYTE-EXACT match for the `palmos33-fr-iii.rom` BIOS option `palmiii` compiles in (`PALM_68328_BIOS` macro, `mame/palm/palm.cpp:829-831`). Sourced as `Palm-III-3.3-fr.rom` from `https://palmdb.net/app/palm-roms-complete`, staged to `/data/assets-staging/palmos/roms/palmos33-fr-iii.rom` on labhost via `ssh lab`, `MANIFEST.sha256` written there. | this worker: downloaded five candidate files from palmdb (`Palm-III-3.3-en/de/fr.rom`, `Palm-III-3.5-en.bin`, `Palm-III-4.1-en.rom`), hashed all five, compared against every `ROM_SYSTEM_BIOS`/`ROMX_LOAD` line in the macro. Only the **French** and **German** 3.3 dumps matched byte-for-byte (German: `a5a99c45`/`209b0154942dab80b56d5e6e68fa20b9eb75f5fe`, also usable). `Palm-III-3.3-en.rom` is 1 343 488 B — a *different*, non-matching dump — and no other palmdb page (`upgrade-os4`, which turned out to hold Windows flash-tool `.zip`/`.sit` installers, not raw ROM dumps) had one either. **This wave picked French because it verified first**, not for any other reason; German is an equally proven fallback if a later stream sources an English dump and wants to compare. |
| Locale decision | Ships Palm OS 3.3 **French**. No byte-exact English 3.x ROM was found for the `palmiii` driver inside this wave's 2-hour budget. This is a real, documented gap — not a guess dressed as a fact — flagged in the registry's `museum.notes` and `listing.reason`. | this worker |
| Pointer route | **NEW**: `scripts/build-guests/patches/mame-ctlsock-abs-fields.patch`. Palm's pen is `IPT_LIGHTGUN_X`/`IPT_LIGHTGUN_Y` (`mame/palm/palm.cpp:509-516`, `PORT_MINMAX(0,0xa0)`) — a genuinely ABSOLUTE analog ioport field whose current value *is* the pen position, latched by the `Pen Button` field's `PORT_CHANGED_MEMBER`. Every existing ctlsock pointer route (MOVEA's closed-loop cursor-register convergence, its open-loop dead-reckoning fallback, the abs-ram guest-RAM-poke route) is built for a RELATIVE device — a guest that reads a delta, or keeps its own belief of the pointer in RAM the module can read back. None of them fit: there is no cursor register to read (there is no on-screen cursor at all) and the field is not RAM the guest polls, it is the input itself. The new patch adds `MAME_CTL_ABS=1`: when set, `movea_target()` short-circuits before any accumulator/dead-reckoning code runs and writes `m_x_field`/`m_y_field` directly, scaled from the published surface (`MAME_CTL_SCREEN`) into each field's own declared range via `ioport_field::minval()`/`maxval()` — nothing hardcoded to Palm. Applies after `mame-ctlsock.patch` + `mame-ctlsock-ptr-tags.patch` (which bind the fields and parse the surface size); unset reproduces every existing caller unchanged (`m_abs_fields` defaults false). | this worker: read the base ctlsock/ptr-tags/abs-ram patches to find the wall, wrote the ~50-line patch, dry-ran it against a freshly cloned+patched `mame0289` tree (clean apply), diffed against the pre-edit tree to produce the committed patch file |
| Pointer binding | `MAME_CTL_PTR_TAGS=:PENB,:PENX,:PENY` `MAME_CTL_BTN_NAMES=Pen Button,,` `MAME_CTL_SCREEN=160x220` `MAME_CTL_ABS=1` — tags/names read from `mame/palm/palm.cpp` `INPUT_PORTS_START(palm_base)` (`PORT_START("PENX")`/`("PENY")`/`("PENB")`, field names "Pen X"/"Pen Y"/"Pen Button"). | this worker, from source; **PROOF STATUS below** |
| Published surface | `160x220` — the driver's own `set_visarea(0,159,0,219)` (`mame/palm/palm.cpp:617`). No letterbox math: the whole published surface IS the pen's coordinate space, unlike every letterboxed MAME station in the fleet. | this worker, from source |
| Device set | `MAME_NATIVE_ARGS=-bios 3.3f` (the `ROM_SYSTEM_BIOS` short name for the matched French dump, id 10) | this worker |
| Hardware buttons | `palmiii`'s `PORT_START("PORTD")` (`mame/palm/palm.cpp:522-529`) defines seven real device buttons — Power (`KEYCODE_D`), Up (`KEYCODE_Y`), Down (`KEYCODE_H`), and four app-launch buttons "Button 1..4" (`KEYCODE_F`/`G`/`J`/`K`) — the historical Date Book/Address Book/To Do/Memo Pad quick-launch row plus the scroll rocker. Because MAME binds them to plain PC keycodes, they are already reachable from any physical/on-screen keyboard, satisfying the wave rule's letter (not hidden host shortcuts); `streamhost/stations/palmos/palmos.keymap` gives them museum labels instead of bare letters — **PLACEHOLDER scancodes, not yet KEYDUMP-verified against a running rig; regenerate with `scripts/dev/mame-keymap.py` before promoting**, see OPEN below. |

## Build

`scripts/build-guests/emulators/native.d/palmos.sh` (new stanza): driver
`palmiii`, subtarget `palmos`, `SOURCES=src/mame/palm/palm.cpp`, patches
`mame-ctlsock.patch mame-drawshm.patch mame-kiosk-no-ui.patch
mame-ctlsock-ptr-tags.patch mame-ctlsock-abs-fields.patch` (the fleet base
trio plus the two pointer-binding patches this station needs), `NATIVE_GEOM=
160x220`, `NATIVE_MAME_ARGS=(-bios 3.3f)`. ROM staged via `stage-romset.py`
against `/data/assets-staging/palmos/roms` (the CT950-side path; labhost's is
different — this worker staged directly on labhost over `ssh lab`, per the
assets-staging mount-split platform fact).

Built with `JOBS=6 scripts/build-guests/emulators/build-mame-native.sh palmos
/data/vms/sandbox/palmos-work/BUILD-native-palmos
/data/vms/sandbox/palmos-work/build/palmos-mame` — **cold ccache** for this
`SOURCES` filter (first `palm/palm.cpp` build on the box), so the compile
alone ran long past the usual few-minute incremental rebuild; see the
measured timestamps below.

## Proof status (fill in as the rig proves each line — DO NOT mark PASS from a log)

| Proof | Status |
|---|---|
| `palmiii` reaches a non-black framebuffer on `-video shm` | PENDING — build in flight at report time |
| Golden scene is the Applications Launcher | OPEN — a fresh `palmiii` boot with no NVRAM most likely lands on Palm OS's own Welcome/digitizer-calibration flow first, not the Launcher; the golden stream needs to walk past it (or ship the calibration screen honestly documented, if it cannot be scripted past inside the stop rule) |
| Five-target pointer accuracy | OPEN — needs the running rig; `MOVEA` on the new abs-fields route should be **exact** (no accumulator, no gain, no convergence — the field IS the position) modulo the field's own 161-step (0..0xa0) quantization across a 160 px axis, i.e. sub-pixel-exact by construction if the binding is right. Framebuffer proof is what turns "should be" into "is". |
| Drag (pen stroke) | OPEN — same rig |
| Reset returns to golden scene | OPEN — same rig |
| Hardware buttons reachable | PARTIAL — bound over ctlsock (source-confirmed), on-screen labels are a placeholder pending KEYDUMP |

## What is genuinely new this wave

The pointer route (`mame-ctlsock-abs-fields.patch`) is a fourth family
alongside the existing three (closed-loop cursor-register convergence,
open-loop dead reckoning, guest-RAM absolute write): a direct absolute-ioport
write. It exists because Palm's digitizer is the first MAME-native station in
this fleet whose pointer ioport field is not a relative counter and has no
on-screen cursor to read back — every prior "absolute" route in the fleet
(macsys1, apple2gs, oberon) still worked by *reading something back*
(guest RAM or a cursor register) to close a loop; Palm's pen has nothing to
read back because there is no cursor, only a touch. Any future MAME station
whose input is a true `IPT_LIGHTGUN`/touchscreen-style analog field (rather
than a mouse) can reuse this same `MAME_CTL_ABS=1` knob unchanged.

## OPEN (next stream's, in priority order)

1. **Golden scene**: reach and capture the Applications Launcher (not the
   Welcome/calibration flow), and re-run the pointer proof against that
   scene specifically — the digitizer calibration screen itself needs
   accurate pen taps to get past, which is a good first real test of the
   new pointer route, but the calibration corners are not the exhibit.
2. **English ROM**: source a byte-exact English Palm OS 3.x/4.x dump for the
   `palmiii` (or a working later driver, if a future MAME version fixes
   `palmm505`) BIOS options; promote past the French/German-only proof.
3. **Keymap**: regenerate `palmos.keymap` for real with
   `scripts/dev/mame-keymap.py` against the built rig's `KEYDUMP`, and give
   the seven hardware buttons real on-screen-keyboard labels/icons in the
   spa layer (`keyboardProfiles.ts`) instead of relying on a physical
   keyboard's D/Y/H/F/G/J/K.
4. **PDA body model**: `pizzaBoxB` is a placeholder scene tuple; a real
   handheld-shaped 3D asset is spa/asset work this wave did not attempt.
5. **Promote**: flip `listing.state` once 1-3 are proven; this wave ships
   dark-launched (`hidden`) on purpose.

## Session timeline (measured, `date -u`)

- 08:54Z — worker started, read AGENTS.md / OPERATING-RULES.md / brief docs
- 08:55Z — `wt.sh new palmos-work --from origin/palmos`
- 08:56Z — `wave.sh alloc palmos` → slot/UDP/VMID 207
- 08:59Z — found MAME 0.289 has no Palm driver in the *station-pinned* trimmed
  binaries; located the real driver in `third_party/mame-irix` source,
  confirmed `palmiii` is the only non-`MACHINE_NOT_WORKING` Palm target
- 09:00Z — sourced and hash-matched the ROM (palmdb.net), staged to labhost
- 09:03-09:06Z — designed, wrote and dry-ran `mame-ctlsock-abs-fields.patch`
  against a clean `mame0289` + base-patches tree
- 09:07Z — `native.d/palmos.sh` stanza written; registry scaffolded
  (`--like postmarketos --tuple pizzaBoxB,none,none,none --slot 207`),
  rewritten for the MAME-native shape; `stations-registry.py validate` green
- 09:08Z — `build-mame-native.sh palmos` started (cold ccache for this
  `SOURCES` filter)
- 09:14Z — first ledger commit pushed (`3acec6c5`); build still in the
  layout-compression phase (fixed cost, not narrowed by `SOURCES`)
- 09:16-09:23Z — discovered `machines.test.ts`/`tileWiring.test.ts` require a
  screen-bearing 3D body for every enabled tile; no free PDA-shaped asset
  exists (`phoneA/B/C` all taken by android/postmarketos/sailfishos) — landed
  as `lifecycle: candidate, enabled: false` instead of guessing UV
  coordinates on an unrelated body; pushed (`9427f35e`), pre-push gate green
- 09:31-09:35Z — build still compiling 3rdparty/core objects; box carries
  concurrent load from sibling waves (34 `cc1plus`/`gcc` processes observed).
  **This checkpoint was written here** rather than continuing to wait on the
  build inline.
- *(fill in: build completion, smoke boot, pointer proof, landing/promotion)*

## Reusability note for sibling MAME-native stations (cpm22, riscos3, msx2, …)

`mame-ctlsock-abs-fields.patch` is NOT Palm-specific. Any MAME driver whose
pointer/touch input is a true absolute analog ioport field (an `IPT_LIGHTGUN`
or similarly `PORT_MINMAX`-ranged field that the emulated CPU reads directly
as a position, rather than a relative mouse counter or a value the guest
re-derives from RAM) can reuse the same `MAME_CTL_ABS=1` knob — no per-field
code, just `MAME_CTL_PTR_TAGS`/`MAME_CTL_BTN_NAMES` pointed at that driver's
own port tags and field names, and `MAME_CTL_SCREEN` matching the published
surface. If any of `cpm22`/`riscos3`/`msx2` turn out to need a genuine
touchscreen/lightgun-style bind (unlikely for those three specifically, since
none are touch machines by history, but worth a five-minute check against
each driver's `INPUT_PORTS_START` before assuming a relative mouse route),
this patch is already on `origin/palmos-work` and can be cherry-picked or
patched-in directly rather than re-derived.
