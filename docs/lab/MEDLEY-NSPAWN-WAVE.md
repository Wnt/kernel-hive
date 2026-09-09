# Medley containment wave — 2026-09-09

Re-enable the `medley` station (Interlisp Medley, host-native maiko under X —
see [`MEDLEY-WAVE.md`](MEDLEY-WAVE.md)) after the operator deactivated it the
same evening: maiko ran as **root on labhost in the host namespaces**, and the
Lisp Exec gives a visitor the host file system. Operator decisions: containment
= **systemd-nspawn ephemeral container**, **Xvfb inside the container**, the
relaunch gate = **proofs typed into the Exec and read off the framebuffer**,
scope = medley only. Requirements: (1) own PID namespace, (2) no host
applications visible, (3) no host network interfaces or devices, (4) no
mount/unmount of host file systems even as root inside.

## Design

| Piece | What |
|---|---|
| root file system | `debootstrap --variant=minbase trixie` + `xvfb procps iproute2 util-linux x11-utils xauth libbsd0`, 303 MB at `/data/vms/streamhost/assets/medley/rootfs`, built and uid-shifted once by `scripts/build-guests/tiles/medley.sh` |
| uid range | `--private-users=1966080:65536` (30·2¹⁶; nspawn requires a multiple of 2¹⁶; CT 950/951's subuid range starts at 100000). `--private-users-ownership=off` at launch — `chown` cannot be combined with a volatile root, so the shift is a one-shot `systemd-nspawn … --private-users-ownership=chown /bin/true` in the builder |
| root | `--volatile=overlay`: tmpfs upper over the read-only tree, nothing persists across launches |
| binds | `--bind-ro` `assets/medley/maiko` and `assets/medley/medley` **at their host paths** (so `/proc/<pid>/exe` and the idle freezer's cmdline match read the same from the host); `--bind work:/work` (the only writable path); `--bind /run/streamhost/x11/medley:/tmp/.X11-unix` (the socket dir, bound OUT) |
| network / devices | `--private-network` (only `lo`); nspawn's minimal `/dev` |
| privileges | `--drop-capability=CAP_SYS_ADMIN,CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_*,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE`, `--no-new-privileges=yes`, `--system-call-filter='~@mount'` |
| lifecycle | `--as-pid2`: nspawn's stub init is PID 1, `nspawn-inner.sh` PID 2 starts Xvfb and `exec`s maiko — maiko's exit ends the container, Xvfb included. `--keep-unit --register=no`: stays in the `qcap-medley-*` scope that `ensure-station-x11.sh` created with `BindsTo=streamhost@medley`, so `systemctl stop` sweeps it |
| host side of X | `/tmp/.X11-unix/X91` is a symlink to the bound socket; the daemon (`SH_CAPTURE=x11`, GetImage — no MIT-SHM, checked in `capture/x11.rs`), XTEST, `labctl shot` and xdotool connect unchanged |
| pidfiles | `mame.pid` = maiko's host pid (found by `/proc/*/exe` under the asset dir; the freezer SIGSTOPs it and `SH_IDLE_PAUSE_PROC_MATCH=assets/medley/maiko` still matches), `xvfb.pid` = the container's Xvfb (same PID namespace as maiko), `nspawn.pid` = the supervisor |
| inner script | ships as an emit `--aux-file` (root, 0600 in the station dir) and is `install`ed into `work/` with the container's ownership each launch — the mapped root cannot read a root-owned 0600 file |

The shipped command line is in `streamhost/stations/medley/x11-runtime.sh`.

## Proofs (dev rig: `/data/vms/sandbox/medley-nspawn/rig`, display `:95`, frames there)

Host-side audit of the running container (maiko pid from `mame.pid`):

```
uid=1966080 CapEff=0000000015808dff NoNewPrivs=1
pid:  host=pid:[4026531836]  container=pid:[4026535384]
mnt:  host=mnt:[4026531832]  container=mnt:[4026535381]
net:  host=net:[4026531833]  container=net:[4026535385]
ipc/uts/user: all differ likewise
nsenter … ps -e:   1 sd-stubinit · 2 ldex · 5 Xvfb   (7 entries in /proc incl. the probe)
nsenter … ip link: lo
nsenter … ls /dev: char core fd full fuse mqueue net null ptmx pts random shm stderr stdin stdout tty urandom zero
mounts: overlay / (lowerdir=…/rootfs, tmpfs upper) · tmpfs /tmp /dev /run · ro binds maiko, medley · rw /work · /proc with kallsyms/kcore/sysrq masked
```

Requirement 4, with **maiko's** capability set (a plain `nsenter` shell keeps
full user-namespace capabilities and can mount a tmpfs — that is not what the
payload has):

```
nsenter -t <maiko> -m -p -n -u -U -S 0 -G 0 -- setpriv --nnp --bounding-set -sys_admin,… --inh-caps -all -- sh -c '…'
CapEff: 000001ff7590cdff
mount -t tmpfs none /mnt   -> permission denied (rc 32)
mount /dev/sda1 /mnt       -> permission denied (rc 32)
umount /work               -> must be superuser to unmount (rc 32)
```

Typed into the Exec (XTEST via xdotool; the Exec is in the XCL package so
Interlisp functions carry `IL:`) — frames `p1.png`, `p2.png`, `p4.png`,
`p5.png`, `p6.png`:

| Form | Result on the frame |
|---|---|
| `(IL:INFILEP "{DSK}/data/kernel-hive/registry/local.env")` | `NIL` |
| `(IL:INFILEP "{DSK}/etc/osgallery/stream-ticket.env")` | `NIL` |
| `(IL:INFILEP "{DSK}/proc/1/comm")` | `{DSK}<proc>1>comm.;1` (the container's stub init) |
| `(IL:INFILEP "{DSK}/proc/67005/comm")` (a host nspawn pid) | `NIL` |
| `(DIRECTORY "{DSK}/data/vms/streamhost/stations/*")` | `NIL` |
| `(DIRECTORY "{DSK}/sys/class/net/*")` | `bonding_masters`, `lo` |
| `(DIRECTORY "{DSK}/dev/*")` | char core fd full fuse mqueue net null ptmx pts random shm stderr stdin stdout tty urandom zero |
| `(IL:INFILEP "{DSK}/work/proof.txt")` | the file (written from inside) |
| `(IL:OPENFILE "{DSK}/data/vms/streamhost/assets/medley/medley/hacked" 'IL:OUTPUT)` | `FS-PROTECTION-VIOLATION` break |
| `(IL:FILESLOAD IL:UNIXCOMM)` → `(IL:CREATE-PROCESS-STREAM "id")` | `NIL` — no subprocess (maiko logs `Failed to find UNIXCOMM file handles; no processes`, as the uncontained station did too) |

Station proofs on the same rig: Exec + logo on the first frame (`f1.png`);
XTEST warp readback exact at (811,533) and (523,333); SIGSTOP on `mame.pid`
→ a typed form changes nothing, SIGCONT → it evaluates (`p7-resumed.png`);
relaunch → old maiko and old nspawn gone, new pids, `work/` wiped
(`p8-after-reset.png`); the aux-copy path (`p9-auxcopy.png`).

## Landing

`station-land.sh medley` (no `--golden`; relaunch reset) landed main at
`a2a0e0ba`, rc 0, one window. The unit was **unmasked only after the rig
proofs above**, immediately before the window.

**Live proofs on the station** (frames `/data/vms/sandbox/medley-nspawn/`,
wake lease held; `medley-landed.png`, `live-proofs.png`, `live-violation.png`,
`live-after-reset.png`): unit active; maiko uid 1966080, `CapEff 15808dff`,
`NoNewPrivs 1`, in `qcap-medley-*.scope/payload`, every namespace differs from
PID 1's; `/tmp/.X11-unix/X91 -> /run/streamhost/x11/medley/X91`; the
`setpriv` mount test denies tmpfs, block device and umount; `ip link` = `lo`;
`ps` = stub init, ldex, Xvfb. Typed: `local.env` → NIL, the live nspawn pid's
`/proc/<pid>/comm` → NIL, net = `lo`, `CREATE-PROCESS-STREAM` → NIL, the
read-only open → `Protection violation`. `labctl reset medley` → new maiko
(old gone), pristine Exec.

## Walls

- `--volatile=overlay` implies a read-only root and refuses
  `--private-users-ownership=chown` → shift the tree once in the builder,
  `ownership=off` at launch.
- `--private-users` base must be a multiple of 2¹⁶ ("Automatic UID/GID
  adjusting is only supported for UID/GID ranges starting at multiples of
  2^16").
- A root-owned 0600 aux file is unreadable to the container's mapped root →
  copy into `work/` with the container's ownership.
- `nsenter` alone over-approximates what the payload can do (full userns
  caps) — drop to the payload's bounding set with `setpriv` before calling a
  mount test a proof.
- The Exec is in XCL: `INFILEP`/`FILESLOAD`/`OPENFILE` need the `IL:` prefix
  or the Exec answers "Undefined car of form".

## Measured timeline (file mtimes on labhost, from the operator's go)

| Milestone | Minute |
|---|---|
| rootfs built (debootstrap) | 6 |
| first contained Exec on the rig (`f1.png`) | 16 |
| host-side audit + Exec-typed proofs (`p1`–`p6`) | 21 |
| freeze / relaunch proofs | 24 |
| landed (`station-land.sh` rc 0, main `a2a0e0ba`) | 31 |
| live proofs + reset on the station | 33 |

## Teardown

Dev rig: maiko TERMed by `mame.pid`, container gone, `/tmp/.X11-unix/X95`
symlink and the rig socket dir removed, display `:95` claim released; zero
maiko processes on the host before the landing started.
