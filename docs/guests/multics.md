# multics guest — Multics MR12.8 on an emulated DPS-8/M

Status: **live, record wave 2026-09-20** (Tier 3 host-native container,
no QEMU checkpoint) — `lifecycle: production`, `enabled: true` in
`registry/stations/multics.json`, which is the authority. Wave record: [`../lab/MULTICS-WAVE.md`](../lab/MULTICS-WAVE.md).
Shared runtime contract:
[`../lab/record-wave/shared-terminal-runtime.sh`](../lab/record-wave/shared-terminal-runtime.sh)
— multics is the station that contributed findings 1, 2 and 4 to it.

## Identity and source

- Public ID / station dir: `multics`; slot 217, UDP 54217, VMID 217, Xvfb
  `:117`. Container uid base 2555904 (39 × 65536).
- What it is: **Multics MR12.8** (Honeywell/Bull, the final release, 1992) on
  an emulated **Honeywell DPS-8/M** under the **DPS8M simulator R3.1.0**
  (`https://dps8m.gitlab.io`, commit `a834c552e9046ed485fabbefa3139dc5ea08e64d`,
  reported by the binary as `DPS8/M simulator R3.1.0 (64-bit)`). No QEMU, no
  MAME, no checkpoint: the exhibit is a simulator process plus one terminal,
  and **reset = relaunch** from the pristine baked RPV.
- Media: the community `QuickStart_MR12.8.zip` release
  (`https://s3.amazonaws.com/eswenson-multics/public/releases/MR12.8/QuickStart_MR12.8.zip`),
  hashes and sizes pinned in `scripts/build-guests/tiles/multics.sh` and
  `assets/multics/MANIFEST.sha256`. The tape is `12.8MULTICS.tap`, the MR12.8
  system tape shipped inside that release.
- Builder: `scripts/build-guests/tiles/multics.sh` — stages and hashes the
  QuickStart zip and the dps8m tarball, installs the pinned `dps8`, stages the
  read-only tape, and uid-shifts the container rootfs. The RPV disk itself is
  **not** built by this script; it is baked separately by
  `scripts/build-guests/tiles/multics-bake-golden.py`, which drives a real
  Multics install over the simulator console and is the only thing allowed to
  produce `media/root.dsk`.

## Runtime and device set

```
disk0  the work copy of the baked MR12.8 RPV       (writable, reflink per launch)
tape0  12.8MULTICS.tap, read-only                   (the MR12.8 system tape)
fnp3   FNP D, telnet listener on 6180                (channel d.h000 is the visitor line)
no Ethernet, no other channel — this station is an island on purpose
```

No network plane and no retronet: Multics had ARPANET networking in its day,
but the FNP terminal line is the whole visitor surface here, frozen for the
first release. The FNP telnet listener lives on the container's own loopback
behind `--private-network`, so it claims no host port and is unreachable from
labhost.

| Part | Value |
|---|---|
| Simulator | `assets/multics/bin/dps8` (DPS8M R3.1.0, pinned) |
| Seed disk | `assets/multics/media/root.dsk`, mode 0444, `cp --reflink=auto` into `work/root.dsk` on every launch |
| Tape | `assets/multics/media/12.8MULTICS.tap`, attached read-only |
| Boot answer | `nspawn-inner.sh`'s own `autoinput` block in `work/boot.ini` — the stock QuickStart MR12.8 boot answer sheet, verbatim |
| Display | pinned Xvfb `:117`, `1024x768x24` inside the container |
| Visitor client | one `xterm`, 80×24, DejaVu Sans Mono `-fs 14`, amber (`#ffb000`) on black, placed `+32+96` on an otherwise black 1024×768 root; runs the station's own `multics-term.pl` bridge, not stock telnet |
| Capture | `SH_CAPTURE=x11` (X root) |
| Input | `SH_X11TEST_KEYS=1`, keyboard only — no pointer, no mouse; a 1969 timesharing terminal has none to give |
| Network | none published (FNP line is container-internal only; see OPEN) |

80×24 is what Multics' own default line type assumes, and the FNP carries no
window-size negotiation, so anything else makes full-screen output wrap
wrong.

Launcher: `streamhost/stations/multics/x11-runtime.sh` (contained, modelled on
vax43bsd's) execs `nspawn-inner.sh`, which stages `work/`, writes the DPS8M
ini and then execs the lane's shared engine,
`docs/lab/record-wave/shared-terminal-runtime.sh` — this station proved
findings 1, 2 and 4 of that contract. `nspawn-inner.sh`'s `autoinput` block:

```
autoinput rpv a11 ipc 3381 0a\n
autoinput bce\n
autoinput yes\n
autoinput yes\n
autoinput boot star\n
autoinput \z

boot iom0
```

It answers `find_rpv_subsystem`'s RPV data prompt, BCE's `bce` request, the
time-of-day confirmation, the boot_delta warning (the baked disk was shut down
cleanly, so its RPV label carries an unmounted time and the warning is
expected and correct), and finally `boot star` to bring up the answering
service. `\z` closes the autoinput stream so the operator console is free for
the visitor's session afterward.

**Readiness measured 2026-09-20T08:58:32Z: TCP/6180 open at +4 s, `as_init_:
Multics MR12.8; Answering Service 17.0` on the simulator's own console at
+52 s** — the 48 s gap is finding 1 of the shared runtime (below), and a
second run on a loaded box took 111 s, so the timeout is generous while the
gate that matters is the console line, not a fixed number.

### Finding 1 — a TCP port probe is not a readiness gate

The telnet listener on 6180 belongs to the simulator, not to the guest: it
binds at +4 s and then lies for the whole of the answering-service bring-up.
A visitor client started on the port alone would attach to a line the guest
has not opened yet. The launcher gates on TWO conditions instead: the port
answers AND the simulator's own console stream has printed `as_init_`
(`KH_TERM_READY_LOG_RE='as_init_'` in `nspawn-inner.sh`). This station is the
sharpest of the three that proved this finding — mvs38 and vax43bsd have
smaller gaps between port-open and guest-ready.

### Finding 2 — never give the hidden emulator a pipe or a FIFO on stdin

`dps8 boot.ini < fifo` prints as far as the FNP listen line and then sleeps
forever: no CPU thread, no boot. `/dev/null` boots — the simulator console is
its own input path once the autoinput sheet is spent, so no pty/expect
supervisor is needed. `nspawn-inner.sh` pins `KH_TERM_EMULATOR_STDIN=/dev/null`
explicitly rather than inherit whatever the outer launcher happened to have.

### Finding 4 (this station) — an attention-key console must handshake on a NEW prompt

`system_control` drops request text that arrives in the same write as the
attention ESC, and sometimes releases the console without running anything
(`CONSOLE: RELEASED`) instead of erroring. The bake script's handshake is ESC
→ wait for a fresh `M-> ` prompt → settle → send the request → verify it ran
from its own echo, retrying when the echo does not appear. This finding
belongs to the bake tooling (`multics-bake-golden.py`), not the launcher —
the exhibit itself never drives the operator console.

### Trap inherited from vax43bsd — no window manager, so focus must be pinned

No window manager runs in the container, so X input focus is `PointerRoot`
and keystrokes reach the xterm only while the pointer happens to be over it.
The daemon drives this station purely with XTEST keys and never moves a
pointer, so without an explicit `XSetInputFocus` a visitor's typing would land
on the root window and vanish. The launcher pins it once with
`xdotool windowfocus`, at bring-up.

### The bridge — why stock telnet cannot front this exhibit

`streamhost/stations/multics/multics-term.pl` runs as the xterm's command in
place of stock telnet, for three reasons measured on this station's own
framebuffer 2026-09-20:

1. Stock telnet opens on its own chrome — `Trying 127.0.0.1...`, `Connected
   to 127.0.0.1.`, `Escape character is 'off'.` — which is 2026, not 1969.
2. The FNP does not hand a fresh connection straight to Multics. It answers
   with a 32-channel `HSLA Port (d.h000,...,d.h031)?` menu that fills a third
   of an 80×24 screen before a visitor ever sees the guest. Measured: 14553
   lit px with stock telnet showing that menu, 5554 with the bridge, which
   answers the menu itself and shows none of it — the rest scene is just the
   Multics banner.
3. A visitor who types `logout` — the correct way to leave a Multics
   session, and part of this station's own type-in demo — gets "Multics has
   disconnected you" from stock telnet and a **dead terminal**; every later
   visitor then finds a station that does nothing until the next relaunch
   reset happens to run. The bridge reconnects at a fresh banner instead,
   which is also what the FNP's own line discipline expects. Measured over
   five logout cycles, the FNP reuses its channel (d.h000 on a fresh
   container, d.h001 after a reconnect) rather than climbing toward its
   32-channel limit.

The bridge offers no telnet escape character on purpose: there is nothing for
a visitor to fall out of the exhibit into.

## Reset and fixture

`SH_RESET_MODE=relaunch`, no statefile: kill by `mame.pid` (`/proc/<pid>/exe`
under the asset dir, never a cmdline grep), `rm -rf work/`, reflink-copy the
pristine seed RPV back in, relaunch. `SH_IDLE_PAUSE_SECS=60` — the daemon
SIGSTOPs the simulator after 60 s idle, and the launcher's own standby hook
freezes it ~30 s after the login prompt settles, so a frozen DPS-8/M between
visitors costs no core.

**MEASURED 2026-09-20 end to end: 2 min 24 s to a lit banner** on a box at
load 60, of which the 594 MB reflink copy itself is 1.35 s.

**Reset proven 2026-09-20**: `create VISITORWASHERE` typed into the guest
made `list` report `Segments = 2`; after the relaunch `list` reported
`Segments = 1` with only the baked `Repair.value`, `Last login` was back to
the bake's own 0458.9 session, and the seed's sha256 was unchanged either
side.

The seed must be baked to `shutdown complete` at the operator console — a
simulator killed mid-run leaves the RPV inconsistent and the next boot stops
in BCE asking questions the autoinput sheet does not answer.

### The bake — paying for the forced password change once

The released MR12.8 QuickStart forces a password change on the very first
`Repair` login. A visitor must never be shown that, so
`multics-bake-golden.py` makes the change once, on labhost, and shuts the
disk down clean; every launch then reflink-copies that pristine RPV. Login on
the live exhibit is `login Repair`, password `multics`.

The bake script's docstring lists four things it pays for, one run each
(2026-09-20): the FIFO-stdin trap (finding 2, above), the attention-key
handshake trap (finding 4, above), that `shut` does not actually shut down —
it answers "shutdown: 5 users still on. Do you want to shut down?" and waits,
because the standard SysDaemons the answering service logs in at every boot
are always still there, so that prompt is the normal path and must be
answered, not treated as an anomaly — and that `die` is **not** a
`system_control` request: after `shutdown complete` the console belongs to
BCE, which takes typed lines with no attention key, so sending `die` through
the ESC handshake produces `system_control: Unknown request "die"`.

## Museum shape as measured

- **`print_wd` is NOT present in this installation** — measured: `Segment
  print_wd not found`. The verified commands are `list`, `who`, `date_time`,
  `help`.
- There is **no login prompt**: Multics prints the banner and waits, because
  it assumes the visitor already knows the word is `login`. The SPA type-in
  demo is what tells them.
- The keyboard is **not a PC's**. `#` is erase (measured: `prinq#t_wd` reached
  the system as `print_wd`) and `@` is kill (measured: `this is
  rubbish@date_time` ran `date_time` alone), and `>` is the pathname
  separator. ^C is the QUIT signal and behaves as 1969 intended — it does not
  cancel, it **suspends** and hands the visitor a new command level (the
  prompt gains `level 2`); `release` discards that level and returns to the
  one below.
- Login proven 2026-09-20 on the framebuffer at every step: `login Repair`
  typed at the banner returned `Password:`, the baked password `multics`
  returned `You are protected from preemption.` and a Multics ready prompt
  (`r 05:17 0.660 19`), and `who` printed `Multics MR12.8, load 6.0/90.0;
  6 users, 1 interactive, 5 daemons`.
- At rest the fixture shows exactly two lines and a block cursor: `Multics
  MR12.8: Installation and location (Channel d.h000)` and `Load = 5.0 out of
  90.0 units: users = 5, <date>` — the bridge is what keeps the FNP's channel
  menu and telnet's own chrome off that scene (see above).

## Driving it by hand

There is no QMP and no exec channel; the FNP line is the only input surface
and it lives inside the container's private network namespace, so it is not
reachable from labhost as a normal TCP port. `labctl shot` reads the X root.
The operator console is **not** the museum surface — it goes to
`work/emulator.log` and carries the `M-> ` attention prompt and BCE, never
onscreen. With no visitor attached the daemon SIGSTOPs the simulator after
60 s idle — hold the wake lease first, or input silently queues against a
stopped process:

```bash
ssh lab 'touch /run/streamhost/wake/multics.lease   # TTL 90 s; re-touch for longer work
         grep State /proc/$(cat /data/vms/streamhost/stations/multics/mame.pid)/status   # want S, not T
         DISPLAY=:117 xdotool key --clearmodifiers Return'
ssh lab 'labctl shot multics'      # reads the X root
ssh lab 'labctl reset multics'     # relaunch: new pid, pristine seed in ~2m24s
```

To reach the FNP line itself from the host for debugging (bypassing the
visitor xterm and its bridge), enter the container's network namespace, only
while no visitor is attached:

```bash
ssh lab 'nsenter -t $(cat /data/vms/streamhost/stations/multics/mame.pid) -n telnet 127.0.0.1 6180'
```

— the port is on the container's own loopback behind `--private-network`, so
this is the only way in from outside the guest's own xterm.

## Security — CONTAINED (systemd-nspawn, 2026-09-20)

Multics is logged into as a real user with a known password (`Repair` /
`multics`), so the containment, not the guest, is the security boundary — the
same posture `docs/guests/medley.md §Security` documents for the equivalent
host-app trap. DPS8M, Xvfb and the visitor's xterm all run inside a
`systemd-nspawn` container: own PID/mount/IPC/UTS/user/network namespaces,
`--private-users=2555904:65536` `--private-users-ownership=off` (root inside
is an unprivileged host uid), `--private-network` (the FNP telnet listener is
reachable only from inside the container, not from labhost),
`--volatile=overlay` over a minimal Debian trixie tree (nothing persists),
`bin/` and `media/` bound **read-only** at their host paths, `work/` the only
writable bind, `CAP_SYS_ADMIN` and friends dropped
(`CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE`),
`--system-call-filter='~@mount'`, `--no-new-privileges=yes`, `--as-pid2`
(the simulator's exit ends the container) and `--keep-unit` (lives in the
unit's BindsTo scope, so `systemctl stop` sweeps it). The host reaches the
display through a symlink `/tmp/.X11-unix/X117 ->
/run/streamhost/x11/multics/X117` (the container's socket directory bound
out), so the daemon's capture, XTEST input, `labctl shot` and the idle
freezer (SIGSTOP on `mame.pid`, the DPS8M host pid) are all unchanged from an
uncontained station.

No exploit chain has been run to prove escape is impossible; this section
records the device-set and namespace posture as built, following the same
containment contract already proven for `medley`/`lisa`/`perq`/`vision`/
`vax43bsd` (`docs/lab/record-wave/HOST-APP-CONTAINER-CONTRACT.md`).

## OPEN

- **No retronet plane.** Multics had ARPANET networking in service, but the
  FNP terminal line is the whole visitor surface here — deliberate for the
  first release, this station is an island by design.
- **Second FNP channel.** The device set carries a 32-channel FNP CDT; only
  d.h000 is published as the visitor terminal. Whether a second line is worth
  exposing for two simultaneous visitors is an open museum question, the same
  one `vax43bsd` leaves open for its own second DZ line.

## Rollback

`systemctl stop streamhost@multics`; delete `assets/multics` — nothing else
on the box was touched by this station. Claims re-home to `station-multics`
at landing.
