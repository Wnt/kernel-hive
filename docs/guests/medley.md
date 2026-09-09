# medley guest — Interlisp Medley, host-native

Status: **LIVE 2026-09-09** (Tier 3 host-native, no emulated machine). Wave
record: [`../lab/MEDLEY-WAVE.md`](../lab/MEDLEY-WAVE.md).

## Identity and source

- Public ID / station dir: `medley`; slot 191, UDP 54191, VMID label 191,
  Xvfb `:91`.
- What it is: **Interlisp Medley**, the Xerox PARC Lisp environment (1987
  release) as maintained by the Interlisp project, running on **maiko**, its
  portable byte-code VM, as a plain X11 client. No ROM, no disk image, no
  emulated CPU.
- Media (MIT licence, public, safe to fetch anywhere):
  `https://github.com/Interlisp/medley/releases/download/medley-260826-3a14c9aa_260319-9259716e/medley-full-linux-x86_64-260826-3a14c9aa_260319-9259716e.tgz`
  — 185512952 bytes, sha256
  `9e163aaf87a30f0e14e721826172d22c680153bab597c57ef20f39bea3736f76`.
  It bundles `medley/` (loadups, greetfiles, library, fonts, docs) and
  `maiko/linux.x86_64/{lde,ldex,ldeinit}`. Reference only: the Virtual OS
  Museum runs the 2023-11-03 build of the same repo with the same
  `run-medley` shape (`vom-reference.md`); nothing was copied from it.
- Builder: `scripts/build-guests/tiles/medley.sh` — fetch, verify, unpack
  into `/data/vms/streamhost/assets/medley/{medley,maiko}`, then a throwaway
  Xvfb boot proof. `assets/medley/MANIFEST.sha256` pins the tarball.

## Runtime and device set

There is no device set in the QEMU sense. The station is:

| Part | Value |
|---|---|
| Lisp VM | `assets/medley/maiko/linux.x86_64/ldex` (needs libX11, libbsd, libmd — all on labhost trixie) |
| Sysout | `medley/loadups/full.sysout` (Interlisp + Common Lisp + all the tools) |
| Greet | `medley/greetfiles/MEDLEYDIR-INIT` (the release default) |
| Display | pinned Xvfb `:91`, `1024x768x24`; `-g 1024x768 -sc 1024x768 -noscroll` so window == Lisp screen == capture |
| Memory | `-m 256` (MB of Lisp virtual memory) |
| Capture | `SH_CAPTURE=x11` (X root) |
| Input | `SH_INPUT_BACKEND=x11test`, `SH_X11TEST_ABS=1`, `SH_X11TEST_BUTTONS=xtest`, `SH_X11TEST_KEYS=1`, `LDEKBDTYPE=X` |
| Audio | off (Medley has none) |
| Network | none (see OPEN) |

Launcher: `streamhost/stations/medley/x11-runtime.sh` (modelled on amix's,
minus the guest-X warp). It reaps a previous maiko by `/proc/<pid>/exe` under
the asset dir, claims the display through `xvfb-alloc`, wipes `work/`, and
execs `ldex` with `HOME`, `LOGINDIR` and `LDEDESTSYSOUT` all inside `work/`
so a visitor's `SaveVM`/`LOGOUT` can never touch the asset tree.

Measured on the smoke rig (2026-09-09): the Exec and logo are on screen at
the first 2 s capture and the frame is byte-identical (bar the caret blink)
through 60 s. **Boot ≤ 2 s.**

## Reset and fixture

`resetMode=relaunch`, no statefile: kill by `mame.pid`, `rm -rf work/`,
relaunch the release sysout. Fixture = the default greet scene: white root,
the `Exec (XCL)` listener top-left with the greet transcript ending in a
time-of-day greeting (`Hi.` / `Good evening.` — MEDLEYDIR-INIT picks it, so
two resets can differ by that one line) and the `2>` prompt, the Medley logo
top-right, the black status line across the top.

## Input proofs (framebuffer, 2026-09-09)

Live station, wake lease held: `(+ 40 2)` typed over XTEST returned `42` in
the Exec (`live/typed2.png`); pointer readback 900,700 exact; `labctl reset`
gave a new pid and the pristine Exec (only the greeting and clock differ).
Earlier, on the smoke rig on `:91`:

- **Pointer PASS**: `xdotool mousemove 200 300` and `900 700` read back
  exactly; the click at 200,300 gave the Exec keyboard focus.
- **Keyboard PASS**: `(PLUS 40 2)` typed over XTEST echoed byte-perfect and
  was evaluated (`typed.png`; the Exec is XCL so `PLUS` is undefined — the
  shipped demo uses Common Lisp forms).
- Key pacing shipped at the fleet floor 40/40; nothing dropped at xdotool's
  60 ms.

## Driving it by hand

There is no QMP and no exec channel. With no visitor attached the daemon
SIGSTOPs maiko after 60 s idle, so **hold the wake lease first** or every
keystroke silently queues (measured 2026-09-09: a typed form changed nothing
until the lease was held):

```bash
ssh lab 'touch /run/streamhost/wake/medley.lease   # TTL 90 s; re-touch for longer work
         grep State /proc/$(cat /data/vms/streamhost/stations/medley/mame.pid)/status   # want S, not T
         DISPLAY=:91 xdotool mousemove 200 300 click 1 type "(+ 40 2)"; DISPLAY=:91 xdotool key Return'
ssh lab 'labctl shot medley'      # reads the X root
ssh lab 'labctl reset medley'     # relaunch: new pid, pristine Exec in ~3 s
```

Never inject while a session is attached — the daemon is the single injector
on this display.

## Security — CONTAINED (systemd-nspawn, 2026-09-09)

Medley is not an emulated machine: `maiko` is a host application, and the
Exec a visitor types into can open files and (with UNIXCOMM) spawn Unix
subprocesses. Until 2026-09-09 maiko ran **as root on labhost in the host
namespaces** under the stock `streamhost@` template, so a visitor was one
typed form away from the hypervisor's file system; the operator deactivated
the station ("absolute no-go") and set four requirements for relaunch:

1. own PID namespace — the Lisp side sees only its own processes;
2. no host applications visible;
3. no host network interfaces or devices;
4. no mount/unmount of host file systems, even as root inside.

**The boundary now** (`streamhost/stations/medley/x11-runtime.sh` +
`nspawn-inner.sh`): maiko AND its Xvfb run inside a `systemd-nspawn`
container — `--private-users=1966080:65536` (root inside is an unprivileged
host uid), `--private-network` (only `lo`), `--volatile=overlay` over a minimal
Debian trixie tree built by `tiles/medley.sh` (nothing persists), the Medley
tree and maiko bound **read-only** at their host paths, `work/` the only
writable bind, `CAP_SYS_ADMIN` and friends dropped, `--system-call-filter=~@mount`,
`--no-new-privileges`, `--as-pid2` (maiko's exit ends the container) and
`--keep-unit` (it lives in the unit's BindsTo scope, so `systemctl stop`
sweeps it). The host reaches the display through a symlink
`/tmp/.X11-unix/X91 -> /run/streamhost/x11/medley/X91` (the container's socket
directory bound out), so the daemon's capture (GetImage, no MIT-SHM), XTEST
input, `labctl shot` and the idle freezer (SIGSTOP on `mame.pid`, which holds
maiko's host pid) are unchanged. The X server is the only thing the Lisp side
can talk to, and only over the X protocol.

**Proven on the framebuffer, typed into the Exec** (frames in
[`../lab/MEDLEY-NSPAWN-WAVE.md`](../lab/MEDLEY-NSPAWN-WAVE.md)). The Exec is in
the XCL package, so Interlisp functions take the `IL:` prefix:

| Typed form | Shows | Requirement |
|---|---|---|
| `(IL:INFILEP "{DSK}/data/kernel-hive/registry/local.env")` | `NIL` | host files invisible |
| `(IL:INFILEP "{DSK}/etc/osgallery/stream-ticket.env")` | `NIL` | host secrets invisible |
| `(IL:INFILEP "{DSK}/proc/<host nspawn pid>/comm")` | `NIL`; `/proc/1/comm` (the container's stub init) exists | own PID namespace, no host processes (1, 2) |
| `(DIRECTORY "{DSK}/sys/class/net/*")` | `lo` only | no host interfaces (3) |
| `(DIRECTORY "{DSK}/dev/*")` | nspawn's minimal set (null, zero, random, tty, pts, shm…) | no host devices (3) |
| `(IL:OPENFILE "{DSK}/data/vms/streamhost/assets/medley/medley/hacked" 'IL:OUTPUT)` | `FS-PROTECTION-VIOLATION` | Medley tree read-only |
| `(IL:INFILEP "{DSK}/work/proof.txt")` | the file | `work/` is the scratch |
| `(IL:FILESLOAD IL:UNIXCOMM)` then `(IL:CREATE-PROCESS-STREAM "id")` | `NIL` | no subprocess at all (maiko reports "no UNIXCOMM file handles" in this launch shape — it did before the container too) |

Requirement 4 cannot be typed (no subprocess), so it is proven **inside the
container's namespaces with maiko's capability set**:
`nsenter -t $(cat mame.pid) -m -p -n -u -U -S 0 -G 0 -- setpriv --nnp
--bounding-set -sys_admin,… -- sh -c 'mount -t tmpfs none /mnt; mount
/dev/sda1 /mnt; umount /work'` — all three `permission denied` / `must be
superuser`. (A plain `nsenter` shell keeps full user-namespace capabilities
and CAN mount a tmpfs there — that is not what maiko has; `CapEff` of maiko
is `15808dff`, no `CAP_SYS_ADMIN`, `NoNewPrivs 1`.)

**Host-side audit** (`docs/lab/MEDLEY-NSPAWN-WAVE.md`): maiko uid 1966080,
every `/proc/<pid>/ns/*` differs from PID 1's, mounts inside are the overlay
root, tmpfs `/tmp` `/dev` `/run`, the two read-only binds, `/work`, and `/proc`
with the kernel interfaces masked.

**Run the proofs again** (after any change to the launcher, the rootfs or
nspawn): hold the wake lease, type the table above into the Exec with
`xdotool` on `:91` (see §Driving it by hand), `labctl shot medley`, and run
the `nsenter … setpriv` line. The same review applies to any future station
whose guest is a stock host application rather than an emulated machine — see
memory/rule "no unsandboxed host-app stations".

## OPEN

- **Network plane.** maiko can bridge Lisp TCP/IP to the host (its nethub /
  TAP options), which would let Medley's own TCP stack join the retronet at
  its reserved `10.99.0.39`; no period browser exists for it, so the value is
  an FTP/telnet demo at most. The reservation and tap name are held as the
  uniqueness ledger only; no `rn-tapnet.sh` is committed.
- **IM client**: none exists for Medley; by definition OPEN.
- **Richer rest scene**: a greet file that also opens an Inspector or a
  Sketch window would show more of the environment at first sight. The
  default greet was kept so the release image, not a local edit, is what
  ships.

## Rollback

`systemctl stop streamhost@medley`; delete `assets/medley` — nothing else on
the box was touched by this station. Claims re-home to `station-medley` at
landing.
