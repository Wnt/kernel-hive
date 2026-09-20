# Lane B findings from `vax43bsd` — reusable by any SIMH/terminal station

Written 2026-09-20 by the `vax43bsd` worker before the lane stood down for load.
These are measured on labhost, not proposed. `multics`, `its` and any other
SIMH-fronted station in this lane can take them as given.

## 1. A SIMH station needs no pty/expect supervisor

The draft runtimes in this lane all assume something has to type the standalone
boot line (`ra(0,0)vmunix` for 4.3BSD) at the simulator's `Boot` prompt, which
would put a Python/expect supervisor between the container's init and the
emulator and break the "one supervised process, resolve it by `/proc/<pid>/exe`"
pidfile contract that `medley`/`lisa`/`indyr4400` use.

SIMH answers its own prompt. In the ini file:

```
load -o boot42 0
d r10 9
d r11 0
expect "Boot\r\n: " send "ra(0,0)vmunix\r"; go
expect "login: " echo KHBOOTREADY; go
run 2
```

Each `expect` rule halts the simulation, runs its action list, and `go` resumes
it. Proven with `set quiet` and stdin on `/dev/null`: the guest reached
`login: ` unattended in ~53 s, with SIMH as the only process.

`echo KHBOOTREADY` gives a cheap readiness token in the console log. Prefer the
**port** probe from `shared-terminal-runtime.sh` over it anyway — the token
proves the kernel got to getty, the port probe proves the getty.

## 2. Keep the operator console out of the capture for free

Because nothing drives the console interactively, SIMH's stdout can go straight
to a logfile inside the container's writable `work/`. The visitor surface is a
separate connection (for `vax43bsd`, `xterm -e telnet 127.0.0.1 <dz port>` to
SIMH's own DZ telnet listener) — so "hide the simulator console" needs no
cropping, no second X window and no window-manager tricks.

## 3. The tape/port/device notes

- `att dz <port>` fails with `Sockets: bind error 98` if a previous simulator is
  still alive, and SIMH then **carries on booting without the device**. The
  kernel prints `dz0 at uba0` only, the visitor line silently does not exist,
  and nothing in the guest says why. Check the ini-file echo at the top of the
  console log before believing a missing terminal is a guest problem.
- Snapshot the pristine seed disk only from a guest that ran `sync; sync;
  /etc/halt`. A simulator killed at the console leaves the filesystem dirty;
  4.3BSD then salvages it at the next boot **and reboots itself**, which from
  outside looks exactly like a station that boot-loops.
- `cp --sparse=always` keeps a 436 MB RA81 image at 19 MB on disk.

## 4. The rule-5 trap this worker walked into

Reaping with a cmdline grep (`case "$c" in *dzprobe.py*`) matched the very ssh
command that was running the sweep and killed it. Resolve by
`/proc/<pid>/exe` and `/proc/<pid>/cwd`, and skip your own process ancestry —
AGENTS.md rule 5 exists for precisely this.
