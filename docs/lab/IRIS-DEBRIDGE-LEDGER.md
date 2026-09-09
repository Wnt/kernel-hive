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
| `$BASE/fb.shm` | the emulator (`IRIS_SHM_PATH`) | validator-fixed path. Pre-created empty by the launcher and bind-mounted **as a file** into the container |
| `$BASE/run/ctl.sock` | the emulator (`IRIS_CTL_SOCK`) | `mamectl/1`. `$BASE/run` is a bound directory, not `$BASE` itself — the station dir holds `station.env`, `signaling.json` and the cert hash and is never exposed to the payload |
| `$BASE/run/iris-ci.sock` | the emulator (`IRIS_CI_SOCK`) | stream D's restore verbs / the exec channel |
| `$BASE/work` | the launcher, wiped every launch | `iris.toml`, `nvram.bin`, the disk COW overlay, logs. The **only** writable bind |
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
| `IRIS_SHM_PATH` | launcher (shm mode only) | IFB1 mapping; its presence on the no-window branch is what installs the `Renderer` (stream A commit 1) |
| `IRIS_CTL_SOCK` | launcher | the `mamectl/1` listener (stream C) |
| `IRIS_CI_SOCK` | launcher | Iris's own JSON-lines ci socket (`--ci-socket`) |
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
  frames IFB1 → `$BASE/fb.shm`, input `mamectl/1` → `$BASE/run/ctl.sock`.

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
