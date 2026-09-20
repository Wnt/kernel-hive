# cpm22 wave — CP/M 2.2 on a Kaypro II

Tracking: #55 · prep branch `cpm22` · worker branch `cpm22-work`

## Allocation (wave.sh alloc, 2026-09-20T08:54:25Z)

| Station | Session | Slot / UDP / VMID | X-warp | retronet |
|---|---|---|---|---|
| cpm22 | cpm22-work | 206 / 54206 / 206 | — (not needed: keyboard-only, no pointer) | — (not needed: no network) |

## Scaffold

```
python3 scripts/stations-registry.py new cpm22 --like apple2gs --production --slot 206 \
  --tuple none,compactA,none,none
```

Hardware tuple `none|compactA|monitor|none|none` (body=none, monitor=compactA — the
same "combined body+screen" model macsys1 uses for an integrated all-in-one —
keyboard=none, mouse=none): the Kaypro II is an integrated luggable with no
separate keyboard/body/mouse model in the kit, and no sibling held this
combination.

## Correction to the integration seed

`docs/lab/integration-seeds/cpm22.md` proposed MAME driver **`kaypro2`**.
That name does not exist as a MAME machine — confirmed against a stock MAME
0.276 system package's `-listxml` on labhost, 2026-09-20. The real driver is
**`kayproii`** (`src/mame/kaypro/kaypro.cpp`, `COMP(1982, kayproii, ...)`).
`kaypro2` is only `formats/kaypro_dsk.cpp`'s *floppy-format* name string
(`kayproii_format::name()` returns `"kaypro2"`), which is presumably where
the seed's guess came from.

## ROM set (MEASURED 2026-09-20)

The DEFAULT bios (`149`, file `81-149.u47`, CRC `28264bc1`, board 81-110) has
no surviving dump on any mirror checked. Shipping **bios `149c`**
(`81-149c.u47`, same board family) instead — the revision archive.org's
dedicated `81149c_KayproII_ROM` item preserves.

A SECOND, separate MAME device romset is required alongside `kayproii.zip`:
`kaypro10kbd.zip` (`m5l8049.bin`, the Kaypro 10/II keyboard's Intel 8049 MCU
dump). This driver's keyboard connector is HLE'd through that MCU (device
`kaypro10kbd`, `src/mame/kaypro/kay_kbd.cpp`) since around MAME 0.260,
**not** the older `keytronic_l2207` ROM the repo's older MAME submodule
source trees (`third_party/mame-irix`, `third_party/mame-mpf2`) still show —
those are stale relative to the fleet-pinned `mame0289` tag. Without
`kaypro10kbd`'s ROM staged, MAME refuses to run at all: `m5l8049.bin NOT
FOUND (tried in kaypro10kbd kayproii)`.

| File | Bytes | SHA-256 | Source |
|---|---|---|---|
| `81-149c.rom` → `81-149c.u47` | 2048 | `5231e5dd0f6fb64a8ec50951269c248e00875906e391d044918e212d14b08f55` | retroarchive.org/maslin/roms/kaypro/81-149c.rom |
| `81-146a.rom` → `81-146.u43` (chargen) | 2048 | `cde431c9e506edf11261f7e7d52fd60b1a43fe2d9ea0d3e06f271d4cab4884fa` | retroarchive.org/maslin/roms/kaypro/81-146a.rom |
| `m5l8049.bin` | 2048 | (crc32 `dc772f80`, matches `-listxml` exactly) | archive.org `bittorrent-e7d4d1eecb938d69888495adb9d931d538f90572` ("MAME 0.266 ROMs (bios-devices)"), member `kaypro10kbd.zip` |

Zip pinned in the builder: `KBD_MCU_SHA256=b3572b3446dada53257a6af0e8b8304e66cb31a5dc1b38c4a5994339fb569c22`.

## Media (MEASURED 2026-09-20)

Source: Internet Archive item `Kaypro_II_TOSEC_2012_04_23` (TOSEC "Kaypro II"
preservation set, 2012-04-23), one outer zip
(`TOSEC_SHA256=c0da43cd9fd4aeb91b78e2374582cbad80f663722db976c65a0e3535e799db17`).

| File | Bytes | SHA-256 | TOSEC member |
|---|---|---|---|
| `cpm22-boot.td0` | 139911 | `ce3e89b4d929596d49417403cfbf1dfbc70cbbe7449d3d8c25f46b94c7c5dbb3` | `Kaypro II - Operating Systems - [IMD]/CP-M 2.2 Boot Disk (19xx)(Digital Research)(DE).zip` → `.td0` (TOSEC's folder label says IMD; the actual member is a Teledisk image) |
| `wordstar33.imd` | 202296 | `7cfe1b6015867a91bd2fda467b99e827c9f239b63033be1973a41d2d826da642` | `Kaypro II - Applications/WordStar v3.3 (1983)(MicroPro).zip` → `.imd` |

### Why the media ships as TOSEC .td0/.imd, unconverted

The integration draft assumed a raw disk image, converting TD0/IMD "during
the builder into the exact floppy format MAME consumes" if needed. Tried
that first (`libdsk`'s `dsktrans -itype tele -otype raw`): the output was
byte-size-correct (204800 bytes = 40 tracks × 10 sectors × 512, matching
`kayproii_format`'s geometry) with **no read errors reported**, but booting
it froze forever at the ROM's `"Please place your diskette into Drive"`
banner. `dsktrans`'s raw driver writes sectors in PHYSICAL encounter order
(track dump showed IDs `002..011`, not `001..010`); `kayproii_format`'s
raw dump is "simply a dump of the 512 bytes from each sector and track IN
ORDER" (its own source comment) — i.e. LOGICAL order — so the converted
image looks unformatted to the ROM's own read loop.

MAME reads `.td0`/`.imd` **natively** (confirmed via `-listmedia`, extension
list includes both). Feeding the untouched TOSEC `cpm22-boot.td0` straight to
`-flop1` booted cleanly to the real `KAYPRO CP/M 2.2 (GMv2.72)` `A>` prompt
with a live directory listing, first try. **Lesson for the next TD0/IMD
station: try MAME's native reader before writing a converter.**

## Smoke proof (2026-09-20, stock MAME 0.276 system package — NOT the
fleet-pinned 0.289 native binary, see below)

`/usr/games/mame kayproii -bios 149c -rompath <staged roms> -flop1
cpm22-boot.td0 -video soft -skip_gameinfo -nothrottle -sound none
-autoboot_script <lua: emu.wait + snapshot>`

1. Cold power-on, no floppy: `* KAYPRO II * / Please place your diskette
   into Drive` (green phosphor text banner) — framebuffer PNG captured.
2. Cold boot WITH `cpm22-boot.td0` on `flop1`: real `A>` prompt with the
   disk's own directory listing (`ASM/BAUD/DDT/DUMP/ED/LOAD/MOVCPM/PIP/
   STAT/SUBMIT/SYSGEN/...`) — framebuffer PNG captured, `spa/public/
   posters/cpm22/desktop.webp` is this frame.
3. `emu.keypost("DIR\n")` through MAME's natural-keyboard path: the listing
   re-ran cleanly from `A>`, no dropped/duplicated characters over a short
   command — framebuffer PNG captured.

All three frames are real MAME pixels (drawshm-equivalent PNG snapshots),
not inferred from logs, per rule 9.

## Status at handoff (2026-09-20, ~T+1h45)

Handing off mid-flight: labhost is at load 124 on 16 cores with 11 MAME
native builds running concurrently (this station's build was reniced to 19
under `nohup` and keeps running unattended — do not relaunch it, check its
log first).

**The fleet-pinned 0.289 native binary COMPILED and LINKED successfully**:
`/data/vms/streamhost/assets/cpm22/mame-native/kayproii` exists (built via
`bash scripts/build-guests/emulators/build-mame-native.sh cpm22
/data/vms/sandbox/cpm22-work/BUILD-native-cpm22
/data/vms/streamhost/assets/cpm22/mame-native/kayproii`, log at
`/data/vms/sandbox/cpm22-work/native-build2.log`). Its own boot gate then
FAILED — not a build problem, a ROM-set problem, described below.

### The one blocking discovery: the keyboard ROM differs between MAME trees

The early smoke proof (frames captured, see "Smoke proof" above) used a
**stock MAME 0.276 Debian system package**, which resolves the Kaypro
keyboard through device `kaypro10kbd` (an Intel i8049 HLE,
`m5l8049.bin`, CRC `dc772f80`) — that ROM was sourced and staged and IS what
made the smoke frames possible.

Running `-listxml` on the **actual freshly-built mame0289 binary** (the one
that will ship) shows a DIFFERENT device: `kayproiikbd`
(`devices/bus/keytronic/keytronic_l2207.cpp`, an Intel i8048 HLE) needing
**`kaypro_ii-ins8048.bin`** — 1024 bytes, CRC `f65e1ca5`, sha1
`7919385fe8badbb610b793a3f5e4077982094aaa`. Confirmed by running the build
output directly:

```
ssh lab '/data/vms/sandbox/cpm22-work/BUILD-native-cpm22/mame/kayproii -listxml kayproii | grep -A3 kayproiikbd'
```

The 0.289 boot gate failed with exactly this:
`kaypro_ii-ins8048.bin NOT FOUND (tried in kayproiikbd kayproii)` — log at
`/data/vms/sandbox/cpm22-work/BUILD-native-cpm22/gate/mame.log`.

`scripts/build-guests/emulators/native.d/cpm22.sh` has ALREADY been
corrected to stage `kayproiikbd` (not `kaypro10kbd`) — see its
`native_stage_roms` comment. `scripts/build-guests/tiles/cpm22.sh` is
flagged KNOWN-STALE at its top (still fetches the wrong ROM/URL) and has
NOT been fixed yet — that is the single next concrete step.

### Next concrete step

1. Source `kaypro_ii-ins8048.bin` (sha1
   `7919385fe8badbb610b793a3f5e4077982094aaa`). Attempted at handoff:
   archive.org item `mame-bios-devices` ("MAME (bios-devices).zip", 434 MB)
   is believed to carry a `kayproiikbd.zip` member — a zip-in-zip fetch via
   `https://archive.org/download/mame-bios-devices/MAME%20%28bios-devices%29.zip/kayproiikbd.zip`
   returned a transient 503 once, then an "entry not found" error page from
   `view_archive.php` on a second try (unzip -p exit 11) — the exact member
   PATH inside that outer zip was not confirmed before handoff. Also
   unchecked: the older submodule tree `third_party/mame-irix/src/devices/
   bus/keytronic/keytronic_l2207.cpp` names this exact ROM in its
   `ROM_START(kayproii_keyboard)` block (same CRC/sha1) — if that submodule
   was ever built, its staged ROM artifacts (if any survive on labhost)
   would already have the right file. Worth a `find` before re-fetching.
2. Stage it to `/data/assets-staging/cpm22/roms/kaypro_ii-ins8048.bin`,
   record its manifest line, fix `scripts/build-guests/tiles/cpm22.sh`'s
   `KBD_MCU_*` block (URL/sha256/paths) to match `native.d/cpm22.sh`'s
   `kayproiikbd` naming.
3. Re-run the boot gate against the ALREADY-BUILT binary (no rebuild
   needed — this is a rompath-only fix):
   ```
   ssh lab '/data/vms/sandbox/cpm22-work/BUILD-native-cpm22/mame/kayproii -bios 149c \
     -rompath /data/vms/streamhost/assets/cpm22/mame-native/roms \
     -flop1 /data/vms/streamhost/assets/cpm22/media/cpm22-boot.td0 \
     -video soft -skip_gameinfo -nothrottle -sound none -window \
     -autoboot_delay 1 -autoboot_script <lua: emu.wait(6); snapshot>'
   ```
4. Once the gate passes on THIS binary: capture the golden savestate,
   dump the real keymap (`scripts/dev/mame-keymap.py <ctl.sock>`, never
   hand-authored — the checked-in `cpm22.keymap` is still the apple2gs
   scaffold placeholder), measure `MAME_CTL_KEY_EXCL` from the real browser,
   flip `MAME_NATIVE_CHECKPOINT=1`, then `scripts/dev/station-land.sh
   cpm22`.

### What IS proven, by real framebuffer pixels (not logs — rule 9)

All three captured on a stock MAME 0.276 system package (same driver
`kayproii`, same bios `149c`, same media), staged under
`/data/vms/sandbox/cpm22-work/smoke/`:

- `boot-gate.png` / `boot-gate-30s.png` — cold power-on, no floppy: the real
  `* KAYPRO II * / Please place your diskette into Drive` banner.
- `boot-td0.png` — cold boot WITH `cpm22-boot.td0` on flop1: the real
  `KAYPRO CP/M 2.2 (GMv2.72)` `A>` prompt with a live directory listing
  (this frame is `spa/public/posters/cpm22/desktop.webp`).
- `dir-typed.png` — `emu.keypost("DIR\n")` through MAME's natural-keyboard
  path re-ran the listing cleanly from `A>`.

**Not yet true**: `/os/cpm22` is NOT published (smoke-rig.sh does not
support MAME-native stations — no QMP/QEMU here — so this station's "smoke
rig" is the boot-gate frame above, not a running dark-launched daemon
process; the real dark-launch is `scripts/dev/station-up.sh cpm22` after a
main-branch deploy, which needs the corrected ROM + golden first). Nothing
has been landed. Registry validates, SPA vitest/eslint/knip/tsc and the
Python/shell/file-size/drift gates were all green on this branch as of
handoff (see the commit this file ships with).

## Landing (RESOLVED 2026-09-20, resume session)

Landed on `main` (`367990f6`), deployed, then INCIDENT and FIX in the same
session:

1. **The ROM.** Sourced `kaypro_ii-ins8048.bin` from archive.org item
   `mame-roms-split` ("MAME 0.280 ROMs (split)") — that item serves every
   romset as a plain downloadable file, unlike `mame-bios-devices`'s
   zip-in-zip `view_archive.php` path (which 503'd, then 404'd, at handoff).
   sha1/CRC verified exact against the driver's own `-listxml`. Restaged the
   mame-native rompath against the ALREADY-BUILT binary (no rebuild), re-ran
   both boot gates — cold-boot floor lowered 4000→2500 (measured 3163 lit px
   on the real 1024x768 drawshm surface; the old floor was carried over from
   a different raster). Captured and restore-proved the golden savestate
   (`sta/kayproii/golden.sta`, 14338 bytes, sha256
   `bba86537a6a02963ddecdd908e6ed22cc02708852310a4716c1bff54f4ae4bd5`), dumped
   the real keymap (76 keys, replacing the stale apple2gs placeholder),
   proved `DIR` over ctlsock (POST+CODE{ENTER}) with no dropped/duplicated
   characters. Landed via `station-land.sh`.

2. **The incident.** Live and listed, `/os/cpm22` showed solid black —
   flagged immediately by the coordinator reading a real `labctl shot`
   (rule 9). Root cause, found by reproducing the EXACT production argv in a
   sandbox rig and reading MAME's own `ui.cpp`: `kayproii` flags "imperfect
   sound" (its beeper device), which makes
   `mame_ui_manager::display_startup_screens()` show a MODAL "known
   problems... Press any key to continue" panel — gated separately from
   `-skip_gameinfo` (a different screen entirely) and auto-disabled ONLY
   when `-str` is under 300s or `-video none`, neither true in production.
   With `MAME_NO_UI=1` the panel composites nothing (kiosk-no-ui strips ALL
   UI primitives) but the modal input-wait behind it still blocks the
   machine from ever reaching `machine_phase::RUNNING` — so ctlsock's
   `setup()` never fires, no verb ever gets acked
   (`[mamesock] ack timeout; reconnecting`, forever), and the framebuffer
   stays black. Plain `ui.ini` `skip_warnings 1` does NOT fix this on a
   fresh process (upstream's condition needs a persisted same-warning memory
   a first launch never has) — it needs `mame-irix-skip-warnings.patch`,
   which domainos and newsos (the fleet's other two audio-off MAME-native
   stations) already carry for the identical reason. This stanza's header
   had claimed "no skip-warnings patch is needed" — wrong.

3. **The fix.** Added `mame-irix-skip-warnings.patch` to
   `NATIVE_EXTRA_PATCHES`, `NATIVE_SKIP_WARNINGS=1` /
   `MAME_NATIVE_SKIP_WARNINGS=1`. Rebuilt (incremental, ccache 100% hit,
   ~1 min); both boot gates still pass. Reproduced the exact production
   argv against the OLD binary first (confirmed the hang), then the NEW one
   (confirmed fixed) in a sandbox rig before touching the live station.
   Re-emitted + restarted; `labctl shot cpm22` x3 over 8s: identical real
   `A>` prompt frames, journal shows `health=Healthy`, one HELLO (no
   reconnect loop). Regenerated the poster hero from the live, fixed scene.

**OPEN**: the real-browser typing proof. `tests/e2e-live/cpm22-key-probe.mjs`
is written and ready, but `/os/:osId` only mounts the live view for an
admin/viewer session (`spa/src/ui/grid/exhibitAccess.ts`) — an anonymous
Playwright context (no passkey credentials in this sandbox) cannot reach it,
confirmed NOT cpm22-specific (an unmodified `nextstep-key-probe.mjs` hits the
identical timeout against the same deployed gallery). The ctlsock-level
typing proof (item 1 above) exercises the same daemon input path. Run the
probe from a session with an authenticated storageState, or the operator
opens `/os/cpm22` directly.

**Lesson for the next audio-off MAME-native station**: check `-listxml` for
`imperfect_features`/`unemulated_features` BEFORE landing, not after —
`NATIVE_SKIP_WARNINGS=1` + `mame-irix-skip-warnings.patch` are required, not
optional, whenever the driver flags anything imperfect, and the fastest way
to prove it is reproducing the EXACT production argv (`-throttle`, no
`-str`, every device flag the fixture ships) in a sandbox rig — a `-str`ed
or `-nothrottle`d smoke test can pass while production hangs.
