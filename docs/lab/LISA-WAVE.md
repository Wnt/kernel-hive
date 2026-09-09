# Apple Lisa (Lisa Office System 3.1) integration wave — 2026-09-09

Operator ask (2026-09-09): add four new stations in parallel on the playbook's
fast path — `sculpt`, `medley`, `domainos` and this one, `lisa`. The Lisa is the
document-centric, pre-Macintosh desktop the lineup lacked between `alto`/`star`
and `macos`. Rule 13: host-native from day one — **LisaEm 2.0.0 as a plain X11
application under a pinned Xvfb**, the daemon capturing the X root
(`SH_CAPTURE=x11`) and driving the pointer and keyboard with XTEST
(`SH_INPUT_BACKEND=x11test`, `SH_X11TEST_ABS=1`). `amix` is the `--like` shape
sibling (x11 runtime, x11 capture, x11test input); its FS-UAE launcher and
guest-X warp are NOT copied — LisaEm follows the host X pointer 1:1, so
absolute XTEST motion is the pointer.

Sibling waves in the same session: `docs/lab/MEDLEY-WAVE.md` (the other
host-native X11 app) and `docs/lab/DOMAINOS-WAVE.md` (MAME). Findings that
apply to them are marked **(cross-wave)** below.

## Ledger — `wave.sh alloc lisa --retronet --x11warp` (session `lisa`)

| Station | Session | Slot / UDP / VMID | X display | retronet (addr / tap / chain / UIN) |
|---|---|---|---|---|
| lisa | lisa | 193 / 54193 / 193 | `:93` (Xvfb, 720x498x24, inside the sandbox) | 10.99.0.41 / `lisarn0` / `LISARN-IN` / UIN 19300 — **reservation only**: a 1984 Lisa has no TCP/IP; web plane and IM are OPEN by definition |

| Fact | Value | Measured by |
|---|---|---|
| Emulator | LisaEm 2.0.0 (2026.01.25), Ray Arachelian, GPL-2.0 — the upstream Linux AppImage, extracted (`--appimage-extract`) and run as `usr/local/bin/lisaem`; UPX-packed, so `ldd` cannot list it (`LD_DEBUG=libs` can) | spine |
| Host libraries | labhost lacks 7 of the 80 objects LisaEm loads: `libgtk-3.so.0 libgdk-3.so.0 libatk-1.0.so.0 libatk-bridge-2.0.so.0 libatspi.so.0 libjpeg.so.8` + the glibc `gconv/UTF-32.so` module. Bundled from CT950's Ubuntu 24.04 packages into `assets/lisa/lib/` and loaded with `LD_LIBRARY_PATH` + `GCONV_PATH`; nothing is installed on labhost **(cross-wave: any GTK/wx emulator meets this)** | spine |
| Boot ROM | Rev H (2/24/84): MAME romset `lisa2.zip` from archive.org item `mame-0.264-roms-non-merged` (file `MAME 0.264 ROMs (non-merged)/lisa2.zip`, 30822 B, sha256 `3f324d5f…bce3034`); `341-0175-h` (high, CRC adfd4516) and `341-0176-h` (low, CRC 546d6603) byte-interleaved high,low into LisaEm's 16384-byte `lisaboot-revH.rom`, sha256 `4eb245a5a133a202cb07757a7430437a996d91acddfba2c1a3b787e8b5b9d8f5`. The archive.org item `apple-lisa-h-1983` is a BAD dump (bit-6 dropouts in ~1300 bytes, wrong checksum bytes) — do not use it | spine |
| System disk | `LisaEM_LOS3.1with7LisaApps.zip` (5131254 B, sha256 `3536d797…563aad`) from archive.org item `apple-lisa-profile-hd-disk-images-for-lisaem-and-idle-lisa-office-system-3.1-lis`: a 10350676-byte DC42 ProFile image with LOS 3.1 and the seven Lisa office tools installed. The install floppies (`los-3.1-en.zip`, 1195960 B, sha256 `7cc3b9e1…8a57f3`, five 419284-byte DC42 images) are staged for provenance and a from-scratch rebuild | spine |
| Media dir | `/data/vms/sandbox/lisa/media/` (MANIFEST.sha256) | spine |
| LisaEm config | `lisaem.conf` written by LisaEm 2.0 on first run in `$HOME`; the station keeps its own: `ROMFILE=`, `[parallelport] parallelport=PROFILE path=`, `MemoryKB=1024`, `cheatromtests=1`, skin off (`-s-`), zoom 1.0, `-o-` (top-left), `-p` power on | spine |
| Lisa video inside the LisaEm frame | 720x498 at (150,26) in the 1020x720 skinless window (LisaEm's aspect-corrected 720x364 — the real Lisa's pixels are 1.5:1); the bottom edge measured by a column scan at row 498 | spine, `xwininfo` + frame crop |
| Root == video | Xvfb `:93` at 720x498. A `gtk.css` in the station's `XDG_CONFIG_HOME` collapses the wx menubar to 2 px; `xdotool windowsize <id> 720 800` puts the video at x=0; `xdotool windowmove -- <id> 0 -42` hides the strip + the 40 px band LisaEm keeps under it. Moving to (-150,-26) instead made GDK drop EVERY button event while motion still worked — only a negative Y is safe. The captured root is exactly the Lisa screen and XTEST root coordinates are Lisa pixels | spine, framebuffer |
| Boot | The Rev H ROM stops at its `STARTUP FROM` menu (floppy / ProFile) while PRAM has no default; a click on the ProFile icon (55,93 in root coords) boots LOS 3.1 to the desktop (Desk / File/Print / Edit / Housekeeping; Preferences, Wastebasket, Clipboard, Disk) | spine, framebuffer |
| Scene tuple | `pizzaBoxB,compactA,keyboardA,paramMouseC` (scaffold accepted) | spine |
| Render orders | signal 83 / stationsManifest 81 / binding 93 / golden 81 / bringUpGroup 8 — as scaffolded (reassign max+1 after merging main) | spine |

## Route race (rule 14) — decided by inspection, no runner needed

- (a) **LisaEm host-native under Xvfb — WON.** GTK stack proven on labhost with the
  bundled libraries; LOS 3.1 desktop on the framebuffer in the spine.
- (b) MAME `lisa2` (the lab's `/usr/games/mame` 0.276 has `lisa`, `lisa2`, `lisa210`)
  — **dead by inspection**: `-listslots`/`-listmedia lisa2` expose two Sony floppy
  drives and no ProFile; Lisa Office System installs and boots only from a
  ProFile, so nothing there can reach the desktop. Not raced.

## Sandbox (the operator's host-application rule, 2026-09-09 — cross-wave)

Mid-wave the `medley` incident produced the rule that a station whose guest
is a host application must run in its own PID/mount/net/user namespace.
LisaEm emulates a machine, but its wx menus and GTK dialogs are host UI a
keyboard accelerator could reach, so it now runs inside `systemd-nspawn`
(`streamhost/stations/lisa/x11-runtime.sh` + `lisa-inner.sh`): read-only
rootfs skeleton `assets/lisa/rootfs` with the host's `/usr`, `/etc/fonts`,
`/etc/ld.so.cache`, `/etc/alternatives` and the asset dir (at its own path)
bound in read-only; `--private-users=200000:65536`; `--private-network`;
capabilities dropped + `--system-call-filter='~@mount'`,
`--no-new-privileges` (the medley flag set); writable only `work/` and
`x11/`; the host symlinks `/tmp/.X11-unix/X93` to the bound-out socket.
Proven from inside on the rig: `uid=0` (host 200000), only `lo`, five
processes, no `/data`, no `/etc/shadow`; from the host: LisaEm as uid 200000
with exe `/data/vms/streamhost/assets/lisa/lisaem/usr/local/bin/lisaem`
(binding the asset dir at its own path is what keeps `/proc/<pid>/exe` and
`SH_IDLE_PAUSE_PROC_MATCH` truthful — the first attempt bound it at `/assets`
and the launcher could not find its own emulator). `--console=pipe` and
`</dev/null` are required or nspawn holds the launching shell.

## Proven in the spine (alone)

- Stack, allocation, media, ROM assembly + hash verification, GTK closure, Xvfb
  rig, LOS 3.1 desktop frame, absolute pointer mapping (the Lisa's own arrow
  tracks the X pointer position 1:1 inside the video rect).

## Streams

No subagents in this wave (fork worker); every stream below ran in the wave
session itself (model: Claude Fable 5.1).

| Stream | Owns | Status |
|---|---|---|
| build | `scripts/build-guests/tiles/lisa.sh` (fetch + hash + extract AppImage, romset, profile; assemble ROM; bundle libs from CT950; rootfs skeleton; stage `assets/lisa/`), `ASSETS-MANIFEST.md`, `os-media-catalog.md` | done |
| golden | launcher + `lisa-inner.sh` + fixture (nspawn), relaunch reset proof on the rig (fresh container, desktop again), pointer framebuffer proofs, staged station dir + golden | done (PRAM default boot OPEN — the launcher clicks) |
| spa | poster, hero (real frame), `keyboardProfiles.ts` OS_FAMILY `classicmac`, museum/spa | done (no demoProgram) |
| docs | `docs/guests/lisa.md`, `GUEST-TIERS.md`, `release-notes/facts/2026-09-13/lisa.md`, `docs/README.md` | done |

## Walls hit

| Wall | Cause | Fix |
|---|---|---|
| LisaEm AppImage dies on labhost: `libgtk-3.so.0: cannot open shared object file` | AppImages assume GTK on the host; labhost (Proxmox, no desktop) has none | bundle the 7 missing objects from CT950 into `assets/lisa/lib`, `LD_LIBRARY_PATH` + `GCONV_PATH` in the launcher **(cross-wave)** |
| `ldd`/`ld.so --list` say "not a dynamic executable" / "no dynamic section" | the AppImage's binary is UPX-packed | `LD_DEBUG=libs lisaem --help` enumerates the closure on a host where it resolves **(cross-wave)** |
| archive.org "Apple Lisa ROMs (Rev. H)" halves carry the item's own SHA-1s but neither MAME's CRCs nor a working checksum | a bad dump (bit 6 stuck low in ~1300 bytes) | the MAME romset halves (CRCs match) interleaved high,low — sha256-identical to the Virtual OS Museum's file |
| A frame-change detector on PNGs "changed" every tick; the "fixed" one then never changed (an hour of double-click theories against windows that had opened) | ImageMagick stamps `date:modify` into every PNG; and `convert f.png rgb:-` writes ALL ZEROS for the 2-bit palette PNGs `xwd` produces, so a pixel hash of that is constant | hash ImageMagick's own pixel signature: `identify -format '%#' f.png` (content-only, format-independent) **(cross-wave: every fb-diff loop)** |
| `xdotool search --name` matched LisaEm's 10x10 helper window; `windowmove` refused `-150` | two toplevels share the name; negative coordinates parse as options | pick the toplevel by width, `xdotool windowmove -- <id> -150 -26` **(cross-wave: any wx/GTK emulator)** |
| Files a rig writes under `labrun` are root-owned and unwritable from CT950 | root umask (fixed by `umask 022`) but ownership stays root | write rig configs FROM the labhost-side script, not from CT950 |
| Double-clicks "stopped working" in the sandboxed LisaEm | they never stopped: the blind detector above; LOS takes 20-60 s at 5 MHz to draw a window after a double-click | wait for a signature change up to 60 s; two 70 ms presses 70 ms apart open icons (`xdotool mousedown 1 sleep 0.07 mouseup 1 sleep 0.07 mousedown 1 sleep 0.07 mouseup 1`) |

## OPEN

- Retronet web plane + IM: no TCP/IP exists for a 1984 Lisa. The reservation
  10.99.0.41 stays as the ledger entry.
- Keyboard typing proof in a LisaWrite document (XTEST keys reach LisaEm — the
  daemon resolved 103 scancodes on the sandboxed display — but no typed line
  was framebuffer-proven). Next: on the live station under a wake lease,
  Disk → Lisa Write → double-click "LisaWrite Paper" → double-click the torn
  sheet → `labctl type`, waiting for a signature change (up to 60 s) after
  each double-click.
- PRAM default boot device (LOS Preferences → Select Defaults → "Start Up
  From: Profile", then a clean power-off so LisaEm writes `[pram]`); until
  then `lisa-inner.sh` clicks the ProFile icon 4 s after launch.
- A type-in demo (needs the document above); audio (`SH_AUDIO=off`).

## Landing

`scripts/dev/station-land.sh lisa` (no `--golden`: the golden ProFile image
was staged into `stations/lisa/disk/` by the spine), run detached with its log
polled. First attempt stopped at step 2 (merge conflict with origin/main after
the `medley` and `sculpt` landings: the six generated/scene files). Resolved
by the recipe — `--theirs` for the generated files and the two scene tables,
`spa-scene-rows.py lisa --like amix --tuple … --apply`, render orders max+1
(bringUp/binding 93→95, signal 83→84, manifest/golden 81→82, build 79→80),
then `spa-scene-rows.py` AGAIN because the order bump moved lisa's lineup
index (92→94) after the rows had been written — validate names exactly that.
Second attempt: window taken at once, gate green (eslint+knip, vitest,
shfmt+shellcheck on 4 files, size budget, generated drift, box state), main
`d0a8905e` pushed 19:40:50Z, `box-deploy --apply` (`.deployed-rev` 19:42Z),
smoke rig withdrawn, `station-up` (unit active, boot click 19:46:32Z),
10 claims re-homed to session `lisa`, SPA built and deployed, window
released. `== LANDED lisa`.

## Proofs (rule 9)

- Spine: LOS 3.1 desktop on the framebuffer (`smoke/frames/c050.png`,
  18:48Z); the Lisa's arrow at the X pointer's position (absolute mapping).
- Launcher, unsandboxed: desktop after its own boot click (`rig/l2.png`).
- Launcher, sandboxed: `rig/n1.png` desktop; from inside the container `id`
  = uid 0 (host 200000), only `lo`, five processes, no `/data`, no
  `/etc/shadow`; from the host LisaEm as uid 200000 with its exe under
  `assets/lisa/lisaem/`.
- Clicks: ROM `STARTUP FROM` icon, Preferences icon + its check boxes, the
  Disk icon (window with the seven tool folders), all on the sandboxed rig.
- Landed station: `labctl shot lisa` = the ROM boot in progress seconds after
  station-up (`lisa-landed.png`), the desktop afterwards (`live-desk.png`).
- **Reset:** `labctl reset lisa` → new nspawn + LisaEm pids (uid 200000) →
  the desktop signature identical to the pre-reset one after 145 s
  (`live-reset.png`).

## Measured timeline (git + box mtimes; the fork's own transcript is inside the coordinator's)

| Milestone | Clock (UTC) | Minutes from `wave.sh alloc` |
|---|---|---|
| `wave.sh alloc lisa` | 18:14 | 0 |
| ROM assembled + hash-verified (after the bad-dump detour) | 18:34 | 20 |
| LOS 3.1 desktop on the framebuffer (Xvfb rig, GTK closure bundled) | 18:48 | 34 |
| Sandboxed launcher end-to-end (desktop, `rig/n1.png`) | 19:21 | 67 |
| `/os/lisa` viewable (smoke rig, x11test) | 19:22 | 68 |
| Branch pushed (`f1e42f9a`) | 19:34 | 80 |
| main pushed (`d0a8905e`) / box deployed | 19:40 / 19:42 | 86 / 88 |
| station-up boot click / landed | 19:46 / 19:48 | 92 / 94 |
| reset proof on the live station | 19:53 | 99 |

Where it went: the operator's mid-wave sandbox rule (≈25 min: nspawn shape,
the `/assets` vs host-path pid trap, `--console=pipe`), and ≈40 min lost to a
frame detector that hashed zeros — the two wall rows above.

## Teardown (rule 8)

- Smoke rig withdrawn by `station-land` (`smoke-rig.sh --down`); its nspawn
  container, Xvfb and the placeholder-QMP python killed by pidfile before the
  landing; the host `/tmp/.X11-unix/X93` link now points at the station's own
  `stations/lisa/x11/X93`.
- Check: a `/proc/*/exe` sweep for `assets/lisa` finds exactly the station's
  LisaEm (uid 200000) beside its nspawn; `kh-claim ls` shows every lisa claim
  (slot/port/vmid/display/6093/rnip/tap/chain/uin/sandbox) held by session
  `lisa`, the station session.
- Kept as provenance: `/data/vms/sandbox/lisa/{media,smoke,rig}` (media +
  MANIFEST.sha256, the proof frames); no stream sandboxes were created
  (single-session wave).
