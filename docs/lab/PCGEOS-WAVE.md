# PC/GEOS Ensemble integration wave — 2026-09-02

Speed-record attempt #2 (after bootOS, 45 min): integrate **PC/GEOS Ensemble**
(GeoWorks Ensemble lineage; the bluewaysw open-source build, Apache-2.0,
https://github.com/bluewaysw/pcgeos) as a fully featured Tier-1 host-native
station. Branch `pcgeos` is the ledger; every stream branches from it.

## Proven in the spine (coordinator, alone)

- `pcgeos-ensemble_nc.zip` (CI-latest, **10932546 bytes**, 743 files, 22.2 MB
  unpacked) unzips to `ensemble/` with `loader.exe`, `geos.ini`, `system/`;
  every name fits 8.3. SHA-256 in `/data/assets-staging/pcgeos/MANIFEST.sha256`.
- Disk recipe: the fleet FreeDOS 1.3 disk (`/data/gallery-guests/FreeDOS/freedos.qcow2`,
  512 MiB FAT16 LBA partition at byte offset 32256) converted to raw, then with
  mtools (`-i disk.raw@@32256`): `mcopy -s ensemble ::/ENSEMBLE`; `FDAUTO.BAT`
  (CRLF!) with `call \MENU.BAT` replaced by `cd \ENSEMBLE` + `loader`. CTMOUSE
  is already loaded by FDAUTO.BAT; `SET BLASTER=A220 I5 D1 H5 T6` too.
- `geos.ini` edits (the zip targets DOSBox): `[mouse]` LEFT AS SHIPPED (device "Basebox Mouse", driver "Abs. coord.
  Wheel Mouse" — it moves 1:1 under QEMU; the Generic Mouse/genmouse.geo entry this
  ledger first prescribed does NOT move the pointer, measured 2026-09-03);
  `screenBlanker = false` (was true, 1 minute); `Lights Out Launcher` removed
  from `[ui] execOnStartup`. Screen stays the zip default: `VESA Compatible
  SuperVGA: 800x600 64K-color`, `vga16.geo` — works on `-vga std`.
- Smoke boot on the freedos device set with `-vga std`: full desktop
  (Computer/Documents/World icons, Meadows wallpaper, taskbar, clock) ~25 s after
  power-on under KVM. Frame: `/data/vms/sandbox/pcgeos/smoke/frame1.png`.
- Dark-launched at `/os/pcgeos` (rig `/data/vms/sandbox/pcgeos/smoke/`,
  `run-daemon.sh` restarts the hand-run daemon). Pristine composed disk =
  `smoke/disk.raw` (never booted); `smoke/disk.qcow2` has been booted.

## Allocation ledger (claimed on labhost by session `pcgeos`)

| Thing | Value |
|---|---|
| id / stationDir / SH_STATION | `pcgeos` |
| slot / UDP / VMID label | 175 / 54175 / 175 |
| render orders | signal 73 · stationsManifest 71 · binding 78 · golden 71 · actionMap 43 · bringUp 78 (group 1) · build row 71, defaultOrder group 0 pos 12 |
| upstream | bluewaysw/pcgeos release tag `CI-latest`, asset `pcgeos-ensemble_nc.zip`, sha256 in the staging MANIFEST (a moving tag: the builder pins the hash, not the tag) |
| base OS | FreeDOS 1.3 from the fleet freedos disk (already built by `tiles/freedos.sh`) |
| builder output | `/data/gallery-guests/PCGEOS/pcgeos.qcow2` (pristine, no golden) |
| station dir | `/data/vms/streamhost/stations/pcgeos/` — `disk.qcow2` = the ONLY block device, carries the `golden` vmstate |
| device set | freedos's, with `-vga std`: `pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0`, KVM, `-cpu host`, 64 MB, 2 vCPU, sb16 + dbus audiodev, ne2k_pci user net, PS/2 relative pointer |
| screen | 800x600 16-bit VESA |

## Streams (each: `scripts/dev/wt.sh new <name> --from pcgeos`, commit on its branch, push, 4-minute stop)

| Stream | Deliverables |
|---|---|
| `pcgeos-build` | `scripts/build-guests/tiles/pcgeos.sh` (fetch zip, verify SHA-256, compose from the freedos disk exactly as above, framebuffer-verify the desktop); RUN it so `/data/gallery-guests/PCGEOS/pcgeos.qcow2` exists; `check-assets.sh`, `docs/lab/ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md` row |
| `pcgeos-golden` | bake `golden` on a sandbox clone from `smoke/disk.raw` with the exact launcher; one `loadvm` restore proof; stage `disk.qcow2` into the station dir; `scripts/coldboot/bootrec-tiles.conf` arm (replace the scaffold `pcgeos-bootrec-arm.sh`); write §Checkpoint of `docs/guests/pcgeos.md` |
| `pcgeos-spa` | `registry/posters/pcgeos.md` + `spa/public/posters/pcgeos/desktop.webp` from real frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`; `museum`/`spa` polish; a `demoProgram` only if a keyboard-driven one makes sense |
| `pcgeos-docs` | `docs/guests/pcgeos.md` prose (not §Checkpoint), `docs/GUEST-TIERS.md`, release notes JSON, `docs/README.md` index if needed |

## Reserved to the coordinator

Merging to `main`, `git push origin main`, `scripts/dev/box-deploy.sh --apply`,
`scripts/dev/station-up.sh pcgeos`, the SPA build/deploy, withdrawing the smoke
overlay, and the final framebuffer acceptance.

## Absolute pointer (2026-09-03, coordinator alone, ~40 min)

Operator: "pointer based graphical OSes need absolute cursor positioning before
they are considered fully integrated." Route: `kh-ramabs` (beos/rhapsody), because
DOS's CTMOUSE understands no absolute device and `-vga std` has no hardware cursor,
but CTMOUSE keeps the pointer as int16 x,y in its resident data and GEOS's
GEOS's mouse driver takes the absolute CX/DX from the INT 33h callback. Steps: re-bake
the golden under `/opt/qemu-beos` (binary + golden are one unit); five positions at
2-unit steps (1:1 below GEOS's acceleration; 20-unit packets accelerate ~1.4x),
screendump + `pmemsave` of the first 1 MB, bias search → six (0,0) candidates;
one QEMU start per candidate with the device's connect-time write probe → exactly
one verified, `0x76e0`; MOVEA sweep pixel-exact at five targets. Tooling:
`scripts/dev/pcgeos-ramabs-derive.py`. Trap: a reference frame with the pointer
clipped at the screen edge still shows 3 px of the sprite — mask it.

## KR-11 in GeoWrite (2026-09-03, operator-found)

The operator opened GeoWrite → new document in the browser and got `System Error
Code: KR-11` (= general-protection fault). Bisected on three parallel sandbox rigs
in ~10 minutes: it is the `truetype.geo` font driver under KVM (also with
`-cpu pentium3`); without that `font = {}` line GeoWrite works and text renders.
Shipped: builder strips the line, golden re-baked (address re-derived). Details:
`docs/guests/pcgeos.md`. Lesson for the playbook: **open a document in the
flagship app before calling a GUI station done** — the smoke boot and the Express
menu proved nothing about the apps.
