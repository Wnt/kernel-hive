# IRIX exec channel for the **Iris** tile (`indyr4400`)

> **STATUS: works, verified live — but NOT durable and NOT wired.** The copy
> that lived in the kiosk at `/root/iexec.py` was **never in the golden**: a
> `systemctl restart` (which starts with `-loadvm golden`) deleted it, measured
> 2026-08-10. `registry/tiles/indyr4400.json` still describes exec as reaching
> the Debian kiosk only. Until the cutover below, this file **is** the agent —
> it must be pushed into the kiosk each time.

Not to be confused with [`../irix/`](../irix/), which is the same idea for the
**MAME** tile (`irix`) over a `-ioc2:rs232a pty`. Different tile, different
emulator, different transport. Both give IRIX 6.5 a real exec channel; neither
is cut over.

## What it is

`indyr4400` runs the [Iris](https://github.com/) SGI Indy emulator inside a
Debian bridge kiosk. Its matrix entry says the Indy "is driven only through the
framebuffer + PS/2" — pointer coordinates and typed keys, no captured output.

That turns out not to be true. **Iris exposes the emulated Indy's two SCC
serial ports as plain telnet listeners on `127.0.0.1:8880` and `:8881` inside
the kiosk, and IRIX runs a getty on `:8881`.** That is a real login shell. No
PROM `eaddr` fix, no guest networking, no framebuffer typing.

So the channel is **two hops**:

```
host  --ssh root@127.0.0.1:5839 (bridge_key)-->  Debian kiosk
kiosk --telnet 127.0.0.1:8881 ---------------->  IRIX 6.5 getty
```

Hop one already exists and is what `labctl exec indyr4400` does today. `iexec.py`
is hop two, and runs **in the kiosk**.

## Using it today

Push it in, then call it. Both hops in one command:

```bash
# once per tile start (the kiosk copy does not survive a reset)
scp -P 5839 -i /data/vms/bridge/bridge_key iexec.py root@127.0.0.1:/root/

ssh lab 'labctl exec indyr4400 "python3 /root/iexec.py \"uname -a\""'
# IRIX IRIS 6.5 10070055 IP22        <- real stdout, exit 0

ssh lab 'labctl exec indyr4400 "python3 /root/iexec.py --put /tmp/x /tmp/x"'
```

The guest's exit code propagates, so a failing IRIX command fails your command.

## The traps it already handles

Each of these cost a debugging round; they are why the file is not fifteen lines.

- **Root's login shell is `csh`.** `$?` there is `Variable syntax`, so the
  marker protocol cannot work. It `exec /bin/sh`s — but that is *racy right
  after login* because csh is still sourcing `.cshrc` and swallows the line, so
  it **probes and retries** rather than sleeping a fixed amount.
- **The tty echoes the command line**, so both fence markers appear once in the
  echo *before* any real output. It anchors on the **last** begin marker.
- **Telnet option negotiation** is answered (`DONT`/`WONT`) so the far end stops
  asking and the stream stops carrying `IAC` bytes into your output.
- **The serial line is lossy if pushed too hard**, so `--put` uses a quoted
  here-doc (nothing is shell-interpreted) and verifies with `wc -c`.

## The traps it does NOT handle — read these

- **Not durable.** See the status banner. `loadvm golden` reverts the guest disk
  along with RAM, and this file is not in the golden.
- **One client at a time.** Port 8881 is a single serial port. A background
  poller holding it **silently starves** everything else — no error, just
  timeouts. This is the shared-global failure class from `AGENTS.md`.
- **An in-place QMP `loadvm` leaves the getty unresponsive.** A fresh
  `systemctl restart streamhost@indyr4400` is fine. So `labctl reset` is *not*
  sufficient to get a working channel back.

## What a cutover would take

Deliberately not done here, because `labctl exec indyr4400` **currently means
"the Debian kiosk"** and other things rely on that. Changing what it means is a
behaviour change on a live exhibit, and the matrix is generated — never
hand-edited. Roughly:

1. Bake `iexec.py` into the kiosk overlay from the tile builder (the repo-native
   fix — it makes the agent part of the image instead of a hand-push), then
   re-bake the golden.
2. Decide the verb. Either a new `exec_kind` that routes into IRIX, or keep
   `labctl exec` on the kiosk and add a separate one for the Indy. The sibling
   MAME tile uses `exec_kind: serial_e`, which is the closer precedent.
3. Update `registry/tiles/indyr4400.json`, `make station-registry-generate`,
   `labctl gen`, and fix the matrix `notes` — they still assert the Indy is
   reachable only by framebuffer + PS/2.
