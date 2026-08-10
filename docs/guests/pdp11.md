# DEC PDP-11/70 + 2.11BSD — gallery tile notes (udp/54115)

**Guest:** a captured **Debian 13 (trixie) x86_64 kiosk** running **Open SIMH's `pdp11`**
simulator as a **DEC PDP-11/70** (22-bit, 4 MB of core, FP11 floating point)
booting **2.11BSD** off an MSCP disk pack, displayed as green phosphor in a
fixed 80×24 `xterm`. An **"emulator bridge"** tile — streamhost captures the
Linux framebuffer exactly like every other bridge tile. See
**`streamhost/docs/BRIDGE.md`**.

**Shared base:** `/data/vms/bridge/bridge-base.qcow2` — does **not** contain
SIMH (see the deviation below).
**Build script (tile):** `scripts/build-guests/tiles/pdp11.sh` — thin overlay + SIMH
build + pack staging + 2.11BSD curation + kiosk `launch.sh` + quiet console +
golden bake + a framebuffer-asserted keyboard proof, fully automated, ~6 min.
**Tile dir (host):** `/data/vms/streamhost/tiles/pdp11/`.
**Registry entry:** `registry/tiles/pdp11.json` (slot 115, udp 54115, VMID 227,
ssh hostfwd 127.0.0.1:5827).

This is the oldest lineage in the collection and the ancestor of most of it:
every Unix tile descends from PDP-11 Unix, C was shaped by this machine's
address space, and `openvms`' VMS was written by the team that had just
finished RSX-11M for the PDP-11.

## The deviation: SIMH is built into the tile overlay

The bridge base is frozen and ships VICE, MAME, cap32, LinApple and FS-UAE — no
SIMH. Debian's packaged `simh` is **3.8.1 built without SDL video** and is
useless here. So, following the `amiga.sh` precedent (which `apt-get install`s
FS-UAE into its own overlay), the builder compiles **Open SIMH from source into
this tile's overlay**, pinned at commit
`a1f57fa3738ed31148d31126ba1a7278ff845c6d` (master, 2026-07-03 — there is no
v4 release tag past v4.0-Beta-1, so the commit is the pin).

Every build dependency is already in the frozen base (`gcc`, `make`, `git`,
`libsdl2-dev`, `libpcre2-dev`, `libpng-dev`, `zlib1g-dev`), so the SIMH build
needs no `apt-get` at all: measured **1 m 32 s at `-j2`** for one 2.68 MB
binary. `libpcap-dev` is **not** needed (SIMH falls back to TAP + SLiRP, which
is enough for 2.11BSD networking should a future tile want it) and
`libvdeplug-dev` is not needed at all.

**`xdotool` IS installed by the builder** (`apt-get install -y xdotool` into the
overlay) — it is the one thing the frozen base lacks that the kiosk cannot do
without; see "the focus trap" below.

### For a from-scratch NVMe rebuild

`scripts/build-guests/lib/bridge-base.sh` should bake both in, so the tile builder
becomes pure configuration:

```bash
apt-get install -y xdotool                       # kiosk window focus (pdp11)
# Open SIMH (pdp11 tile). Deps are already installed for the VICE/MAME builds.
git -c advice.detachedHead=false clone https://github.com/open-simh/simh.git \
  /usr/local/src/simh
git -C /usr/local/src/simh checkout -q a1f57fa3738ed31148d31126ba1a7278ff845c6d
make -C /usr/local/src/simh pdp11 AIO_CCDEFS= -j"$(nproc)"
install -m 755 /usr/local/src/simh/BIN/pdp11 /usr/local/bin/simh-pdp11
```

`AIO_CCDEFS=` is not optional — see trap 3.

## Media and licence — staged, hashed, never committed

| item | value |
|---|---|
| file | `2.11BSD_rq.dsk.zip` → `2.11BSD_rq.dsk` (1 GB MSCP pack) |
| URL | `https://ak6dn.github.io/PDP-11/2.11BSD/2.11BSD_rq.dsk.zip` |
| zip sha256 | `94abeca02f001619e7aa2252cb2336ffe79af0cb3fb35cbd8c14240af3125a6b` (49 850 663 B) |
| dsk sha256 | `2f100ee585f229fd55923e1d1c44108e72df96f649f28a31df35985e6a481805` (1 000 047 616 B) |
| class | **preservation-source** |
| staged at | `/data/vms/streamhost/tiles/pdp11/media/` (host, outside the overlay) |

2.11BSD is a 1991 UC Berkeley release that **predates the Net/2 split**, so it
is *not* covered by the Caldera 2002 Ancient-Unix letter, and this prebuilt
image carries no licence statement of its own. The gallery's posture is
therefore the one it already takes for Kickstart, OS/2 and Win9x media: run it
as a **stream of pixels only**. The bits are never committed to the repo, never
served, and the tile offers no download affordance of any kind.

**DEC media sourcing is fragile.** `simh.trailing-edge.com` — the link in every
2.11BSD howto on the internet, including the one inside this very kit's README
— has been Cloudflare-dead (520/522) since at least 2026-08-09, as have `www.`,
`ftp.` and `mini-me.`. It also has AAAA records and this box has no working
IPv6 egress, so any `curl` at it needs `-4` or it hangs for 40 s before failing.
The surviving routes are `web.archive.org` (raw `/web/<ts>id_/` form, enumerated
through the CDX API), `bitsavers.org`, `retrolib.info`, and Don North's GitHub
Pages mirror, which is what the builder uses. Treat every DEC fetch as one-shot
and stage it on the box; the builder never reaches the network for media once
the staged zip hashes correctly.

## The fixture: 2.11BSD's own `login:`

The golden rests where an **unattended cold boot stops** — at the multiuser
login prompt, with the tail of the boot above it and the machine's own banner
naming the system:

```
Assuming non-networking system ...
standard daemons: update cron accounting.
starting lpd
starting local daemons: sendmail.
Thu Mar 19 00:19:04 PST 2015
March 19 00:19:04 init: kernel security level changed from 0 to 1

2.11 BSD UNIX (pdp11) (console)

login:
```

**Why not a logged-in root shell.** The plus4 lesson applies in the other
direction here. A shell is a state a *human* typed into; it hides that this is
a multiuser timesharing system whose whole point is that it asks who you are;
and it would hand each visitor whatever the last one left running (`vi`, a
`more` pager, a half-typed command). The login prompt is the machine's honest
resting state and the only one a visitor cannot arrive in the middle of.

**What the screen cannot say, and where it is said instead:** the account is
`root` and there is **no password**. That fact lives in the placard
(`registry/posters/pdp11.md`), in `SH_FIXTURE_DESC`, and in the SPA hint. Once
in, `uname -a` prints
`BSD pdp11 2.11 2.11 BSD UNIX #19: Sun Jun 17 16:44:43 PDT 2012
root@pdp11:/usr/src/sys/ZEKE  pdp11`, and `/usr/src` holds the entire 2.11BSD
kernel and userland source tree — which is half the reason to run this machine
rather than V6.

The build proves that route by framebuffer *after* the bake, against the
restored fixture, so nothing it types can reach the golden:
`evidence/keyboard-root-shell.png`.

## What was curated on the pack, and why

The prebuilt pack is configured for a machine with a DZ11 eight-line terminal
mux and a DEUNA Ethernet board. This 11/70 has neither, so out of the box the
console was overprinted with seven `getty: /dev/tty0N: Device not configured`
lines *on top of the login prompt*, `ifconfig: ioctl (SIOCGIFFLAGS): no such
interface`, `add net default: … Network is unreachable`, two `lpd: unable to get
hostname for remote machine printer`, and — every 60 seconds, for ever —
`ntpd: sendto: 192.168.1.21 Network is unreachable`. A console that reprints an
error a minute is not an exhibit.

Four edits, all of them ordinary 2.11BSD site configuration for the hardware
actually present, applied by a scripted in-guest session at build time:

| file | change | effect |
|---|---|---|
| `/etc/ttys` | `tty00`–`tty07` `on` → `off` | no DZ11: those lines do not exist |
| `/etc/dtab` | `dz`, `rx`, `tms`, `cn` commented | removes four `skipped: No CSR.` lines from the boot |
| `/etc/netstart` | `INET=`\``testnet`\` → `INET=NO` | "Assuming non-networking system …"; also drops inetd/rwhod/remote lpd |
| `/etc/rc.local` | `ntpd` → `#ntpd` | stops the recurring spam |

Nothing else is touched. `/usr/src` is untouched, the kernel is the stock
`#19` ZEKE build, and the patch level is the kit's own (PL448).

## Traps this tile paid for

1. **`set cpu 11/70` rejects the two lines every 11/44 recipe opens with.**
   `nocis` → `%SIM-ERROR: The CIS option can't be disabled on a 11/70 CPU`;
   `set rha disabled` → `Command not allowed`. The widely-copied ak6dn
   `cpu1144.ini` fails on exactly those.
2. **SIMH's console emits LF-then-CR with 0x7f padding** (`\n\r\x7f`), not
   CRLF. Every expect regex written `\r\n` silently never matches. And SIMH's
   own `EXPECT`/`SEND` did not fire against 2.11BSD's boot block at all, so the
   boot dialogue is walked by a forkpty driver instead
   (`/opt/pdp11/pdp11-console.py`, emitted by the builder).
3. **The async-I/O build deadlocks across `loadvm`.** SIMH's makefile
   auto-detects libpthread and compiles `-DSIM_ASYNCH_IO -DUSE_READER_THREAD`.
   After restoring a snapshot, both simulator threads sit in `futex_wait`
   burning **0 CPU ticks per 20 s** and every keystroke vanishes — while the
   exhibit looks perfectly healthy: right framebuffer, live `xterm`, correct X
   focus, QEMU's i8042 interrupt counter still ticking. Build with
   `make pdp11 AIO_CCDEFS=` (a command-line variable overrides every `+=` in
   the makefile); the builder asserts the running simulator has exactly one
   thread, because a rebuilt-with-defaults binary passes every other check.
4. **`set cpu idle` costs the exhibit its reset.** It is the standard answer to
   SIMH burning a whole core and it works beautifully — until a `savevm`/
   `loadvm` cycle destroys the calibrated timer it rides on, permanently.
   Measured on this tile against a 120 s-old snapshot:

   | ini | echo latency after `loadvm` | CPU at an idle login prompt |
   |---|---|---|
   | `set cpu idle` | never echoed (38–80 s+, no recovery over 3 rounds) | 2.4 % |
   | nothing | 0.5 s | 100.1 % |
   | `set throttle 1200k` (≈ a real 11/70) | 0.5 s | 59.0 % |
   | **`set throttle 10%`** (shipped) | **0.5 s** | **19.7 %** |
   | `set throttle 5%` | 0.4 s | 7.9 % (visibly sluggish: `ls -l /usr/src` ≈ 6 s) |

   `set timer nocatchup` ships alongside it, to stop SIMH trying to make up the
   simulated clock ticks it thinks it owes for the wall-clock gap the restore
   invents. **This is the tile's one real compromise:** a fifth of a host core,
   for ever, to keep reset instant. If SIMH ever survives a snapshot with its
   calibration intact, put `set cpu idle` back and take 2.4 %.
5. **The focus trap.** There is no window manager, so X's focus is
   `PointerRoot` — keystrokes go to whatever window the *core pointer* is over,
   and this guest parks it at (0,0), outside a centred 80×24 window. Every
   keystroke was swallowed by the root window while everything looked healthy.
   The launcher therefore backgrounds a small waiter that `xdotool mousemove`s
   into the terminal and sets the focus explicitly once the window has mapped.
6. **`xterm -fs` is POINTS at ~96 dpi, not pixels.** `-fs 21` measured 17.4 px
   per column — an 80-column window 1392 px wide whose right-hand end fell off
   the 1024 px root. `-fs 15` measures 12.05 px/column and 24.0 px/row → 964×576,
   centred by `+30+96`. Re-measure on the framebuffer if the font changes.
7. **The kiosk runs as `bridge`, not root.** A root-owned 0644 pack attaches
   read-only and 2.11BSD panics with `ra0a: hard error sn36 status 20006` and a
   kernel dump the first time it writes `/etc/utmp`. The builder chowns the
   pack. (The identical panic also appears when two simulators share one pack —
   which is how the forkpty driver came to kill its whole process group: it puts
   the simulator in its own session so a visitor's `^C` reaches 2.11BSD as a
   byte, and that same `setsid` orphans it if the driver is signalled.)

## Key pacing: there is none, and that is measured

Playbook §5.1's frame-sampling trap is about emulators that scan a keyboard
matrix once per emulated frame. SIMH has no such matrix: its console is a byte
stream on a pty, and a 69-character line written to it at a **0 ms**
inter-character gap echoed and executed intact **5 times out of 5**. What
remains is the ordinary bridge path — browser → streamhost → QEMU PS/2 → X →
`xterm` → pty — and **40 ms hold / 40 ms gap** through QMP delivered `root`,
`uname -a` and `ls /usr/src` losing nothing. The tile therefore ships 40/40
rather than vic20/plus4's 80/80.

The keys a visitor needs that a modern keyboard hides are 2.11BSD's own, and the
machine prints them itself at every login: `erase, kill ^U, intr ^C` (and `^D`
to log out).

## Device set and launcher

`streamhost/tiles/pdp11/qemu-streamhost.sh`, identical in shape to its bridge
siblings but with **512 MB** instead of 1536:

| RAM | guest MemTotal | guest MemAvailable at the login prompt | host QEMU RSS |
|---|---|---|---|
| 768 MB | 725 MB | 408 MB | 859 MB |
| **512 MB** (shipped) | **468 MB** | **337 MB** | **591 MB** |

The simulated PDP-11 is 4 MB of core and the simulator's RSS is 21 MB, so this
is comfortably the cheapest guest in the collection by memory. The AC97 card
stays in the device set because the golden was baked with it; the exhibit itself
is **silent** — a console terminal has nothing to say.

The kiosk launcher is:

```
xsetroot -solid black
( wait for the window; xdotool mousemove 512 384; xdotool windowfocus ) &
exec xterm -geometry 80x24+30+96 -fa 'DejaVu Sans Mono' -fs 15 \
  -bg '#000000' -fg '#33ff33' -cr '#33ff33' -b 0 -bw 0 +sb -sl 512 \
  -e /usr/bin/env PDP11_LOG=/tmp/pdp11-console.log /opt/pdp11/pdp11-console.py
```

and the SIMH configuration is `/opt/pdp11/pdp11.ini`:

```
set cpu 11/70 4096K fpp
set throttle 10%
set timer nocatchup
set ptr/ptp/lpt/cr/rp/rk/rl/rx/ry/tm/ts/tq/hk/vh/dz/xu/xq disabled   (one per line)
set tto 7b
set rq enabled
set rq0 RAUSER=1000
attach rq0 media/2.11BSD_rq.dsk
boot rq0
```

**80×24 is deliberate.** `/etc/ttys` gives the console `vt100` and 2.11BSD
cannot learn otherwise over a DL11 serial line, so a taller window would leave
`vi(1)` painting only its top 24 rows. The consequence is that the first ~15
lines of the boot (including the `2.11 BSD UNIX #19` kernel banner) scroll off
the top — exactly as they did on real glass. A visitor who wants the banner
types `uname -a`.

## Golden, reset and rollback

- `SH_RESET_MODE=loadvm`, snapshot `golden`, inside `overlay.qcow2`. **Never
  delete or recreate `overlay.qcow2`** — the golden *and* the 2.11BSD pack live
  inside it. The device set must match the bake exactly.
- Re-bake with `scripts/build-guests/tiles/pdp11.sh --force` (stops only this tile,
  refuses to run while `streamhost@pdp11` is active, re-uses the staged and
  hashed media).
- Rollback: `systemctl stop streamhost@pdp11` — see the tile's `ROLLBACK.md`.
- Verified reset on the live tile against a golden 15 minutes old: `loadvm
  golden` → first keystroke echoed in **0.8 s** → `root` / `uname -a` /
  `ls /usr/src` all correct (`evidence/post-reset-root-shell.png`), then a
  second `loadvm golden` restored the fixture frame byte-for-byte.
- Credentials reference only (never values): `guest/pdp11`. The guest account is
  the 2.11BSD `root` with an empty password, which is a property of the
  preserved 1991 image and is deliberately public on the placard.

## Evidence

`/data/vms/streamhost/tiles/pdp11/evidence/`

| file | what it shows |
|---|---|
| `cold-boot-login.png` | the first unattended cold boot of the provisioned overlay reaching `login:` |
| `ready-before-golden.png` | the clean cold boot the golden was baked from |
| `golden-frame.png` | the exact frame `savevm golden` captured |
| `golden-restored.png` | the same frame after `loadvm golden` |
| `keyboard-root-shell.png` | root (no password) → `uname -a` → `ls /usr/src`, typed through the PS/2 path after the bake |
| `golden-restored-after-keyboard.png` | the fixture restored again, proving the proof left no trace |
| `post-reset-root-shell.png` | the same route on the LIVE tile against a 15-minute-old golden |
| `golden-restored-final.png` | the live tile back at the fixture |
| `live-tile-resumed.png` | the running `streamhost@pdp11` tile after idle auto-pause resumed it |
