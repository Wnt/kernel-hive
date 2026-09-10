# `indyr4400` de-bridging — the allocation ledger

**One commit, written first, so streams A/C/D never guess a shared value.**
Companion to [`IRIS-DEBRIDGE-BRIEF.md`](IRIS-DEBRIDGE-BRIEF.md) (the design) —
this file is only the numbers, the paths and the env names the four streams
must agree on. Owned by stream B; change it by editing this table, never by
inventing a second one somewhere else.

`indyr4400` is an **existing live station** and keeps its identity: same
registry id, same `stationDir`, same slot, same archetype, same poster.

## Shared values

| Value | Setting | Claimed | Changes at cutover? |
|---|---|---|---|
| slot | **136** | held by the live station | no |
| UDP port | **54136** | held by the live station | no |
| VMID label | 239 | — | **retired** — `runtime.vmidLabel` is dropped; there is no QEMU |
| ssh / exec port | 5839 | — | **retired** — the Debian kiosk it forwarded to is gone |
| `SH_X11_DISPLAY` | **`:94`** | `kh-claim display :94` (session `iris-b`) | REAL while `SH_CAPTURE=x11` (the interim Xvfb-in-container proof); **inert** once the fork's shm publisher ships, but the registry validator requires the key regardless |
| container uid base | **2031616** (31 × 2^16) | `kh-claim uidbase 2031616` | permanent. `medley` = 1966080, `lisa` = 200000; must be a multiple of 65536 and clear of CT 950/951's subuid range (100000+) |
| retronet ip / tap / UIN | none | — | **out of scope** (brief §5 Q3): a conversion that also changes the network is two changes sharing one rollback |
| audio | off | — | **out of scope** (brief §5 Q4) |

## Paths

Station base `$BASE = /data/vms/streamhost/stations/indyr4400`,
assets `$ASSETS = /data/vms/streamhost/assets/indyr4400`.

| Path | Who writes it | Notes |
|---|---|---|
| `$ASSETS/iris` | `scripts/build-guests/tiles/indyr4400.sh` | the emulator binary **at its host path**, bound read-only into the container so `/proc/<pid>/exe` and `SH_IDLE_PAUSE_PROC_MATCH=assets/indyr4400/iris` read the same from the host (`lisa.md` §Sandbox) |
| `$ASSETS/rootfs` | same | the nspawn skeleton (mount points + symlinks; the host's `/usr` is bound in read-only at launch — the `lisa` shape, not a debootstrap) |
| `/data/gallery-guests/IrisIndy/irix65-r4400-disk.raw` | `streamhost/stations/indyr4400/fetch-assets.sh` | the 6 291 456 000-byte IRIX 6.5.22 disk, **a plain immutable file**, bound read-only. The bridge era's ext4 wrapper existed only so a QEMU guest could mount it; host-native, Iris opens the file directly and the wrapper is retired |
| `$BASE/run/fb.shm` | the emulator (`IRIS_SHM_PATH`) | **moved out of `$BASE` 2026-09-10.** The publisher creates the mapping by temp-file-and-rename, which needs a writable DIRECTORY; `$BASE` is never bound into the container (cert hash, `signaling.json`). `run/` already is, so the mapping joins the sockets there. Declared as `runtime.x11.shmPath`; the launcher does NOT pre-create it |
| `$BASE/run/ctl.sock` | the emulator (`IRIS_CTL_SOCK`) | `mamectl/1`. `$BASE/run` is a bound directory, not `$BASE` itself — the station dir holds `station.env`, `signaling.json` and the cert hash and is never exposed to the payload |
| `$BASE/run/iris-ci.sock` | nobody, as shipped | Iris's own JSON-lines exec channel. **`IRIS_CI_SOCK` is EMPTY on the station**: measured 2026-09-10, arming it publishes no frame at all (~200 % CPU, ten minutes, nothing) — the ci SCC backend travels with the socket, not with `--ci`. The reset verbs never rode it; they are on `ctl.sock` |
| `$BASE/work` | the launcher, wiped every launch | `iris.toml`, `nvram.bin`, the disk COW overlay, logs. `/work/saves` is a SYMLINK to `/state` |
| `$BASE/state` | the emulator (`SAVEST`), **never wiped** | the checkpoints and the shared CAS chunk store. Bound at `/state`. It exists because `saves/<name>` resolves against the process CWD (`/work`) and `work/` is wiped on every launch — a golden written there would be deleted by the next relaunch, i.e. by the thing meant to restore it |
| `$BASE/x11` | interim only | the container's Xvfb socket dir; the host gets `/tmp/.X11-unix/X94 -> $BASE/x11/X94` |
| `$BASE/indy.keymap` | **stream C** | `SH_MAMESOCK_KEYMAP`, the `nextstep.keymap` shape |
| `$BASE/mame.pid` | the launcher | the emulator's HOST pid — the daemon's freezer and the reap-by-exe path |
| `$BASE/nspawn.pid` / `$BASE/xvfb.pid` | the launcher | the supervisor; the interim Xvfb |
| `$BASE/indyr4400_cmd` | nobody | `SH_X11_CMD_FILE`: required by the validator, read by nothing |

## Emulator env knobs (the fork's contract with the launcher)

Streams A, C and D implement these names; stream B's launcher is the only
thing that sets them. **Unset knob = loud failure, never a fallback.**

| Knob | Set by | Meaning |
|---|---|---|
| `IRIS_BIN` | fixture | the binary the launcher execs |
| `IRIS_SHM_PATH` | launcher (shm mode only) | IFB1 mapping; its presence on the no-window branch is what installs the `Renderer` (stream A). The binary must be run with **`--no-window`, never `--ci`** — measured 2026-09-10: under `--ci` the Indy ran twelve minutes at 107 % CPU with `screen.width == 0`, so `present()` is never called and nothing is ever published |
| `IRIS_CTL_SOCK` | launcher | the `mamectl/1` listener (stream C) |
| `IRIS_CI_SOCK` | launcher | Iris's own JSON-lines ci socket (`--ci-socket`). The fork now gates `ci::start_server` on the SOCKET rather than the mode, so `--ci`'s COW-overlay redirect and serial swap are no longer implied — but **the frame plane still dies when the socket is armed** (measured 2026-09-10: ten minutes, ~200 % CPU, no frame; empty → first frame in 19 s). Ships EMPTY. No `:-` default anywhere |
| `IRIS_SHM_GEOMETRY` | launcher, from `IRIS_GEOM` | the published crop. **REQUIRED**: VC2 decodes 1282x1024 and the registry declares 1280x1024, and the consumer has no crop knob |
| `IRIS_CTL_SCREEN` | launcher, from `IRIS_GEOM` | the pointer clamp and the HELLO banner's `screen=`. Same source as the crop, so the frame, the clamp and the registry cannot drift |
| `IRIS_MONITOR_ADDR` | launcher | the monitor console (upstream hardcodes `127.0.0.1:8888`, a process-wide singleton). Inside `--private-network` this is the container's own loopback |
| `KH_PROVENANCE` | launcher | `strict` = refuse a checkpoint captured by a different binary (rule 6) |
| `IRIS_PTR_MODE` | launcher | `vc2` arms stream C's closed absolute loop; `rel` is the shipped fallback. **This string is the pointer method's device-ledger token** (`scripts/stations_registry/pointer_rules.py`) — without it in the launcher the registry gate fails, which is the point: the declaration cannot outrun the mechanism |
| `IRIS_STATE` | fixture | the snapshot the launcher restores; **empty forces a cold boot** (~7 min), exactly as `IRIX_STATE=` does on the `irix` sibling |
| `IRIS_WORK` | launcher | the writable dir inside the container (`/work`) |

## The two capture modes, and the one line that switches them

The launcher and `nspawn-inner.sh` implement **both**, keyed on `SH_CAPTURE`:

* `SH_CAPTURE=x11` — **the interim.** A pinned Xvfb inside the container, Iris
  as an ordinary winit window on it, `SH_INPUT_BACKEND=x11test`. This is
  architecture 2 of the brief and it exists to prove the container, the
  launcher, the pidfile contract, the streamhost attach and the `/os/<id>`
  publication path **before** the fork lands.
* `SH_CAPTURE=shm` — **what ships.** No X server, no `DISPLAY`, no window;
  frames IFB1 → `$BASE/run/fb.shm`, input `mamectl/1` → `$BASE/run/ctl.sock`.

Cutover is `SH_CAPTURE`, `SH_INPUT_BACKEND` and `runtime.x11.capture`. Nothing
else in the containment, the binds, the pidfiles or the reaping changes — which
is why the interim proof is worth taking.

## What the registry declares

`stream.pointer.method` = **`iris-vc2-closedloop`**, backend `mamesock`,
`absolute: true` (the validator derives `absolute`/`present` from the backend
and admits no other answer for a `mamesock` station with a pointer). `rel` is
not a legal fallback *in the registry* on this backend — if stream C's loop
does not converge, the fallback is the pointer method staying `none` and the
station shipping keyboard-only, or the conversion holding at `dbus-rel` on the
bridge. Say which in the guest doc; do not quietly declare an unproven abs.

`reset.mouse` / `reset.keyboard` stay **UNVERIFIED** until stream C's real-browser
probe clears them.

## Proven on the smoke rig, 2026-09-10 (stream B)

`/data/vms/sandbox/iris-b/rig`, never the live station. Frames are streamhost's
own: the IFB1 mapping decoded with `scripts/shmshot.py`.

| | file | what it shows |
|---|---|---|
| interim `SH_CAPTURE=x11` | `rig/proof/x11-01-irix-session-bg.png` | the IRIX 6.5 X session root, Xvfb pinned to 1280x1024 inside the container |
| | `rig/proof/x11-03-irix-autoconfig-relink.png` | the autoconfig relink console |
| shipping `SH_CAPTURE=shm` | `rig/proof/shm-01-irix-autoconfig-relink.png` | first published frame, correct colours |
| | `rig/proof/shm-02-irix-login-panel.png` | **the IRIX login panel** (root / EZsetup / demos / guest / chronic), red arrow cursor |

Containment, read off the live payload both runs: private `pid mnt net ipc uts
user` namespaces, `uid_map = 0 2031616 65536`, `CapBnd 0x15808dff` (no
`CAP_SYS_ADMIN`), `NoNewPrivs 1`, `Seccomp 2`. At the payload's own bounding set
(`setpriv --bounding-set=-all`): `mount` → permission denied, `/root` and the
IRIX disk → read-only filesystem, `ip link` → `lo` only, `ps -e` → `sd-stubinit`
and `iris` only, `/work` → writable.

### The open defect, closed

**The mapping was published 1282x1024, not 1280x1024.** Fixed in the publisher,
where it belongs: `IRIS_SHM_GEOMETRY` crops to the declared rectangle, and the
launcher derives it from `IRIS_GEOM` so it cannot be set independently. Verified
on the integration rig 2026-09-10 — `Rex3: Resolution changed to 1282x1024
cursor_x_adjust=5` followed by `iris: shm first geometry 1280x1024 (stride
5120)`, and a mapping of exactly 5 242 944 bytes. The two dropped columns are
real right-edge overscan, not black padding.
