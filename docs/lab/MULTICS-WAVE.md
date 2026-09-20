# Multics MR12.8 — station wave (record wave, Lane B)

Tracking: #51 · prep branch `multics` · work branch `multics-work` ·
seed [`integration-seeds/multics.md`](integration-seeds/multics.md) ·
lane contract [`record-wave/HOST-APP-CONTAINER-CONTRACT.md`](record-wave/HOST-APP-CONTAINER-CONTRACT.md)

**STATUS 2026-09-20T09:35Z: PAUSED by the wave coordinator** (labhost 1-min load
116 against the documented cap of 50 — not a station failure). Nothing is live,
nothing is enabled, nothing of this wave is running on the box. Resume from
§"Next concrete step".

## Allocation ledger

| Station | Session | Slot / UDP / VMID | X display | X-warp | retronet |
|---|---|---|---|---|---|
| multics | multics-work | 208 / 54208 / 208 | `:108` | — | — |

Neither `--retronet` nor `--x11warp` was taken: the visitor surface is an X
terminal captured with `SH_CAPTURE=x11` + XTEST (the medley route), and the
guest has no network of its own — the FNP telnet line is loopback INSIDE the
container.

Container uid base: **2031616** (31·65536; medley holds 30·65536 = 1966080).

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

## Two walls, both diagnosed, both shared-lane

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

### W3 — the operator console drops characters typed with the ESC

`\033shut\r` in one write is swallowed: the ESC takes the console, prints
`M-> `, and the request text that arrived in the same breath is gone
(`CONSOLE: RELEASED`, then later `system_control: Unknown request "die"`).
The working shape is ESC → **wait for a NEW `M-> ` in the console stream** →
settle → send the request. Half-implemented at the pause
(`req()` in the bake driver); this is the one unproven step of the bake.

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

## Next concrete step (resume here)

1. Finish W3: `req()` = ESC → wait for a new `M-> ` → settle → request. Then
   re-run the bake from the pristine QuickStart and confirm `shutdown complete`
   followed by a clean `die` / `y` exit; that `root.dsk` becomes the immutable
   asset.
2. Write `streamhost/stations/multics/{x11-runtime.sh,nspawn-inner.sh,
   multics-term.py}` from the medley launcher (the scaffold currently holds
   medley's copies, unedited) and `scripts/build-guests/tiles/multics.sh` from
   the measured hashes above.
3. Smoke it on display `:108` in the sandbox and **take the first framebuffer** —
   that is the proof this wave does not yet have.
4. `scripts/dev/smoke-rig.sh multics --like medley`, then the input/reset proofs
   and the on-screen control keys (Multics needs a real BREAK/interrupt key and
   `#`/`@` as its erase/kill characters — they must be on the SPA keyboard, not
   behind a host shortcut).

## Teardown at the pause

Every `dps8` was killed by `/proc/<pid>/exe` match (never `pkill -f`, AGENTS.md
rule 5); the sweep printed no survivors. No smoke rig was ever published, no
station was enabled (`registry/stations/multics.json` is
`lifecycle: candidate`, `enabled: false`), and no fleet file was deployed.
