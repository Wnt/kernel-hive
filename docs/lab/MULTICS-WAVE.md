# Multics MR12.8 — station wave (record wave, Lane B)

Tracking: #51 · prep branch `multics` · work branch `multics-work` ·
seed [`integration-seeds/multics.md`](integration-seeds/multics.md) ·
lane contract [`record-wave/HOST-APP-CONTAINER-CONTRACT.md`](record-wave/HOST-APP-CONTAINER-CONTRACT.md)

**STATUS 2026-09-20T13:20Z: LIVE.** The station renders, takes keystrokes and
resets deterministically, and every claim below that was byte-level at the
pause is now framebuffer-proven. The three walls W1–W3 are closed; W3 needed
two more findings than the pause knew about (§"W3, closed").

## Allocation ledger

| Station | Session | Slot / UDP / VMID | X display | X-warp | retronet |
|---|---|---|---|---|---|
| multics | multics-live | 217 / 54217 / 217 | `:117` | — | — |

Slot 208 was released at the pause and msx2 took 107; the wave re-allocated at
resume with `wave.sh alloc multics`. bindingOrder/bringUpOrder are 117, chosen
to match the slot and stay clear of the siblings landing in the same window.

Neither `--retronet` nor `--x11warp` was taken: the visitor surface is an X
terminal captured with `SH_CAPTURE=x11` + XTEST (the medley route), and the
guest has no network of its own — the FNP telnet line is loopback INSIDE the
container.

Container uid base: **2555904** (39·65536). NOT the 2031616 recorded at the
pause: the rootfs was built at that base and mvs38's rootfs was found at the
same one, and two contained stations sharing a uid base means each can write
the other's files. tiles/multics.sh detects 2031616 and shifts the tree.

## Media (measured, `stat -c %s` + `sha256sum` on the box)

| File | Bytes | SHA-256 | Upstream |
|---|---|---|---|
| `QuickStart_MR12.8.zip` | 143942587 | `0c67af417950ca529249ce16568e8cc97cd8b4d7fde34081bd25af03cf64fac2` | `https://s3.amazonaws.com/eswenson-multics/public/releases/MR12.8/QuickStart_MR12.8.zip` |
| `dps8m-r3.1.0-linux-641.tar.gz` | 2678491 | `ce6104ac20349ca6d25fa4f3df9afb52714334b506c7dba911a178d7cbbb0ed7` | `https://dps8m.gitlab.io/dps8m-r3.1.0-archive/R3.1.0/dps8m-r3.1.0-linux-641.tar.gz` |

QuickStart contents (byte sizes from `unzip -l`):
`root.dsk` 594001152 · `12.8MULTICS.tap` 5349060 · `MR12.8_boot.ini` 956 ·
`site_setup.sh` 11645 · `README.txt` 2420.

Simulator pin, read from the simulator's own banner — **not** from a README:

```
DPS8/M simulator R3.1.0 (64-bit)
  Commit: a834c552e9046ed485fabbefa3139dc5ea08e64d
```

`file dps8` → statically linked x86-64 ELF, so the container rootfs needs no
runtime libraries for the simulator itself.

Staged at `/data/assets-staging/multics/` (labhost mount, not CT950's).

## What is PROVEN, and by what

The framebuffer is the only proof a guest reacted, and **this wave never reached
a framebuffer**. Everything below was proved at the byte level on the FNP telnet
line or in the simulator's own console stream, and is recorded as exactly that —
none of it is a claim about pixels.

1. **MR12.8 boots unattended from the stock QuickStart ini** with the R3.1.0
   binary, `stdin` on `/dev/null`, in a namespaced sandbox dir.
   Measured 2026-09-20T08:58:32Z: TCP/6180 open at **+4 s**, answering service
   (`as_init_: Multics MR12.8; Answering Service 17.0`) at **+52 s**; a second
   run under a pty reached the answering service at +111 s on a loaded box.
2. **The visitor line works.** A raw socket to 127.0.0.1:6180 gets
   `IAC WILL SGA / WILL ECHO / WILL BINARY` then the `HSLA Port (...)` prompt;
   one `\r\n` yields `Attached to line d.h000` and the
   `Multics MR12.8: Installation and location (Channel d.h000)` banner;
   `login Repair` then answers `Password:`.
3. **The password bake works.** `login Repair -cpw` / `repair` / new password
   twice returns `Password changed.` and a logged-in Multics command level
   (`r 01:15 2.279 33`). This is the fix for the exhibit: the stock QuickStart
   FORCES a password change on the first `Repair` login, which no visitor should
   ever be shown.
4. **`cp --reflink=auto` of the 594 MB `root.dsk` costs 0.126 s** on labhost's
   ZFS. A pristine per-launch copy is therefore free — this station wants
   relaunch, not a checkpoint, exactly as the seed guessed.
5. **The container rootfs builds**: debootstrap `--variant=minbase --include=
   xvfb,xterm,telnet,netcat-openbsd,procps,iproute2,util-linux,x11-utils,xauth,
   xfonts-base,fonts-dejavu-core,ncurses-term` trixie, uid-shifted to 2031616 in
   a one-shot nspawn. 362 MB. Built at
   `/data/vms/streamhost/assets/multics/rootfs`.

## Three walls, all closed

### W1 — a FIFO on the simulator's stdin wedges it before boot

`dps8 MR12.8_boot.ini < con.fifo` prints as far as
`[FNP emulation: TELNET server listening on 0.0.0.0:6180]` and then sleeps
forever: no `bootload_0`, no CPU thread. `/dev/null` boots; a **pty** boots.
The console is not optional plumbing — it is the simulator's own clock-ish
input path, the same shape as the PERQ trap in
[`perq-station.md`](../../docs/lab/perq-station.md) (a TTY as its clock).

**Contract for the lane:** the hidden emulator gets `/dev/null` (no console
driving needed) or a **pty** (console driving needed). Never a pipe or a FIFO.

### W2 — `nc -z <port>` is NOT a readiness probe for a heritage terminal

The draft `record-wave/shared-terminal-runtime.sh` starts the visitor client as
soon as a TCP port probe succeeds. On Multics that probe passes at **+4 s** and
the system is not usable for another **48 s**: a visitor client started on the
port probe attaches to a line on a system whose answering service does not
exist yet. The readiness proof has to be a **line in the emulator's own console
stream** (`as_init_` here; the sibling equivalent for MVS/VAX/ITS), with the
port probe kept only as a cheap precondition.

### W3, closed — driving the operator console through a clean shutdown

The pause had one third of this. `\033shut\r` in one write is swallowed, and
the fix is ESC → wait for a NEW `M-> ` → settle → send. Two more findings were
needed before a bake completed, and each cost a run:

**W3a — a request that was silently dropped looks exactly like one that ran.**
Even with the handshake, the console sometimes takes the ESC, prints its
prompt and then releases without executing anything (`M-> CONSOLE: RELEASED`).
Measured: this happened on the FIRST `req("shut")` of every single bake run and
never on the second. So the request is not sent, it is sent and **verified by
its echo in the console stream**, and retried when the echo does not appear.

**W3b — `shut` does not shut down; it asks a question.** It answers

```
shutdown: 5 users still on. Do you want to shut down?     M->
```

and waits. The five are the standard SysDaemons — IO.SysDaemon (cord and
prta), Backup.SysDaemon, Utility.SysDaemon and Volume_Dumper.Daemon — which
the answering service logs in at every boot and which are ALWAYS there. This
is the normal path, not an anomaly to be avoided, and `logout * * *`
beforehand does not help. Unanswered, the console prints `CONSOLE: TIMEOUT`
and abandons the request.

Answering it has its own trap: Multics prints the question in the same breath
as the echo of the request, so by the time the echo has been confirmed the
question is ALREADY in the log. An answer routine that starts searching from
"now" never finds it and the console times out. It must search from the mark
the request started at.

Note also that answering a question the console has already prompted for must
NOT send the attention ESC — the ESC would be taken as the answer's first
character. `req()` and `answer()` are therefore different routines.

**W3c — `die` is not a system_control request.** Once `shutdown complete`
prints, the console belongs to BCE, which takes typed lines with no attention
key. Sending `die` through the ESC handshake is what produced
`system_control: Unknown request "die"` in the very first attempt. In practice
the simulator does not exit on `die` under a pty either, which is cosmetic:
`shutdown complete` is Multics' own statement that the RPV has been flushed,
so that line — not the process exit — is the gate, and the bake SIGKILLs
afterwards.

### W4 — the exhibit cannot use stock telnet

Not a wall at the pause because the wave never reached a framebuffer. Stock
`telnet -E` opens the scene on `Trying 127.0.0.1...` and the FNP's 32-entry
`HSLA Port (d.h000,...,d.h031)?` channel menu — a third of an 80x24 screen of
plumbing (measured: 14553 lit px against 5554 for the finished scene). Worse,
a visitor who types `logout` — which is in this station's own type-in demo —
gets `Multics has disconnected you` and a DEAD TERMINAL that every later
visitor inherits.

`stations/multics/multics-term.pl` replaces it: answers the channel menu
without showing it, prints no connection chrome, and reconnects at a fresh
banner on hangup. Perl because the container rootfs is a debootstrap minbase
with no python3, but perl 5.40 arrives with the base packages. Measured over
five logout cycles the FNP reuses its channel (d.h000 fresh, d.h001 after a
reconnect) rather than climbing toward its limit.

## Design decided (not yet built)

- **Containment** per the lane contract, copied from medley's proven shape:
  `systemd-nspawn --as-pid2 --private-users=2031616:65536 --private-network
  --volatile=overlay`, assets read-only, one writable `work/`, `~@mount`
  filtered, Xvfb INSIDE the container, host sees `/tmp/.X11-unix/X108` as a
  symlink into `/run/streamhost/x11/multics`.
- **Visitor surface**: `xterm` on `:108` running a small telnet-aware bridge
  rather than stock `telnet`, so the wave gets three things stock telnet cannot:
  the `HSLA Port (...)` prompt is answered and suppressed (the rest scene is the
  Multics login banner, never the FNP's channel menu), NUL padding is stripped,
  and a hangup reconnects to a fresh login instead of leaving a dead terminal.
  The FNP negotiates `WILL SGA/ECHO/BINARY` and Multics echoes, so the bridge is
  raw character-at-a-time with IAC refusal — ~60 lines, measured from the byte
  dump in §"What is proven" item 2.
- **Golden**: no checkpoint. The immutable asset is a `root.dsk` baked ONCE
  (password changed away from the forced-change state, Multics shut down
  cleanly through `logout * * *` / `shut` / `die`), reflink-copied into `work/`
  on every launch. Reset = kill the container tree, re-copy, relaunch.
- **Rest scene**: the Multics login banner on channel `d.h000`, terminal filling
  the frame, no simulator console and no host shell.
- `mame.pid` = the host-visible `dps8` pid (idle freezer + reap-by-exe, as
  medley does with maiko); `nspawn.pid` = the supervisor.

## What the framebuffer proved (2026-09-20, display :117)

The pause recorded everything as byte-level and explicitly not as a claim about
pixels. All of it is now pixels.

| Proof | Result |
|---|---|
| Rest scene | Banner + `Load = 5.0 out of 90.0 units` + cursor, 5554 lit px, nothing else |
| Keys reach the guest | `login Repair` → `Password:`; `multics` → `You are protected from preemption.` and `r 05:17 0.660 19` |
| Commands | `who` → `6 users, 1 interactive, 5 daemons`; `list`, `date_time`, `help` all work |
| Multics erase `#` | `prinq#t_wd` arrived as `print_wd` |
| Multics kill `@` | `this is rubbish@date_time` ran `date_time` alone |
| ^C | QUIT, and the prompt became `r 05:09 1.707 422 level 2`; `release` discards the level |
| Bridge reconnect | `logout` → fresh banner, five cycles, channel reused not climbed |
| Relaunch reset | `create VISITORWASHERE` → `Segments = 2`; after relaunch `Segments = 1`, seed sha256 unchanged |

Measured timings on a box at load 60–120 (the wave ran alongside three
siblings): answering service **+55.9 s to +85 s** from exec depending on load,
password changed **+88 s**, `shutdown complete` **+133 s**, full relaunch to a
lit banner **2 min 24 s**, of which the 594 MB reflink copy was **1.35 s**.
The pause's 0.126 s figure for that copy was taken on an idle box; 1.35 s is
the loaded number and the design conclusion is unchanged — a pristine copy per
launch is free, so this station has no checkpoint.

## The pre-pause drafts were deleted, not kept

`docs/lab/integration-drafts/multics/` (builder.sh, runtime.sh,
registry-overrides.md) is gone. The lane normally keeps its drafts — vax43bsd
still has its — but these had become actively wrong rather than merely stale:
the draft builder cloned and built dps8m from
`BAN-AI-Multics/dps8m@83d7252b` while the station ships the pinned R3.1.0
linux-64 release binary (`a834c552`), and the draft runtime predated both the
container contract and the bridge. A reader following them would have built a
different simulator than the one the golden RPV was baked against — and a
checkpoint, a binary and a device set are one combination. The real files are
`scripts/build-guests/tiles/multics.sh` and
`streamhost/stations/multics/x11-runtime.sh`.

## One thing the exhibit does not do

`print_wd` is not present in this MR12.8 installation (`Segment print_wd not
found`), so neither the poster nor the demo cites it. Verified commands are
`list`, `who`, `date_time` and `help`.

## Rule 5, paid for again

The resume session killed its OWN labrun shell (exit 144) with a loop that
matched `/proc/<pid>/cmdline` for the bake script's name — the ssh command line
contains that name, so the match found the session's own bash. The only safe
resolution is `/proc/<pid>/exe`, and for this station the fast form is

```
find /proc -mindepth 2 -maxdepth 2 -name exe -lname "<assets>/bin/*" -printf '%h\n'
```

which is what the launcher uses. Killing the simulator alone is enough to end
the bake driver, so no process ever needs to be matched by its command line.
