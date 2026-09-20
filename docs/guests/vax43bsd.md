# vax43bsd guest — 4.3BSD on a SIMH VAX-11/780

Status: **LIVE 2026-09-20** (Tier 3 host-native container, no QEMU checkpoint).
Wave record: [`../lab/VAX43BSD-WAVE.md`](../lab/VAX43BSD-WAVE.md) — its status
header still reads PAUSED from the pause on 2026-09-20; the station has since
been brought up and this page is the current state. Shared runtime contract:
[`../lab/record-wave/shared-terminal-runtime.sh`](../lab/record-wave/shared-terminal-runtime.sh).

## Identity and source

- Public ID / station dir: `vax43bsd`; slot 215, UDP 54215, VMID 215, Xvfb
  `:115`. Container uid base 2490368 (38 × 65536).
- What it is: **4.3BSD** (Berkeley, June 1986) on an emulated **DEC VAX-11/780**
  under **Open SIMH** (`https://github.com/open-simh/simh`, pinned commit
  `a1f57fa3738ed31148d31126ba1a7278ff845c6d`, "PDP18B: Add delay to Type 647
  line printer"; reported by the binary as `VAX 11/780 simulator Open SIMH
  V4.1-0`). No QEMU, no MAME, no checkpoint: the exhibit is a simulator process
  plus one terminal, and **reset = relaunch** from the pristine seed disk.
- Media: TUHS, `https://www.tuhs.org/Archive/Distributions/UCB/4BSD/4.3BSD/`
  (the `.../UCB/4.3BSD/` path most guides quote 404s; the files are one level
  down under `4BSD/`) — `stand.gz`, `miniroot.gz`, `rootdump.gz`, `usr.tar.gz`,
  `FORMAT`, hashes and sizes in `docs/lab/VAX43BSD-WAVE.md`. Bootstrap is
  `boot42`, the 4.2BSD standalone boot (6600 bytes), uudecoded from the
  Computer History Wiki's `Boot42` page — SIMH cannot boot the emulated TS tape
  directly, so `boot42` is `load`ed at address 0 and entered with `r10=9
  r11=0`.
- Builder: `scripts/build-guests/tiles/vax43bsd.sh` — stages and hashes the
  TUHS media, builds the pinned `vax780`, installs 4.3BSD onto a fresh RA81
  image driven over the simulator console (`simhdrive.py`) and halts it clean,
  and debootstraps + uid-shifts the container rootfs. `assets/vax43bsd/MANIFEST.sha256`
  pins the media.

## Runtime and device set

```
rq0   RA81, work copy of bsd43-ra81.dsk   (root ra0a, /usr ra0h, /home ra0g)
ts    TS11, 43.tap attached read-only     (kernel probes ts0; mt/tar still work)
dz    DZ11, lines=8, 7b, telnet listener  (the visitor line, tty00..tty07)
rq1-3, rp, rl, tq, tu, lpt   disabled
tti/tto 7b · cpu idle=32v
```

No Ethernet — this station is deliberately an island: 4.3BSD's networking on
the SIMH 780 is unreliable and the DZ line is the whole visitor surface. There
is no QEMU checkpoint here: like `medley`, `lisa`, `perq` and `vision`, reset
= relaunch from the pristine seed, so a device-set change costs a rebuild, not
a re-bake.

| Part | Value |
|---|---|
| Simulator | `assets/vax43bsd/bin/vax780` (Open SIMH, pinned) |
| Seed disk | `assets/vax43bsd/media/bsd43-ra81.dsk`, mode 0444, `cp --sparse=always` into `work/ra81.dsk` on every launch |
| Tape | `assets/vax43bsd/media/43.tap`, attached read-only |
| Boot answer | SIMH's own `EXPECT`/`SEND` in `work/boot.ini` — no pty/expect supervisor (see below) |
| Display | pinned Xvfb `:115`, `1024x768x24` inside the container |
| Visitor client | one `xterm`, 80×24, DejaVu Sans Mono `-fs 14`, measures 960×576 px, placed `+32+96` to centre it on the 1024×768 root; `telnet -E 127.0.0.1 10023` |
| Capture | `SH_CAPTURE=x11` (X root) |
| Input | `SH_X11TEST_KEYS=1`, keyboard only — no pointer, no mouse on the 4.3BSD console |
| Network | none published (DZ line is container-internal only; see OPEN) |

80×24 is not a taste call: 4.3BSD's termcap `vt100` is fixed 24×80, and telnet
to a DZ line carries no window-size negotiation, so any other row count makes
full-screen programs (`vi`, `more`) draw wrong. `telnet -E` is deliberate too:
besides dropping a line of chrome it removes the `^]` escape, so a visitor
cannot fall out of the exhibit into a telnet command prompt.

Launcher: `streamhost/stations/vax43bsd/x11-runtime.sh` (contained, modelled
on medley's) execs `nspawn-inner.sh`, which stages `work/`, writes the SIMH
ini and then execs the lane's shared engine,
`docs/lab/record-wave/shared-terminal-runtime.sh` — vax43bsd is the station
that proved that contract end to end. The ini's boot answer is SIMH's own:

```
load -o boot42 0
d r10 9
d r11 0
expect "Boot\r\n: " send "ra(0,0)vmunix\r"; go
expect "login: " echo KHBOOTREADY; go
run 2
```

Each `expect` rule halts the simulation, runs its action list and `go`
resumes, which removes any Python/expect supervisor from the container and
leaves `vax780` as the single supervised process — the `mame.pid` +
`/proc/<pid>/exe` reap contract is unchanged, and it hands the shared runtime
its readiness token (`KHBOOTREADY`) for free.

**Launch time measured 2026-09-20: 53-60 s wall** (reap the previous launch,
boot, and get the login banner onto the framebuffer). Cold boot alone, process
start to `login:` on the console, is **~53 s** with `set cpu idle=32v`; the
bulk of it is the boot-time `fsck` of `ra0a`/`ra0h`/`ra0g` — the seed is
halted clean so fsck finds nothing to salvage.

### Trap 1 — no window manager, so focus must be pinned

No window manager runs in the container, so X input focus is `PointerRoot`
and keystrokes reach the xterm only while the pointer happens to be over it.
The daemon drives this station purely with XTEST keys and never moves a
pointer (there is none in the exhibit), so without an explicit
`XSetInputFocus` a visitor's typing lands on the root window and vanishes.
The launcher pins it once with `xdotool windowfocus`.

### Trap 2 — the login banner prints on line-open, not on connect

4.3BSD's `getty` prints its `login:` banner when it **opens** the DZ line,
which happens at boot into the void — long before any visitor connects. A
later telnet connection does **not** re-trigger it: measured, a passive
connect sat silent for 25 s on a line whose getty was alive and well. One CR
makes getty re-print, so the rest scene is the login prompt instead of a
black screen.

The launcher sends that CR itself and gates on the framebuffer, not the
keystroke: a lit-pixel count over the Xvfb root. Measured 2026-09-20 on this
station's own display: telnet chrome alone = 2958 lit pixels; chrome + SIMH's
own connect greeting + two login banners = 9148 — so one banner is worth
about 2000 lit pixels and a cursor blink about 90.

## Reset and fixture

`SH_RESET_MODE=relaunch`, no statefile: kill by `mame.pid`
(`/proc/<pid>/exe` under the asset dir, never a cmdline grep), `rm -rf work/`,
copy the pristine seed RA81 back in, relaunch. `SH_IDLE_PAUSE_SECS=60` — the
daemon SIGSTOPs the simulator after 60 s idle and the launcher's own standby
hook freezes it ~30 s after boot settles, so a frozen VAX between visitors
costs no core.

**Reset proven 2026-09-20**: `echo VISITOR-WAS-HERE > /VISITORWASHERE` typed
into the guest, then relaunch → `/VISITORWASHERE not found`, and the seed
`bsd43-ra81.dsk` sha256
`a99158ea72e318f6f5bc8cf7705e0f07c28b3ac92576d11811165f8e90f77a5d` unchanged
before and after.

## Museum shape as measured

- `uname` **does not exist** in 4.3BSD. The real commands are `hostname`,
  `machine`, `who`, `ls`, `netstat`.
- Guest hostname is `kernelhive` (stock 4.3BSD ships `myname.my.domain`, which
  reads as a placeholder in a gallery).
- The authentic `/etc/motd` is kept verbatim — `4.3 BSD UNIX #1: Fri Jun 6
  19:55:29 PDT 1986` ending *"Would you like to play a game?"* — and login
  prints *"Don't login as root, use su"*. That is the exhibit's voice; not
  museum copy.
- `/usr/games` is fully populated: adventure, backgammon, boggle, chess,
  ching, cribbage, doctor, fortune, hangman, …
- Kernel is stock `GENERIC`: `4.3 BSD UNIX #1: Fri Jun 6 19:55:29 PDT 1986
  karels@monet.Berkeley.EDU:/usr/src/sys/GENERIC`, 8 MiB real memory,
  `avail mem = 7187456`.

## Driving it by hand

There is no QMP and no exec channel; the DZ line is the only input surface and
it lives inside the container's private network namespace, so it is not
reachable from labhost as a normal TCP port. With no visitor attached the
daemon SIGSTOPs the simulator after 60 s idle — hold the wake lease first, or
input silently queues against a stopped process:

```bash
ssh lab 'touch /run/streamhost/wake/vax43bsd.lease   # TTL 90 s; re-touch for longer work
         grep State /proc/$(cat /data/vms/streamhost/stations/vax43bsd/mame.pid)/status   # want S, not T
         DISPLAY=:115 xdotool key --clearmodifiers Return'
ssh lab 'labctl shot vax43bsd'      # reads the X root
ssh lab 'labctl reset vax43bsd'     # relaunch: new pid, pristine seed in ~53-60 s'
```

To reach the DZ line itself from the host for debugging (bypassing the
visitor xterm), enter the container's network namespace:

```bash
ssh lab 'nsenter -t $(cat /data/vms/streamhost/stations/vax43bsd/mame.pid) -n python3 <driver> 10023'
```

— the port is on the container's own loopback behind `--private-network`, so
this is the only way in from outside the guest's own xterm.

## Security — CONTAINED (systemd-nspawn, 2026-09-20)

4.3BSD's root account has **no password** — that is stock 1986, not a local
mistake — so the containment, not the guest, is the security boundary, the
same posture `docs/guests/medley.md §Security` documents for the equivalent
host-app trap. SIMH, Xvfb and the visitor's xterm all run inside a
`systemd-nspawn` container: own PID/mount/IPC/UTS/user/network namespaces,
`--private-users=2490368:65536` `--private-users-ownership=off` (root inside
is an unprivileged host uid), `--private-network` (the DZ11 listener is
reachable only from inside the container, not from labhost), `--volatile=overlay`
over a minimal Debian trixie tree (nothing persists), `bin/` and `media/`
bound **read-only** at their host paths, `work/` the only writable bind,
`CAP_SYS_ADMIN` and friends dropped
(`CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE`),
`--system-call-filter='~@mount'`, `--no-new-privileges=yes`, `--as-pid2`
(the simulator's exit ends the container) and `--keep-unit` (lives in the
unit's BindsTo scope, so `systemctl stop` sweeps it). The host reaches the
display through a symlink `/tmp/.X11-unix/X115 ->
/run/streamhost/x11/vax43bsd/X115` (the container's socket directory bound
out), so the daemon's capture, XTEST input, `labctl shot` and the idle
freezer (SIGSTOP on `mame.pid`, the SIMH host pid) are all unchanged from an
uncontained station.

No exploit chain has been run to prove escape is impossible; this section
records the device-set and namespace posture as built, following the same
containment contract already proven for `medley`/`lisa`/`perq`/`vision`
(`docs/lab/record-wave/HOST-APP-CONTAINER-CONTRACT.md`).

## OPEN

- **`/usr/sys` kernel sources.** `srcsys.tar`/`src.tar` were not staged onto
  the tape for the first release, so the kernel sources are absent (the
  compiler toolchain in `/usr` is present). Adding them is a tape rebuild plus
  a second `tar` extract, not a reinstall.
- **No retronet plane.** No Ethernet in the frozen device set — deliberate for
  the first release; this station is an island by design.
- **Second DZ line.** The device set has eight DZ lines; only line 0 (tty00)
  is published as the visitor terminal. Whether a second line is worth
  exposing for two simultaneous visitors — very much the 1986 timesharing
  experience — is an open museum question.

## Rollback

`systemctl stop streamhost@vax43bsd`; delete `assets/vax43bsd` — nothing else
on the box was touched by this station. Claims re-home to `station-vax43bsd`
at landing.
