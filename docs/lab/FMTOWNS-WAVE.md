# fmtowns wave — Fujitsu FM TOWNS, Towns OS V2.1 L51 (TownsMENU)

Part of the five-station wave of 2026-09-13 (`vision`, `oberon`, `fmtowns`,
`magiccap`, `perq`). This is the FM TOWNS: Fujitsu's 1989 CD-ROM-first 386
home computer, whose operating system boots from the System Software CD into
**TownsMENU**, an icon desktop over an MS-DOS kernel. The fact that the
Virtual OS Museum runs this OS (on Tsugaru) is credited as a fact; nothing of
theirs is copied.

Read `docs/guests/fmtowns.md` for the station's operating manual once it is
filled; this file carries the wave: the ledger, the race, the sandbox verdict
and what is still open.

## Ledger — `wave.sh alloc fmtowns --x11warp` (no `--retronet`: Towns OS V2.1 has no TCP/IP stack by default, so a tap NIC would be meaningless)

| Station | Session | Slot / UDP / VMID | X-warp | retronet (addr / tap / chain / UIN) |
|---|---|---|---|---|
| fmtowns | fmtowns | 196 / 54196 / 196 | :96 (127.0.0.1:6096) | — |

| Field | Value |
|---|---|
| sibling (`--like`) | `samcoupe` (MAME host-native, 0.289, save-state golden), tuple `towerE,crtC,keyboardE,paramMouseC` |
| render orders | as scaffolded (build 82 / signal 86 / stationsManifest 84 / binding 97 / golden 84 / bringUp 97) |
| uid base (if the Tsugaru route had won) | 2228224 — unused, see §Sandbox |
| media | see §Media |

## The race (rule 14) — two theories from minute 0, first TownsMENU frame wins

| Theory | Runner | Sandbox | Result | Frame |
|---|---|---|---|---|
| A. MAME `fmtowns` family, host-native (fleet tier) | sonnet | `/data/vms/sandbox/fmtowns/race/mame/` | **WON** — `fmtownsftv` boots the Towns System Software V2.1 L51 CD straight into a fully-rendered, settled TownsMENU desktop, ~80s wall-clock | `race/mame/frames/t90.png` |
| B. Tsugaru_CUI inside systemd-nspawn (uid base 2228224) | sonnet | `/data/vms/sandbox/fmtowns/race/tsugaru/` | not pursued once A won — reference only. Tsugaru_CUI needed a Linux build from source (no prebuilt binary for this arch/distro), an nspawn container per the sandbox contract, and a from-scratch X11/framebuffer capture path; none of that is proven, so this row records the theory's shape, not a result | — |

**finisher (this stream, sonnet, 2026-09-13)**: turned the race into the shipped
artifact — real fleet build (not the race sandbox's ad-hoc invocation), real
CHD compose via chdman, real keymap generated from KEYDUMP, keyboard proof via
the real ctlsock KEY path, golden bake + restore proof. See §Proofs.

## Media — staged by the `fmtowns-media` agent on labhost (`/data/assets-staging/fmtowns/`), re-hashed by the lead

Fetched from archive.org origins; the bits stay under `/data` (the gallery is
private), the repo carries only URL + sha256 + size in
`scripts/build-guests/tiles/fmtowns.sh`. MEASURED 2026-09-13 (`sha256sum`,
`sha1sum`, `stat -c %s` on labhost):

| File | Bytes | sha256 | sha1 (MAME member match) |
|---|---|---|---|
| `roms/fmtowns.7z` — MAME 0.272 merged romset `mess/fmtowns.7z` (item `mame-0.272-romset-complete-merged`), 20 members incl. every regional variant + the 32-byte `mytowns*.rom` boot-select ROMs | 967 043 | `5856826e…5081ac` | — |
| `FMT_SYS.ROM` | 262 144 | `7d4e8935…7b9a` | `15d9cc70…` = base `fmtowns` (Model 1/2) `fmt_sys.rom` |
| `FMT_DOS.ROM` | 524 288 | `b760d991…f17f` | `57fd1464…` = every set's `fmt_dos.rom` |
| `FMT_F20.ROM` | 524 288 | `dca1f314…b774` | `1920711c…` = Towns II `fmt_f20.rom` |
| `FMT_DIC.ROM` | 524 288 | `fdec9c3b…cdc7` | `7564020d…` = Towns II `fmt_dic.rom` |
| `FMT_FNT.ROM` | 262 144 | `aa9e9565…b9d` | `a216482e…` = Towns II `fmt_fnt.rom` |
| `cd/towns-sysv21-l51-cd.7z` — "[OS] Towns System Software v2.1 L51 [CD].7z" from item `neo_kobe_fujitsu_fm_towns_2016-02-25-repack_20200803` | 252 788 766 | `43db0465…0648b85` | — |
| `cd/towns-sysv21-l51-cd.img` (CloneCD; 1× MODE1/2352 data track + 8 audio tracks; `.ccd`/`.sub` alongside) | 593 767 104 | `5adbae1b…50f8ab` | — |
| `optional/` MS-DOS 6.2 L10 FD sets, Towns OS V1.1 L20 **English** FD + HD sets | 0.5–2.7 MB each | in `SOURCES.md` | not used by this wave |

The five uppercase files are the set the Virtual OS Museum boots on Tsugaru;
by hash they straddle two MAME machines (SYS is the Model 1/2 ROM, the rest are
Towns II), which is why the rompath is assembled by `stage-romset.py` from the
extracted merged archive rather than from the five files.

## Sandbox verdict

**Emulated machine under the fleet MAME (host-native template).** The visitor's
reach ends at the emulated FM Towns hardware — no nspawn audit is needed (per
WAVE-COMMON's tier table). Launcher line (real fleet build, real CHD, from the
shared `stations/mame-native/x11-runtime.sh`):

```
MAME_SHM_PATH=$BASE/fb.shm MAME_SHM_SIZE=1024x768 MAME_CTL_SOCK=$BASE/ctl.sock MAME_NO_UI=1 SDL_VIDEODRIVER=dummy \
/data/vms/streamhost/assets/fmtowns/mame-native/fmtowns fmtownsftv \
  -rompath /data/vms/streamhost/assets/fmtowns/mame-native/roms \
  -inipath $BASE -homepath $BASE -cfg_directory $BASE/cfg -nvram_directory $BASE/nvram \
  -video shm -nofilter -sound none -skip_gameinfo -throttle -frameskip 0 -noautoframeskip \
  -state_directory $BASE/sta -state golden \
  -pad1 townspad -pad2 mouse -cdrom /data/vms/streamhost/assets/fmtowns/media/townsos-v21l51.chd
```

No `-netdev`, no 9p/virtfs/`fat:` host directory, no monitor/QMP socket reachable
from the guest, no `-device virtio-serial`. Only `-cdrom` (a CHD, read-only image)
and `-pad1`/`-pad2` (emulated peripherals) touch the device set beyond the fleet
defaults.

## Proofs

All frames measured 2026-09-13, real fleet binary (`sha256
4bb3755496523d016d035b2afe8f4ed55ca2285d083428c05165c9fe7f580d46`) + real CHD
(`sha256 fde4fa2bc8ede2d260e9baf0dc7e832b0682222fa04fc480dace923445a00c4d`, 210
349 963 bytes), on `/data/vms/sandbox/fmtowns/golden2/` then the real station
dir `/data/vms/streamhost/stations/fmtowns/`.

| Proof | Shows | Path |
|---|---|---|
| Race frame (theory A win) | TownsMENU desktop, drive-select window, Q:TOWNSSYSTEM folder | `race/mame/frames/t90.png` |
| Real build boot gate | 50291 lit pixels on the published 1024x768 surface (floor 25000) | `race/mame/build-real.log` |
| Cold boot, early | `TownsOS V2.1 L51` boot banner | `golden/run/settled.png` |
| Cold boot, mid | loading clock icon | `golden2/run/s3-settled.png` |
| Cold boot → settled desktop (untouched, no keys sent) | TownsMENU desktop reached from a clean cold boot | `golden2/run/s5.png` — **this is the golden savestate's pixel source** |
| Keyboard proof: before | the settled desktop, no dialog | `golden/run/desktop-settled.png` |
| Keyboard proof: Ctrl+Esc pressed (ctlsock `KEY` verbs on `:key3 Ctrl` + `:key1 ESC`, real generated keymap fields) | the guest's own タスクリスト (Task List) dialog opens, showing `TownsMENU V2.1L51` and its buttons (サイドワーク/強制終了/選択/取消) | `golden/run/after-ctrlesc.png` |
| Keyboard proof: Ctrl+Esc pressed again | a DIFFERENT dialog (サイドワークリスト — Control Panel / Calculator / CD Player / Schedule / etc.), proving the guest is genuinely reading each keypress, not replaying a cached frame | `golden/run/back-to-desktop.png` |
| SAVEST at the settled desktop | `334ms ack, bytes=797714`, written to `sta/fmtownsftv/golden.sta` | `golden2/sta/fmtownsftv/golden.sta`, installed at `/data/vms/streamhost/stations/fmtowns/sta/fmtownsftv/golden.sta` |
| Restore proof: a FRESH process launched with `-state golden` against the REAL station dir | settled in 5.2s (includes CD mount); `PIL.ImageChops.difference` bbox against the golden capture frame is `(767, 60, 768, 69)` — a 1×9 px sliver at the on-screen clock glyph (real wall-clock time reads through to the guest's RTC), otherwise pixel-identical | `golden2/run/restored.png` vs `golden2/run/s5.png` |
| Hero / poster image | the settled TownsMENU desktop, converted to webp | `spa/public/posters/fmtowns/desktop.webp` (source `golden2/run/s5.png`) |

## Still open

1. **Pointer** — the Towns mouse is on `-pad2 mouse` (driver default). `KEYDUMP`
   over the real ctlsock shows the port as `:pad2:mouse:MOUSE_X` /
   `:pad2:mouse:MOUSE_Y` (relative axis fields) and `:pad2:mouse:BUTTONS` — no
   absolute-position port exists on this device (an MSX-protocol mouse is
   inherently relative). `MOVEA`+`CLICK1` through the generic ctlsock open-loop
   path produced NO observable cursor movement on the framebuffer in ~10 minutes
   of testing (matches domainos's wall 6 exactly: "the pointer never leaves
   compatibility mode"). Registry `stream.pointer.transport` stays `none`
   (ship keyboard-only, exactly the domainos precedent) — this is a DELIBERATE
   decision pending the pointer proof, not an oversight.
   **Exact next step:** trace what `pad2:mouse` actually needs (relative deltas
   fed continuously, not an absolute MOVEA target — likely a `MOVE`/`MOVEP`
   verb with small relative steps timed to the guest's own poll rate; read
   `src/mame/fujitsu/fmtowns.cpp`'s mouse port handler first) on a throwaway
   clone, never the live station.
2. **`/os/fmtowns` publish** — `scripts/dev/smoke-rig.sh` is QMP-shaped (it
   expects a QEMU guest's `-display dbus,p2p=on` + `qmp.sock`, and a released
   daemon binary at `/usr/local/lib/streamhost/stations/<like>/current` whose
   `--like` stream.env it rewrites); it has no `SH_CAPTURE=shm`/ctlsock path,
   so it does not fit a MAME-native rig directly (same gap `station-up.sh` has:
   it requires the branch already landed on labhost's main checkout).
   **Exact next step:** either (a) land this branch via `station-land.sh` and
   run `scripts/dev/station-up.sh fmtowns` from the deployed main checkout (the
   normal path every prior MAME-native station used, per this wave's siblings'
   docs), or (b) if a pre-land dark-launch preview is wanted, extend
   `smoke-rig.sh` with an `SH_CAPTURE=shm` branch — that is a shared-tool
   change out of this stream's scope, flag it to the coordinator rather than
   hand-rolling it in this station's own tree.
3. **Command Mode / MS-DOS prompt, TownsGEAR and the other TOWNSSYSTEM icons**
   — not opened (no proven pointer, and no keyboard-only launch path found for
   icons; `Ctrl+Esc`'s Task List / Sidework dialogs are the only reachable
   non-desktop screens without a pointer). OPEN for a future stream once
   pointer lands.

## Teardown

- `golden` rig (`/data/vms/sandbox/fmtowns/golden/run/mame.pid`, pid 2691902) —
  killed via `/proc/<pid>/exe` match against the real fleet binary, then
  SIGKILL-verified dead (0.28s `SIGTERM`→exit path).
- `golden2` rig (`/data/vms/sandbox/fmtowns/golden2/run/mame.pid`, pid 2746459)
  — same kill path, dead before the golden.sta was copied out of it.
- The real station-dir process (pid 2772770, launched to prove the
  `-state golden` restore against the real `/data/vms/streamhost/stations/fmtowns`
  paths) — killed the same way (`/proc/<pid>/exe` match against the real fleet
  binary, SIGTERM then confirmed dead), after the restore frame was already
  captured. `/data/vms/streamhost/stations/fmtowns/{ctl.sock,fb.shm}` are now
  stale files from a dead process (no daemon manages this station yet); the
  next real launch (via `station-up.sh` after landing) removes and recreates
  them itself, same as any other station's `reap_previous`.
- Race sandboxes (`/data/vms/sandbox/fmtowns/race/{mame,tsugaru}/`) left on
  disk as provenance, per brief; the race's own MAME instance (pid 2545230)
  was already gone (no `/proc/2545230`) by the time this stream started —
  no action needed there.
