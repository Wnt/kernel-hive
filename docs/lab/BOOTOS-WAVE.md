# bootOS integration wave — 2026-09-02

Speed-record attempt: integrate **bootOS** (Óscar Toledo G., 2019 — an entire OS in
one 512-byte boot sector, https://github.com/nanochess/bootOS, BSD-2) as a fully
featured Tier-1 host-native station, with four parallel streams and one
coordinator. Branch `bootos` is the ledger; every stream branches from it.

## Allocation ledger (claimed on labhost by session `bootos`, hands-off)

| Thing | Value |
|---|---|
| id / stationDir / SH_STATION | `bootos` |
| slot / UDP / VMID label | 174 / 54174 / 174 |
| render orders | signal 72 · stationsManifest 70 · binding 77 · golden 70 · actionMap 42 · bringUp 77 (group 1) · build row 70, defaultOrder group 0 pos 11 |
| upstream pin | commit `329b75e60d04e89616bc1844578098df43d4f432` (master, 2026-08-01) |
| staged media | `/data/assets-staging/bootos/` (`os.img`, `osall.img` = 720K floppy with 19 programs, `os.asm`, `patch/*`, `MANIFEST.sha256`) |
| builder output | `/data/gallery-guests/BootOS/bootos-floppy.qcow2` (pristine, no golden) |
| station dir | `/data/vms/streamhost/stations/bootos/` — `floppy.qcow2` = the ONLY block device, carries the `golden` vmstate |
| device set | `qemu-system-x86_64`, `pc-i440fx-11.0,pcspk-audiodev=snd0`, KVM, `-cpu host`, 64 MB, 1 vCPU, `-vga std`, floppy qcow2 `-boot a`, dbus display + dbus audiodev; **no pointer device** (`SH_INPUT_BACKEND=disabled`) |
| proven so far | cold boot to `$` under KVM in 720x400 text mode; `dir` typed over QMP lists all 19 programs (smoke at `/data/vms/sandbox/bootos/smoke/`) |

## Streams (each: `scripts/dev/wt.sh new <name> --from bootos`, commit on its branch, push)

| Stream | Owns (may touch anything; these are the deliverables) |
|---|---|
| `bootos-build` | `scripts/build-guests/tiles/bootos.sh` (fetch pinned upstream, verify SHA-256, compose the 720K qcow2 floppy, framebuffer-verify boot + `dir`), `check-assets.sh`, `docs/lab/ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md`; RUN the builder so the pristine output exists |
| `bootos-golden` | bake + prove `golden` on a sandbox clone with the exact launcher; prove PC-speaker audio or flip `stream.audio`/`SH_AUDIO` off; measure key pacing; `scripts/coldboot/bootrec-tiles.conf` arm + `bootos-zero-input-prep.md`; registry `runtime`/`reset`/`operator` truth; stage `floppy.qcow2` with the golden into the station dir |
| `bootos-spa` | `registry/posters/bootos.md` + `spa/public/posters/bootos/desktop.webp` (real frames), `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa`/`demoProgram` fields; make the type-in demo actually work (bootOS's `enter` needs an EMPTY line to finish — the validator forbids blank lines today; fix at the root) |
| `bootos-docs` | `docs/guests/bootos.md`, `docs/GUEST-TIERS.md`, release notes (`registry/release-notes/2026-09-06.json`), `docs/README.md` index if needed |

## Reserved to the coordinator

Merging to `main`, `git push origin main`, `scripts/dev/box-deploy.sh --apply`,
`serve-https-spa.sh manifests`, `labctl gen`, starting `streamhost@bootos`, the SPA
build/deploy, and the final framebuffer acceptance.
