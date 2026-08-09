# IRIX serial exec agent (`irixser/2`)

> **STATUS: built and verified on a clone, NOT cut over.** The live tile still
> runs the golden without the agent and `registry/tiles/irix.json` still has
> `exec_kind: null`, so `labctl exec irix` errors out exactly as it did before.
> The cutover — new launcher, new golden, registry flip, `labctl gen` — is a
> human step, written out in `../../../docs/guests/irix.md`. Everything below
> describes what happens *after* it.

Gives the SGI IRIX 6.5 tile what the ssh and bridge tiles already have:

```
$ ssh lab 'labctl exec irix "hinv | head -3"'     # after the cutover
CPU: MIPS R4600 Processor Chip Rev 2.0
FPU: MIPS R4600 Floating Point Cop Rev 2.0
1 100 MHZ IP22 Processor
$ ssh lab 'labctl exec irix "false"'; echo $?
1
```

Real captured stdout+stderr and the guest's own exit code — not a blind
`labctl sh`, and not pixel-hunting the 4Dwm Toolchest. It exists because
driving this exhibit by pointer coordinates is slow and fragile, and because
launching a demo, reproducing a panic or capturing `hinv` should be one
command.

## Pieces

| file | lives | role |
|------|-------|------|
| `irixagent.pl` | guest `/usr/local/bin/irixagent.pl` | the agent. Perl 5.004 + POSIX::Termios, owns `/dev/ttyd2` |
| `irixagent.sh` | guest `/usr/local/bin/irixagent.sh` | wrapper started by an `/etc/inittab` respawn entry |
| `irixexec.py` | box `/root/irixexec.py` | host client. `labctl exec irix` shells out to it |
| `../../tiles/irix/x11-runtime.sh` | box tile dir | adds `-ioc2:rs232a pty` and publishes the pty in `serial.pts` |
| `../../../scripts/build-guests/irix/irix-serial-rig.sh` | repo | boot / exec / shot / halt a namespaced clone with the channel wired |
| `../../../scripts/build-guests/irix/irix-serial-install.sh` | repo | bake the agent into a golden, over the guest's own console |
| `../../../scripts/build-guests/irix/irix-serial-selftest.py` | repo | the acceptance suite: real agent + real client over ptys, with a corrupting relay |

## The wire

```
labctl exec irix "<cmd>"
  -> /root/irixexec.py  <tile-dir> "<cmd>"        irixser/2, escaped ASCII lines
  -> /dev/pts/N         (MAME -ioc2:rs232a pty, scraped from MAME's fd table)
  -> emulated SCC85230  (indy_4610 ioc2, 9600 8N1)
  -> guest /dev/ttyd2   (physical serial port 2 — `t2` in /etc/inittab is `off`,
                         so nothing else has ever wanted it)
  -> irixagent.pl
```

`ioc2:rs232b` is IRIX `/dev/ttyd1`, where `/etc/inittab`'s `t1` respawns a
console getty. Production leaves that slot **unpopulated**, exactly as the
exhibit shipped before this change. The bake rig populates it (`--console`) and
uses it once, to type the agent in.

Three findings decide the shape of all of this, and each was measured:

* **`socket.` cannot be used.** MAME's socket bitbanger closes its listener
  after the first `accept()` and never re-accepts, so a one-shot exec client
  would work exactly once per MAME run. The `pty` endpoint has no accept
  semantics: the host opens the slave as often as it likes. MAME never prints
  the slave's name (`dipty.cpp` only stores it), so it is scraped out of
  `/proc/<mame>/fd` + `fdinfo` — authoritative across relaunches, unlike the
  `serial.pts` file the launcher writes for convenience.
* **A fresh pts defaults to ECHO ON**, which bounces every byte the guest sends
  straight back into the guest. Both the launcher and the client put the slave
  in raw `-echo`.
* **MAME's SCC drops transmitted bytes.** See PACING below.

## Protocol

Line-oriented, LF-terminated, printable 7-bit ASCII in both directions. Every
payload is escaped — `\` → `\\`, LF → `\n`, CR → `\r`, anything else outside
`0x20..0x7e` → `\xHH` — so no framing byte can occur inside one, and text costs
~1.0x (base64 would cost 33% more on a wire that runs at a few hundred bytes a
second, and IRIX has no base64 anyway).

Every line, in **both** directions, is `<id> <verb> <sum> <payload>`, where
`<sum>` is a 4-hex-digit additive 16-bit checksum of `"<id> <verb> <payload>"` —
the whole line with the sum taken out.

```
host -> guest   <id> PING  <sum>
                <id> RUN   <sum> <opts> <esc-cmd>  opts: t=secs,o=bytes,p=idle|fast,d=1
                <id> ABORT <sum> <target-id>
                <id> RESULT <sum> <target-id>
guest -> host   <id> P <sum> irixser/2 <version> <src-sum>
                <id> O <sum> <esc-chunk>           0..N, <= 512 raw bytes each
                <id> T <sum> <dropped> <esc-path>  output was capped
                <id> X <sum> <status>              terminal
                <id> E <sum> <esc-message>         terminal
                <id> N <sum> <esc-message>         NAK — not run, resend the line
```

### What `/2` changed, and why

`irixser/1` checksummed the *payload of replies only*. Four consequences, all
reproduced (`irix-serial-selftest.py`, which fails on `/1` and passes on `/2`):

* **The framing was outside the checksum.** A dropped digit in the id or a
  flipped verb byte on the terminal `X` line was simply dropped by the client,
  which then waited out its whole deadline and exited 124 — on a command that
  had completed. The operator's next move is to re-run it. Now the framing is
  inside the sum, so that corruption lands on the replay path it was designed
  for.
* **The replay was indistinguishable from the original.** `RESULT` replayed
  under the ORIGINAL id, and the agent is single-threaded, so it did not even
  read the `RESULT` until the reply being replaced had finished going out. The
  client appended the tail of the original, hit the original `X`, and returned
  TRUNCATED output with a SUCCESS status — the one failure this channel must not
  have. A replay now goes out under the requester's id.
* **Requests had no integrity check at all.** A dropped byte in the command text
  ran a DIFFERENT command and reported success (`rm` and `shutdown` go through
  this channel). Now a request that does not verify is answered `N` and NOT run;
  the client re-sends the identical line. Re-sending is safe because a `RUN` is
  **idempotent in its id**: a `RUN` whose id and command checksum match the last
  completed one is replayed, never re-run.
* **Guest bytes >= 0x80 were transcoded.** The client decoded latin-1 and let
  stdout re-encode to UTF-8, so every high byte became two. It now writes bytes.

`<status>`: 0..255 = the command's exit code, 256+N = killed by signal N,
257 = timed out, 258 = aborted. The client maps those to its own exit status
(128+N, 124, 124).

**Resynchronisation is the id.** Every reply line carries the id it answers, so
the tail of a command a previous client gave up on is unambiguous garbage the
next client drops. Each run picks a fresh id, drains the line, PINGs, and reads
until its own id answers before it sends anything real.

The agent remembers the last completed RUN, so a client that reads a bad line
can ask for the whole reply again:

```
<id2> RESULT <id>     ->  the O/T/X lines of <id>, replayed under <id2>
```

Re-fetching, never re-running: the commands this channel exists for are not all
idempotent. The checksum earned its place — an `X 265` was seen arriving as
`X 3,5`, and it is what turned "the output looks wrong sometimes" into a
reproducible signal.

**That `X 3,5` has a second, worse cause than the two agents it was first blamed
on.** It came back on a clone with exactly one agent, ~1 run in 5 of a
signal-killed command — and the checksum on the garbled line was *correct for
the garbled text*. Only the agent can produce that, so this perl (5.004, IRIX
n32) sometimes renders the integer 265 as the string `3,5`, and no wire-level
integrity check can ever see it. Two things now stand against it: `do_run`
forces the status through `sprintf("%d", ...)` once (20/20 and 10/10 clean
afterwards, against 8/10 before), and the client treats a checksum-clean reply it
cannot parse exactly like a bad checksum — replay, never re-run. If you touch
this code, do not "simplify" that sprintf away.

**One agent, or none.** Two agents on one line is not a degraded mode, it is an
unreadable one — both write to `/dev/ttyd2` and their 4-byte paced writes
interleave into something that looks exactly like wire corruption. It happened:
an install that killed the wrapper but not the perl left init respawning a
second one. The agent now holds an **`flock`** on `/var/tmp/irixagent.lock` for
its whole life and a second instance declines to start (sleeping 60 s first, so
init does not disable the respawn entry for restarting too fast). Not a pid
lock: writing the pid is not atomic (a lock reading `/70` for pid 970 was
observed), and `kill(0,$pid)` only asks whether *some* process has that pid —
the agent's boot pid is deterministic on this golden, so a pid lock that ever
survived into a baked image would make every future agent decline for ever,
silently. The kernel drops an `flock` however the holder dies. The installer stops the old
agent by removing the inittab entry first, running `telinit q`, and only THEN
killing what is left — `telinit q` has been seen leaving the old agent alive as
an orphan of init — and it asserts afterwards that exactly one is running. The
order is the whole point: kill before the respawn entry is gone and init starts a
second one immediately. And never `/sbin/killall`, which on SysV is the shutdown
helper and signals every process on the machine.

The installer also does **not** delete `/var/tmp/irixagent.lock`. Unlinking a
lock file does not release the `flock` the running agent holds on that inode; it
only guarantees the next agent locks a fresh file and starts anyway. That is
exactly how a re-install was caught running two agents at once.

**A payload's leading and trailing spaces are data.** Parse with a single-space
split and never with a whitespace-collapsing one; `.strip()` on a received line
silently ate four bytes out of `/etc/inittab` before this was fixed, in a
transfer that was otherwise byte-exact.

**Single consumer.** Two clients interleaving bytes on one serial line would be
unrecoverable, so every run takes an exclusive `flock` on
`<tile-dir>/serial.lock`.

**A broken agent is silent, by design and not by accident.** `irixagent.sh`
sleeps 30 s on a missing device or script and 5 s after the perl exits, purely so
SysV init does not disable the respawn entry ("Command is respawning too
rapidly") — which means a persistently failing agent loops for the life of the
tile with nothing visible: the framebuffer is byte-identical to a healthy tile,
and `/var/tmp/irixagent.log` is *inside* the guest, i.e. unreachable exactly when
you need it. The cost is small (50 perl startups measured 0.58 s of guest CPU),
but the only symptom you will get is `labctl exec irix` failing. If it does,
suspect the agent before the wire, and read the log from a clone of the golden.

## Pacing — why this wire is slow

MAME's `SCC85230` signals "transmitter empty" long before the byte has left, so
IRIX's `sduart` driver overruns the emulated 4-byte TX FIFO and bytes are
**silently dropped**. Measured on `indy_4610` against this golden, 1200-byte
patterns:

| bytes per write | delay after | received |
|---|---|---|
| 4 | >= one `select()` | 1200/1200 |
| 4 | none | 620/1200 |
| 8 | 10 ms | 904/1200 |
| 16 | 30 ms | 756/1200 |

It is the write SIZE that matters, not the byte rate. So the agent writes at
most 4 bytes at a time and pauses. IRIX's clock tick makes any `select()` cost
~20 ms whatever timeout is asked for, which is why a calibrated busy-loop is
*faster* than sleeping:

| profile | throughput | cost |
|---|---|---|
| `p=idle` (default) | ~139 B/s | the agent sleeps — no emulated CPU |
| `p=fast` (`--fast`) | ~267 B/s | 100% of one guest CPU while transmitting |

Measured end to end: `cat /etc/inittab` (8263 bytes) in 59 s idle, 31 s fast,
byte-identical both ways. The exhibit is CPU-bound and every cycle is visible to
a visitor, so `idle` is the default; ask for `--fast` when you want bulk.

Output is capped (`--outmax`, default 4096 bytes) and the remainder is left in
the guest at `/var/tmp/irixexec-<id>.out`, whose path comes back on the `T`
line. For anything big, redirect in the guest and page it — do not stream it.

The ceiling here is MAME's SCC, not the design. A fix in
`src/devices/machine/z80scc.cpp` (assert TX-buffer-empty when the byte actually
leaves, not when it is accepted) would remove the pacing entirely and take this
to the full 960 B/s of a 9600-baud line. That is a separate change with its own
binary cutover.

## Long-running commands

`--detach` starts the command in its own session with stdin `/dev/null` and
output to a guest file, and returns immediately with the pid. Use it for
anything that does not exit — Netscape, a demo, `init 0`.

Even without it, a child never inherits the serial line: stdout and stderr go to
a **file**, never a pipe. A pipe is the obvious choice and is the wrong one — a
backgrounded grandchild holds the write end open and the read never returns,
which wedges the whole channel. (That is exactly how an `xterm &` wedged the
proof-of-concept.)

Host timeouts are enforced by ABORT, not by hanging up: the client tells the
agent to kill the process group and waits for the `X` line before it lets go of
the lock, so the next client finds a quiet line. The agent reads the line
**between output chunks**, so an ABORT lands even in the middle of a reply — in
`/1` it was not looked at until the whole capped output had been paced out, and
a timed-out 16 KB reply blocked every later client for ~2 minutes behind the
backlog.

A reply that is still *arriving* keeps the client alive past `--timeout`: the
cap counts raw guest bytes, escaping can quadruple them on the wire, and this
wire does ~140 B/s. `--timeout` bounds the COMMAND; 60 s of silence
(`IRIXEXEC_TRANSFER_GRACE`) bounds the transfer.

## X11 (launching demos)

The agent sets `DISPLAY=:0` and `XAUTHORITY=/.Xauthority` for every command.
That works **once someone is logged in**. At the `iconlogin` chooser the tile
ships (no visitor session yet) xdm holds the server grabbed and X clients block
until a login completes — a `--timeout` turns that into a clean 124 rather than
a wedge. Log in first (the browser, or the key-matrix channel), then launch.

## Verifying — the acceptance suite

```
scripts/build-guests/irix/irix-serial-selftest.py         # ~40 s, needs only perl
```

It runs the real `irixagent.pl` and the real `irixexec.py` against each other
over a pair of ptys with a relay in the middle that corrupts one chosen line, so
the four corruption cases above are produced on demand instead of waited for.
It cannot cover IRIX's perl 5.004 or MAME's SCC — those still need a booted
clone — but everything else is seconds instead of a 4.5-minute cold boot per
attempt.

**Which agent is the guest actually running?** The PING reply carries a checksum
of the agent's own source as the guest has it:

```
python3 /root/irixexec.py <tile-dir> --ping \
    --agent-src streamhost/guest-agents/irix/irixagent.pl    # exit 126 on drift
```

Nothing else in the tree can see inside the golden, and the repo file changing
does NOT change the exhibit — only a re-bake does.

## Installing / re-baking

```
ssh lab '/data/vms/.../irix-serial-rig.sh boot bake1 --console --display 171'
ssh lab '/data/vms/.../irix-serial-install.sh bake1'
ssh lab '/data/vms/.../irix-serial-rig.sh exec bake1 "uname -a"'
ssh lab '/data/vms/.../irix-serial-rig.sh halt bake1'
# -> /data/vms/soltest/irix-serial/bake1/disk.chd is the new golden
```

The installer types the agent into the guest through the console getty's own
here-document and then verifies every byte with `cksum` on both sides. It
assumes a virgin `login:` prompt: `login(1)` flushes typeahead before reading a
password and asks for one after any failed attempt, so a stray line ahead of the
username costs the whole sequence. `IRIX_INSTALL_SKIP_LOGIN=1` re-pushes into a
console that is already at a quiet shell (the agent-development loop). The last
thing it prints is the baked agent's source checksum — record it in
`../../../docs/guests/irix.md` next to the golden's md5.

`/etc/inittab` gets one line, and the previous file is kept as
`/etc/inittab.preagent`:

```
ia:23:respawn:/usr/local/bin/irixagent.sh </dev/null >/dev/null 2>&1
```

inittab and not `/etc/rc2.d`: init supervises and restarts the agent, a change
applies with `/etc/telinit q` instead of a 4.5-minute cold boot, and it sidesteps
rc2's orphan hazard (`/etc/rc2` feeds EVERY non-empty `/etc/rc2.d/S*` to
`/sbin/sh`, editor backups included — the `S77sysevent.989` trap).

## Related

Same family, different transports: `../win311`, `../os2`, `../templeos`
(pointer-only over COM1) and `../solaris` (the `E` verb over TCP, whose reply
framing this protocol is a hardened descendant of). Guest notes:
`../../../docs/guests/irix.md`.
