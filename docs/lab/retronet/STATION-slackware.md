# slackware on the retronet — the bridge, Arena, micq, and a guest that builds its own client

**Status: BAKED, not yet landed.** `slackware` (Slackware 3.4, October 1997 —
Linux 2.0.30, XFree86 3.3.1, fvwm95) joined both retronet planes on
**2026-09-03**. It is on a real bridged NIC on `vmbr-rn` with a unique MAC,
**statically addressed `10.99.0.31`** with no default route, it browses the
museum corpus in **Arena beta-2b** through the gateway's `:3128` proxy door, and
it is signed in to the gateway as UIN **`18400`** with **micq 0.4.3** over the
**pre-OSCAR UDP 4000** door — the same door `beos` uses. Open the station and the
ICQ window is already there under the terminal, listing HiveBot and beos by name,
with a `web` button in the fvwm95 dock and **Web browser** at the top of the
Start menu.

Three things make this station different from every other one on the plane:

- **It has no browser and no IM client to install.** Slackware 3.4 ships neither
  Netscape nor any ICQ client, and none exists for libc5/1997 that can be
  downloaded ready to run. The browser came out of the distribution's own `xap1`
  series (Arena, W3C's HTML3 testbed, June 1996) and **the IM client was compiled
  inside the guest by its own `gcc 2.7.2.3`** from micq 0.4.3 source. That is not
  a workaround; it is the period-correct answer, and it is why the station now
  ships the `d` series.
- **One NIC does everything.** The station used to run slirp purely so the
  daemon could reach the guest's X server for the absolute pointer. That slirp
  is gone: the same `ne2k_isa` is now a bridge port, and the pointer, the web,
  ICQ and a brand-new exec channel all ride it.
- **It gained an exec channel it never had.** `inetd` + `in.telnetd` were already
  on the disk (the `tcpip` package); enabling them cost three lines in
  `compose.sh` and gives `labctl exec slackware` on the shared `telnet_unix_e`
  kind, with no agent and nothing downloaded.

Parents: [`ICQ-STATION.md`](ICQ-STATION.md) (the win98se pathfinder — the
host-side tap/containment wiring is shared verbatim),
[`STATION-beos.md`](STATION-beos.md) (the other pre-OSCAR station),
[`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md), [`GATEWAY.md`](GATEWAY.md). The guest
itself: [`docs/guests/slackware.md`](../../guests/slackware.md).

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device ne2k_isa,netdev=rn0,mac="$RN_SLACKWARE_MAC"` — the **same device** the station always had (the `bare.i` kernel's `ne.o` module at `io=0x300`); only the netdev backend went `user` → `tap`. Backend: `-netdev tap,id=rn0,ifname=slackwarern0,script=no,downscript=no` |
| MAC | unique, fleet scheme `52:54:00:52:4e:1f` (`52:4e` = RN, last octet = last IP octet, `.31` → `0x1f`). Real value in gitignored `registry/local.env` `RN_SLACKWARE_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:1f` and reads the one line at boot. It lives in the golden's device vmstate, so it was baked by a **cold** boot |
| Tap | `slackwarern0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/slackware/rn-tapnet.sh up`, invoked from the launcher on **every** start. Chain `SLACKWARERN-IN`, scoped to the guest IP, fail-closed — the launcher runs under `set -e` and `rn-tapnet.sh` exits non-zero if it cannot read its own rules back, so **QEMU never starts an uncontained guest** |
| Guest IP | **static `10.99.0.31/24`**, written by `compose.sh` into `/etc/rc.d/rc.inet1`, with the on-link `10.99.0.0/24` route and **nothing else** — no default route. Slackware 3.4 predates DHCP on this media (there is no `dhcpcd`/`pump` anywhere in the `a` or `n` series), so it joins the plane the way `chokanji`, `rhapsody` and `macos753` do. The reservation `52:54:00:52:4e:1f=10.99.0.31` in `RETRONET_DHCP_RESERVATIONS` hands out nothing and exists purely as the plane's uniqueness ledger |
| DNS | `/etc/resolv.conf` → `10.99.0.2`. A convenience only: both browsers reach the corpus through the proxy **by IP**, so nothing on this station depends on name resolution |
| Web | **proxy door `10.99.0.2:3128`**, not the `:80` origin — see §Which door, below |
| Browser | **Arena beta-2b** (`/usr/X11R6/bin/arena`, the `xap1/arena.tgz` package, June 1996), wrapped by `/usr/local/bin/webbrowser` |
| ICQ | **micq 0.4.3**, UIN **`18400`**, to `10.99.0.2:4000/udp` (the pre-OSCAR legacy door), kept on the air by `/usr/local/bin/icq-session`. Password in `registry/local.env` `RETRONET_ICQ_SLACKWARE_PASS` |
| Pointer | **absolute**, x11warp straight over the bridge: the daemon opens `10.99.0.31:6000`, `XWarpPointer` + `XQueryPointer` readback. `SH_X11WARP_DISPLAY=10.99.0.31:0` |
| Exec | `labctl exec slackware "<cmd>"` → the guest's own `in.telnetd` at **`10.99.0.31:23`**, straight over the bridge. `exec_kind: telnet_unix_e` (shared with `sunos414`, `beos`, `aix432`), host client `/root/sunexec.py`, `SUN_RC='$?'` (the login shell is bash) and an empty password |
| Audio | unchanged: `sb16` + PC speaker on the dbus audiodev; the desktop only beeps |

## Which door, and why it is the proxy

Arena is a 1996 browser built on libwww and it **predates the `Host:` header**.
The gateway's `:80` origin dispatches on `Host:` and answers `400` without one,
so Arena cannot use the seamless web at all — the same class as MacWeb 2.0 on
`macos753` and Mosaic 2.x, exactly as [`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md)
warns. It uses the `:3128` **proxy** door, which dispatches on the absolute-form
request line and needs no `Host:`.

That is configured in two places on purpose:

- `/etc/profile` exports `http_proxy`, `ftp_proxy` and `WWW_HOME` for anything
  started from a login shell (including `lynx`, which also gets the same two
  settings written into `/usr/lib/lynx/lynx.cfg`).
- `/usr/local/bin/webbrowser` sets them **again** and then execs Arena. A browser
  launched from an fvwm95 menu or dock button is not a login shell's child and
  never reads `/etc/profile`; without the wrapper the dock button would open a
  browser that cannot reach anything, which is a failure that looks exactly like
  "the corpus is down".

## Discoverability — the dock button and the Start menu

The exhibit's requirement was that a visitor can *find* the web without being
told. `compose.sh` patches the stock `system.fvwm2rc95` in two places:

- The **dock** (`FvwmButtons`, bottom right) gains a `web` button. It goes into
  the slot the shipped config already reserved: Slackware's own
  `system.fvwm2rc95` carries a commented-out `#*FvwmButtons netscape nscape.xpm`
  line and ships `nscape.xpm`, so the museum's browser takes the Netscape slot
  the distribution left for it.
- The **Start menu** gains `Web browser` and `ICQ (retronet)` as its first two
  entries, above `New shell`, with `mini-nscape.xpm` and `mini-mail.xpm`.

Both are ordinary `sed` edits against anchors in the stock file, so a change in
the upstream package shows up as a missing hook rather than a silent no-op —
`compose.sh` prints `fvwm95 browser hooks: 2` and a `0` there is the alarm.

## The ICQ client — micq 0.4.3, built by the guest

### Why this client

There is **no graphical ICQ client for libc5 Linux**. Everything from the era
that had a GUI (GnomeICU, kicq, licq) needs GTK+ or Qt and a C++ toolchain this
distribution does not have; everything modern enough to speak OSCAR (climm
0.6.4, the `solaris` rollback client) is C99 and does not survive `gcc 2.7.2.3`.
What does exist is **micq 0.4.3** (December 1999): ~10 files of plain C89, no
`configure`, no ncurses, no dependencies at all — and it speaks the **ICQ v5**
protocol on **UDP 4000**, which the gateway has served since 2026-08-23 for
`beos` and which a **bridged** station can actually reach (a slirp `guestfwd` is
TCP-only, which is the whole reason `win98se` needs an OSCAR-era client).

So the station's IM surface is a terminal client in an xterm, the way `solaris`
ran climm in a `dtterm` before Pidgin. It is titled `ICQ - retronet`, it owns its
window, and it is on the taskbar as a first-class application.

### It is compiled in the guest, and that is the reproducible path

The obvious idea — build it host-side in a chroot on the composed root — **does
not work on this hardware**, and the failure is worth writing down because it
will bite the next libc5 guest:

> Slackware 3.4's binaries are 32-bit ELF against libc5 and they run under
> `chroot` on the trixie host *only in the simplest cases*. `/bin/ls` runs.
> `/bin/sh` (bash 2.0) dies with **`sh: Out of virtual memory!`** and `gcc` with
> **`gcc: virtual memory exhausted`**, on a box with 500 GB free. It is libc5's
> `sbrk`-based malloc against a modern mmap layout; `setarch linux32 -L`
> (legacy VA layout, 3 GB personality), `setarch -R` and `ulimit -s 8192` all
> fail to change it. `/bin/ash` is the one shell that works, which is enough to
> discover the problem and not enough to run a build.

So the build happens where the toolchain is native: in the guest, over the new
telnet exec channel, in about 20 seconds. `compose.sh` unpacks
`micq_0.4.3.orig.tar.gz` into `/usr/src/micq`, applies the museum's patch, and
installs the **staged** binary from `/data/assets-staging/slackware/extras/micq`.
A visitor — or the next agent — types `cd /usr/src/micq && make` and gets the
identical binary back; that is the reproducibility record, and it is why the
source ships on the disk rather than only the binary.

| Artifact | Value |
|---|---|
| Source | `micq_0.4.3.orig.tar.gz`, 100430 bytes, from `snapshot.debian.org` (`debian-archive`, `micq 0.4.3-4.1`) |
| Patch | `scripts/build-guests/patches/micq-0.4.3-quiet-retronet-chatter.patch` |
| Toolchain | the guest's `gcc 2.7.2.3` (`d3/gcc2723`) + `binutils` (`d1`) + `linuxinc` (`d7`) + libc5 dev (`d8/libc`) + `gmake` (`d2`) |
| Binary | `/usr/local/bin/micq`, 90804 bytes, ELF 32-bit i386, `md5 52300c7cd1756ab16f0bc376fce56074` |
| Build time | ~20 s in the guest (32 MB, 1 vCPU, KVM) |

### The patch, and the thing it fixes

Stock micq against this gateway produces an ICQ window that **never stops
scrolling**. Three separate sources, all of them the client treating a routine
server response as news:

1. micq refreshes its contact list on a timer; the gateway answers each refresh
   with a **full presence dump**, so `HiveBot (Online) logged on.` reprints for
   every contact roughly every ten seconds.
2. The same refresh gets another `SRV_X1` "list done" ack, and micq redraws the
   whole `Users online:` block each time.
3. The gateway **does not acknowledge** three of the commands micq queues —
   Finish Login, Contact List, Delete Server Messages. micq retries each six
   times and then prints `Discarded a Contact List packet.`, for ever.

None of it means anything is wrong: the station signs in, sees its roster and
exchanges messages. But on an exhibit it is fatal to the *golden*: the
framebuffer never settles, so there is no stable frame to bake, and an idle
station streams changed tiles all day. Measured before the patch: `fb-wait
--settle 75 --timeout 200` **timed out with the last change at 200.4 s**. After:
settles in seconds, and the only thing still repainting on the whole desktop is
xclock's minute hand.

The patch is three surgical changes that each keep the case that *is* news — a
real presence transition, the actual login summary, and a discarded `LOGIN` or
`KEEP_ALIVE` (which really does mean the session is gone, and still exits so the
watchdog can restart it).

### The watchdog

micq has no auto-reconnect, the same gap `beos`/ICBM has. Here it costs one
wrapper instead of a guest-side service: `/usr/local/bin/icq-session` runs micq
in a loop and the xterm runs the wrapper, so the client dying is a visible,
self-healing event rather than a dead window.

**Measured**: `kill` the client in the guest → the window prints
`--- micq exited; reconnecting in 5s (Ctrl-C to stay out) ---` and micq is signed
back in with HiveBot and beos online **6.2 s later**.

### The contact list is guest-side, and this is the one thing to remember

**ICQ v5 has no server-side roster.** SSI/feedbag is an OSCAR service; the legacy
protocol sends the contact list *from the client* at login. So the seeder's
primary path ([`CONTACT-SEEDER.md`](CONTACT-SEEDER.md)) does nothing for this
station's own display:

- `scripts/retronet/icq/roster.json` gains a `slackware` row so **every other
  station** carries slackware in its server-side roster. That half works normally
  and `seed_contacts.py ssi --apply` picks it up.
- What **slackware itself shows** comes from `~/.micqrc`, written by `compose.sh`
  from the same roster. Changing slackware's contact list therefore needs a
  **compose + golden re-bake**, not a seeder re-run. `beos`/ICBM is in the same
  class.

## The exec channel — inetd, telnetd, and the two lines that make login work

The `tcpip` package already carries `/usr/sbin/inetd`, `/usr/sbin/in.telnetd` and
`/usr/sbin/tcpd`; the station simply had `rc.inet2` emptied. `compose.sh` now:

- writes an `rc.inet2` that starts `inetd` and nothing else;
- rewrites `/etc/inetd.conf` to a **single** service, `telnet` behind `tcpd`;
- writes `hosts.allow` = `in.telnetd: 10.99.0.1` and `hosts.deny` = `ALL: ALL`,
  so even from inside the bridge only labhost reaches it;
- **appends the 64 pty names to `/etc/securetty`.** This is the non-obvious one:
  `login(1)` refuses **root** on any tty not listed there, and every pty is
  unlisted by default. With the museum's empty root password and no securetty
  entry, telnet answers, accepts `root`, and then silently rejects the login —
  which reads as "telnetd is broken" and is not.

## Containment, stated plainly

Four layers, none of which depends on another
([`rn-tapnet.sh`](../../../streamhost/stations/slackware/rn-tapnet.sh) carries
the same list in full):

1. **Topology** — the tap is enslaved only to `vmbr-rn`, which has
   `bridge-ports none` and no uplink.
2. **Routing** — the guest's own `rc.inet1` adds the on-link route and no
   default; `retronet-fw`'s FORWARD chain drops anything trying to route through
   labhost regardless.
3. **Filter** — `SLACKWARERN-IN`, scoped to `10.99.0.31`, drops every NEW flow
   the guest starts toward labhost and returns only the reply side of a
   labhost-initiated one.
4. **In the guest** — `hosts.deny ALL: ALL`, and the X server's own
   `xhost +10.99.0.1` means an X connection from any other bridge member is
   refused by the X server itself.

Layer 3's `ESTABLISHED,RELATED RETURN` rule is **load-bearing here**, unlike on
`chokanji` where it is a courtesy: labhost dials this guest twice (the x11warp
pointer on `:6000`, the exec channel on `:23`), and without the return rule the
pointer stops working.

What this link exposes: the other guests on `vmbr-rn` can address `10.99.0.31`,
and what they find is an X server that refuses them and a telnetd behind an
`ALL: ALL` deny. Same trade every bridged station makes.

## Proofs — 2026-09-03, all on the framebuffer

Rig `/data/vms/sandbox/slackware-rn/rig/`, same device set as the station.

| Frame | What it proves |
|---|---|
| `fb-cold.png` | the golden scene from a cold boot: ICQ signed in as 18400, **HiveBot** and **beos** online by name, quiet; `web` in the dock |
| `fb-startmenu.png` | **Web browser** and **ICQ (retronet)** at the top of the fvwm95 Start menu |
| `fb-arena.png` | Arena rendering `http://search.retronet/` — the AltaVista-styled search page, W3C logo and all |
| `fb-arena-corpus.png` | Arena rendering the corpus site `http://home.netscape.com/` (July 1997) **with images** |
| `fb-prebake.png` / `fb-restore1.png` | the bake frame and the `loadvm golden` restore — **10 differing pixels out of 786432**, all one 2×5 block at x 510–511 / y 713–717: the dock's xload load-graph bar on its own 5-second timer. The ICQ window, the terminal, the taskbar and the pointer are identical |
| `fb-warp-after-restore.png` | x11warp `(100,700)` and `(900,100)`, exact readback, cursor visible — **after** the restore |
| `fb-icq-reconnect.png` | the watchdog: client killed, signed back in 6.2 s later |

Non-framebuffer measurements taken alongside:

- guest `uname -a` → `Linux darkstar 2.0.30 #3 Tue Jun 24 03:49:52 CDT 1997 i686`
- `ifconfig eth0` → `HWaddr 52:54:00:52:4E:1F  inet addr:10.99.0.31`, and
  `route -n` shows exactly two routes, neither a default
- `lynx -dump http://search.retronet/` through the proxy returns the search page
- `savevm golden` → VM_SIZE **17.1 MiB**, VM_CLOCK `0000:01:26.825`
- cold boot to settled: **62.0 s** at `--settle 45`, with the **last real change at
  16.3 s** — the whole desktop, micq signed in and all, is painted 16 s after
  power-on. The only two things that ever move by themselves afterwards are
  xload's bar (5 s) and xclock's minute hand (60 s), so a settle window of 45 s
  is the one that reports the truth; 75 s never settles and says nothing about
  the guest

## Rollback

The retronet golden is staged beside the live one, never over it:

```
/data/vms/streamhost/stations/slackware/disk.qcow2         # the slirp-era golden, untouched
/data/vms/streamhost/stations/slackware/disk.qcow2.rn-new  # this work
```

Rolling back is `disk.qcow2` plus reverting `qemu-streamhost.sh` (the `-netdev
user,hostfwd` line) and `station.env.fixture` (`SH_X11WARP_DISPLAY=127.0.0.1:84`)
— the golden, the launcher's device set and the fixture are one combination and
must move together. `rn-tapnet.sh down` releases the tap and the chain.
