# Amiga 1000 integration wave — 2026-09-09

Operator ask (2026-09-09): "Add the two Amigas" from the home-computer study
(`docs/lab/research/home-computer-candidates.md` §4.4: A1000 first, then the
big-box). This brief is the Amiga 1000's; `A3000-WAVE.md` is its sibling wave,
run in the same session. Rule 13: host-native on the FS-UAE path from day one —
`amigaos35` is the shape sibling (`stations-registry.py new a1000 --like amigaos35`),
its x11-runtime launcher, Xvfb capture and XTEST input are copied, its retronet
cage is not (a 1986 guest has no web plane). The study's exhibit is the
Kickstart-from-floppy boot; see Walls for where that stands.

## Ledger (allocated by `wave.sh alloc a1000`, session `a1000`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet |
|---|---|---|---|---|
| a1000 | a1000 | 188 / 54188 / 188 | — (FS-UAE mousehack + XTEST abs, as amigaos35) | — (pre-web guest) |

| Fact | Value | Measured by |
|---|---|---|
| Xvfb display | `:88` (kh-claim `display/88`, session a1000); race runners used `:86` `:87` | spine |
| Scene tuple | `pizzaBoxB,crtC,keyboardA,paramMouseA` (scaffold refused the sibling's) | spine |
| Emulator | FS-UAE 3.2.35, pinned source build with the lab mousehack patch (`build-fsuae-native.sh`, `FSUAE_STATION=a1000` → `assets/a1000/fsuae-native/`, the station's OWN copy) | spine; smoke used amigaos35's binary |
| Model | `--amiga_model=A1000` (OCS, 68000, 512 KB chip; FS-UAE model → `chipset_compatible A1000`, `cs_a1000ram`) | spine from src/fs-uae/config-model.c |
| Window / X screen | 720x568 (`xwininfo`, same as amigaos35; PAL 640x256 desktop inside) | spine, measured on the smoke rig |
| Device set (shipped) | Kickstart 1.2 r33.180 image in the ROM slot, DF0 = Workbench 1.2 (writable work copy), DF1 = Extras 1.2 (work copy); no HDF, no statefile, no network | spine |
| Boot | ~55 s to the Workbench 1.2 desktop (frame `smoke-t1/frames/f055.png`, 2026-09-09) | spine |
| Media | `/data/vms/sandbox/a1000/media/` (MANIFEST.sha256; archive.org items `commodore-amiga-firmware` and `commodore-amiga-operating-systems-workbench`, TOSEC zips unpacked) — table below | spine |

| File | Bytes | sha256 |
|---|---|---|
| `Amiga 1000 ROM Bootstrap (1985)(Commodore)(A1000)[!].rom` | 65536 | `c67d47d0ff4a4cd29104e96fe7920a2ec13dff4f7f0fbcf7be645e2ae493262c` |
| `Kickstart v1.2 r33.180 (1986-10)(Commodore)(A500-A1000-A2000)[!].rom` | 262144 | `87cddb1f499e32758de20145e73031a84bab299e3f6e5c8487e76d02b2ee9d16` |
| `Kickstart v1.2 r33.166 (1986-09)(Commodore)(A1000)[!].rom` | 262144 | `86a0de3a6e390fe0804e8d8e3d39091552f3f5020d8bd4989a77bb996bbc50b7` |
| `Workbench v1.2 rev 33.56 (1987)(Commodore)(A500)(Disk 1 of 2)(Workbench).adf` | 901120 | `4dfd92a4589346f157593d1a3098966b43e2298c46b749c689b9dc457480be4c` |
| `Workbench v1.2 rev 33.56 (1987)(Commodore)(A500)(GB)(Disk 2 of 2)(Extras).adf` | 901120 | `7edba9fcbffacde7f1bf94920b76c57e2002ae07b877f26de152ae96c631ba69` |

## Proven in the spine (coordinator, alone)

- Both Amiga stacks, allocations, media and displays in the first 10 minutes;
  `/os/a1000` published from the smoke rig (`smoke-rig.sh` with a placeholder
  QMP socket + a hand-patched `stream.env`: display `:86`, `x11test` input —
  the tool assumes a QEMU sibling, see Tooling).
- The A1000 model boots Workbench 1.2 from DF0 with the 256 KB Kickstart 1.2
  image in the ROM slot: desktop at 55 s, framebuffer proof above.
- The authentic bootstrap route does NOT boot in this build (Walls).

## Streams

| Stream | Branch | Owns | Model |
|---|---|---|---|
| build | `a1000-build` | `scripts/build-guests/tiles/a1000.sh` (fetch + sha256 + stage the floppy set and ROMs into `assets/a1000/` and the station `disk/`), `FSUAE_STATION=a1000 build-fsuae-native.sh` run so `assets/a1000/fsuae-native/bin/fs-uae` exists, `check-assets.sh`, `ASSETS-MANIFEST.md`, `os-media-catalog.md` rows | sonnet-low |
| golden | `a1000-golden` | cold-boot proof with the station launcher on a sandbox clone, XTEST pointer + keyboard proof on the framebuffer, measured boot time, registry `reset` truth, fixture pacing if 40/40 drops characters, staged station dir under `/data/vms/streamhost/stations/a1000/` | sonnet |
| spa | `a1000-spa` | `registry/posters/a1000.md`, hero + frames, `museum`/`spa`/`demoProgram`, `keyboardProfiles.ts`, `machineIdentity.ts` tints — the only stream that edits visitor-facing prose | opus |
| docs (after golden) | `a1000-docs` | `docs/guests/a1000.md` incl. §Checkpoint, `GUEST-TIERS.md`, release notes, `docs/README.md` | sonnet-low |
| bootstrap race | (no branch; findings in `/data/vms/sandbox/a1000/smoke/BOOTSTRAP-FINDINGS.md`) | the Kickstart-from-floppy route, 25-minute stop | opus |

One owner per file; facts flow one way (the stream that measures corrects this ledger).

## Walls hit

**Kickstart-from-floppy bootstrap loops (spine, 2026-09-09).** `kickstart_file`
= the 64 KB A1000 bootstrap ROM (crc32 `0b1ad2d0`, UAE's own known-good
dump) + the raw 262144-byte Kickstart 1.2 image in DF0 (UAE synthesizes the
Kickstart disk: `disk.cpp` ADF_KICK) + Workbench in DF1: the framebuffer stays
flat grey; `fs-uae.log` shows a reset loop (206 `PAL mode` lines, the
`00F80000 512K Kickstart ROM (…)` checksum alternating `B5F86782`/`B54EB5E2`).
The 8 KB bootstrap image behaves the same. Raced per rule 14: the full-ROM
route won at 55 s and ships; the bootstrap route is an OPEN item handed to a
discovery runner (theories: forced `uae_a1000ram`/`chipset_compatible`, the
hard-reset path reinstalling the bootstrap, a proper 880 K Kickstart .adf,
DF0/DF1 order). The launcher already carries the switch
(`FSUAE_NATIVE_A1000_BOOTSTRAP=1`); relaunch-mode reset means proving it later
is a launcher change, not a re-bake.

## Tooling debt found by this wave

- `stations-registry.py new --like` assumed a QEMU sibling (`qemu-streamhost.sh`);
  fixed in this wave to take the launcher named by `runtime.x11.launcher`, to
  rewrite `<sib>_cmd` (SH_X11_CMD_FILE) and the `--tile`/`--udp` values in
  `runtime.x11.emitArgs`. The display stays the sibling's on purpose.
- `smoke-rig.sh` requires a QMP socket and drops `SH_X11TEST_*`, so an x11
  rig needs a placeholder socket and a hand-patched `stream.env`.
- `labrun` runs as root with umask 077: files a rig writes on labhost are
  unreadable from CT950 unless the script sets `umask 022`.
- `/data/assets-staging` is root-owned inside CT950 and a different mount on
  labhost; this wave staged media under `/data/vms/sandbox/<id>/media/` instead.

## Timeline (measured: transcript ask timestamp + git/box mtimes)

| Milestone | Clock (UTC) | Minutes from the ask |
|---|---|---|
| Operator ask ("Add the two Amigas") | 14:56 | 0 |
| Both stacks (`wt.sh new`), both `wave.sh alloc`, media staged + hashed | 15:03 | 7 |
| A1000 smoke boot proven (Workbench 1.2 desktop, full-ROM race runner) | 15:10 | 14 |
| `/os/a1000` viewable (smoke rig) | 15:12 | 16 |
| Ledger pushed (`a1000`) | 15:16 | 20 |
| Five streams launched (a1000 build/golden/spa, a3000 build/spa) | 15:18 | 22 |
| a1000 main push | 15:39 | 43 |
| **a1000 landed live** (`/os/a1000`, unit active, framebuffer shows Workbench 1.2) | 15:41 | **45** |

Where the 45 minutes went: 16 to viewable (about 5 of them were self-inflicted:
the root-owned staging mount, a `cd` that failed and hashed the shared clone, a
frame loop with broken quoting), 4 to the ledger, 20 in the streams (the FS-UAE
build stream lost 10 minutes to labhost's missing `zip`), and 5 across four
landing attempts: a unit test I ran in the landing worktree leaked a temporary
station into the tree; the a1000 tile had no keyboard-profile family
(`spa/src/ui/keyboard/keyboardProfiles.ts` OS_FAMILY — the spa stream looked
under `spa/src/data/`); the scaffold had copied the sibling's
`operator.labctl.udp_port`. Every one of those is now either fixed in the tool
or written in the wall table below.

## Walls hit at landing (2026-09-09)

| Wall | Cause | Fix |
|---|---|---|
| `station-up` red: `labctl: declared/live mismatch a1000.udp_port` | scaffold copied `operator.labctl.udp_port` from the sibling | scaffold now rewrites it; check the field on any pre-fix scaffold |
| vitest `tileWiring` + `keyboardProfiles`: no keyboard family for the tile | the family map lives in `spa/src/ui/keyboard/keyboardProfiles.ts` (OS_FAMILY), not under `spa/src/data/` | add `<id>: 'amiga'` next to amigaos35's |
| a validate error shipped in a commit | `validate 2>&1 \| tail -1 && …` masks the exit code | run it to a file and test `$?`; never pipe a gate |
| `build-fsuae-native.sh` exits silently after the patches | `configure` needs `zip`; labhost has none; the script did not check configure's exit | run the build in CT950; the script now checks and says so |
| golden's pointer probe: an instant `xdotool click` never selects | FS-UAE's mousehack samples per frame; press+release inside one frame is lost | 150 ms hold, 150–200 ms between the two clicks of a double-click |

## Converted to host-native (no X) — 2026-09-09

a1000 moved off the pinned-Xvfb/x11test plane onto the shared FS-UAE
host-native launcher (`streamhost/stations/fsuae-native/x11-runtime.sh`, rule
13, `docs/lab/FSUAE-NATIVE-BRIEF.md`): `SH_CAPTURE=shm` 640x512,
`SH_INPUT_BACKEND=mamesock` against `FSUAE_NATIVE_CTL_SOCK` with
`amiga.keymap`, `SH_AUDIO_SOURCE=fifo`, `SH_BTN_MIN_HOLD_MS=150`. Pointer
proof is exact through the real daemon on the shared plane (an A3000 rig):
MOVEA 41,148 landed the tip at 38,148, double-click opened the System
window. Daemon lines proving the plane is live: `[shmcap] geometry 640x480
-> 640x512`, `[mamesock] connected, HELLO verified`, `[audio] fifo open`.
Xvfb `:88` is released and unused; `runtime.x11.display` stays as inert
registry bookkeeping.

Walls specific to the conversion (on top of the table above):

| Wall | Cause | Fix |
|---|---|---|
| validate-pipe mask | a validate error shipped in a commit because a piped `validate 2>&1 \| tail -1 && …` swallowed the exit code | run to a file, test `$?`, never pipe a gate |
| missing `zip` | `configure` on the fork needs `zip`; labhost has none | bootstrap on labhost (autotools, no zip), configure/make in CT950 (zip, no autotools) |
| autotools split | the reverse of the above — CT950 has zip but not autotools | same two-host split as the wall above; the builder does both legs |
| `--mouse_integration=1` missing | mousehack never registers a click without it | mandatory flag on the launch line, not optional |
| first build ignored SIGTERM | the shm binary didn't handle clean shutdown | fixed on the fork: clean SIGTERM quit in ~55 ms |
| smoke rig / station Xvfb collision | a smoke rig's own Xvfb held the display an x11 station reused | moot once the station is on the no-X plane — no display to collide on |
| station-up shot fired before the mapping existed | a proof screenshot was taken before `amiga.keymap` landed | sequence the keymap commit before the bring-up proof step |
