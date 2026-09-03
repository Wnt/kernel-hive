# netbsd14 retronet station (mICQ + Lynx) — as built

**Status: BUILT, not yet promoted.** `netbsd14` (NetBSD 1.4.1 i386, 1999,
XFree86 3.3.3.1 + twm) joins **both** retronet planes on 2026-09-03: the **web
plane** through Lynx 2.8.2rel.1 and the **ICQ plane** through **mICQ 0.4.12**
signed in as UIN **17600**, with **HiveBot** on its contact list. Both clients
are compiled **on the guest** from period sources — NetBSD 1.4.1 ships no
browser and no IM client in base, and pkgsrc does not exist for it in any usable
form. Parents: [`GATEWAY.md`](GATEWAY.md), [`WEB-PROXY.md`](WEB-PROXY.md),
[`ICQ-STATION.md`](ICQ-STATION.md) (the win98se pathfinder — the host-side
tap/containment wiring is shared), [`ICQ-STATION-solaris.md`](ICQ-STATION-solaris.md)
(the first Unix OSCAR station), and the guest itself,
[`docs/guests/netbsd14.md`](../../guests/netbsd14.md).

## The wiring, at a glance

| | |
|---|---|
| NIC | a **second** `-device ne2k_pci,netdev=n1`, backend `-netdev tap,ifname=netbsd14rn0,script=no,downscript=no`. The **first** `ne2k_pci` stays on SLIRP but now with **`restrict=on`** — see §Two NICs |
| MAC | `RN_NETBSD14_MAC` in gitignored `registry/local.env` (committed placeholder `02:00:00:00:00:20`) (fleet scheme `52:54:00:52:4e:<last IP octet>`, `.32` → `0x20`). Box-local in `registry/local.env` `RETRONET_ICQ_NETBSD14_MAC`; the launcher reads it with the same value as a committed fallback. It lives in the golden's device vmstate, so the golden was **cold-baked** with it |
| Tap | `netbsd14rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/netbsd14/rn-tapnet.sh up` from the launcher on every start (registered as a `box_sync_add_pair` — the generic launcher sweep does not carry the helper) |
| Guest IP | **static `10.99.0.32/24`** on `ne1`, from `/etc/ifconfig.ne1`. NetBSD 1.4.1 does ship `dhclient`, but a hand-set address needs no lease renewal inside a `loadvm` guest whose clock jumps, and the DHCP reservation is kept anyway as the plane's uniqueness ledger |
| Default route | **`10.99.0.2` via `ne1`** (`/etc/mygate`) — the retronet gateway and nothing else. It is not a route off the retronet: CT 951 has no uplink and labhost's `RETRONET-FWD` drops any forward through the box, so this is containment Lock 2 doing the work rather than the absence of a route |
| Guard | `NETBSD14RN-IN` — ESTABLISHED/RELATED back to labhost only, every NEW flow the guest starts toward labhost DROPped |
| DNS | `/etc/resolv.conf` → `nameserver 10.99.0.2`, `domain retronet.lab` (SLIRP's `10.0.2.3` is unreachable under `restrict=on` and must not be listed); `/etc/nsswitch.conf` → `hosts: files dns`. **`files` must stay first** — the guest's X server reverse-resolves every TCP client, and the SLIRP peer `10.0.2.2` has to answer out of `/etc/hosts` or the x11warp handshake stalls |
| Web | **seamless, no proxy.** Lynx 2.8.2 sends `Host:`, so it uses the gateway's `:80` origin door. Proven in-guest: `http://search.retronet/` renders the AltaVista-styled search page and `http://spacejam.com/` renders from the corpus |
| ICQ | mICQ 0.4.12, `/usr/local/bin/micq`, config `/root/.micq/micqrc`, UIN `17600`, password `registry/local.env` `RETRONET_ICQ_NETBSD14_PASS`, server `10.99.0.2:5190` (the labhost door — routable from the guest over the bridge) |
| Exec | **none.** This station has no exec channel: everything here was driven with `qmp-type.py` into the guest's xterm plus the framebuffer, with a transfer CD-ROM for files |

## Two NICs, and why the pointer stayed on SLIRP

`ne0` is the SLIRP NIC and the **only** x11warp channel: the launcher's
`hostfwd=tcp:127.0.0.1:6076-10.0.2.15:6000` and
`SH_X11WARP_DISPLAY=127.0.0.1:76` are unchanged. `ne1` is the retronet tap.

**The SLIRP netdev is a one-way door: `restrict=on`.** Before the retronet the
guest's default route and resolver were SLIRP's `10.0.2.2` / `10.0.2.3`, and
SLIRP's whole job is to NAT the guest out through the host — which on this box
means the real internet, and it also means a `ping 10.99.0.2` can succeed with
no retronet link at all. `restrict=on` closes that: the guest cannot use
`10.0.2.2` as a gateway or `10.0.2.3` as a resolver, and the netdev carries
**only** the host-initiated `hostfwd`. Verified after the change: the raw X
connection-setup handshake on `127.0.0.1:6276` still answers `1`, and
`xwarp.py` still warps and reads the pointer back.

So the guest's *only* outbound network is `ne1`: resolver `10.99.0.2`, default
route `10.99.0.2`, everything it can reach is the retronet.

It is tempting to collapse them and point `SH_X11WARP_DISPLAY` at
`10.99.0.32:6000` now that the guest has a real address. **Don't.** The
containment chain is fail-closed *toward labhost*, and the whole design is that
the guest never accepts a labhost-initiated flow it did not have to. The SLIRP
forward is host-local, host-initiated and needs no bridge hole at all, so it
costs the containment model nothing. Keeping it also means the x11warp route —
the station's entire pointer — does not depend on the retronet being up.

The device *order* matters: the SLIRP `ne2k_pci` is declared first and therefore
lands on the lower PCI slot, so it stays `ne0` and the guest's existing
`/etc/ifconfig.ne0` is still correct. Adding the tap NIC first would renumber
both interfaces.

## mICQ 0.4.12 — sourced, built, configured

| | |
|---|---|
| Source | `micq-0.4.12.tgz`, sourceforge.net/projects/climm/files/OldFiles/, `sha256 9fd47c90be48a7d9d41d2bb4c5c9c00496206afab3d0eb9ff7916d41b46641f7` |
| Build | `CFLAGS="-O" ./configure --prefix=/usr/local --disable-ssl --disable-tcl --disable-nls && make && make install` — clean on NetBSD 1.4.1's stock `gcc`, no patches, ~90 s |
| Protocol | **OSCAR v8** (`type icq8`, `version 8`), the FLAP/SNAC/TLV protocol Open OSCAR Server speaks. mICQ also carries the pre-OSCAR v5 UDP path; it is not used here |
| Replay | `scripts/build-guests/tiles/netbsd14/build-im.sh` (pinned URL + sha256) and `micqrc.tmpl` |

Why mICQ and not climm/Gaim: NetBSD 1.4.1's compiler is a 1999 `gcc` and its X
is XFree86 3.3 with no GTK anywhere, so a GTK+1.2 client like the tru64/irix
Gaim build has nothing to link against. mICQ 0.4.12 is plain C over libc and
curses, it is the direct ancestor of the climm the solaris station used to run,
and it is contemporary with the guest.

### Three things about `micqrc` that are not obvious

1. **`HOME` is not set in the exhibit session.** `/etc/rc.local` starts `xinit`
   from `/etc/rc`, so mICQ looked for `./.micq/` relative to `/`, found nothing,
   and opened its **setup wizard** on the exhibit screen instead of signing in.
   `kh-xsession` now pins `HOME=/root` *and* passes `-b /root/.micq/`.
2. **`format 1` and a `[Group]` section** belong in the file. Without a `[Group]`
   naming the connection, mICQ synthesises one and prints
   `Warning: Deprecated syntax found in rc file!` at the top of the window.
   (Both are set here and the banner still appears — see §Known limits.)
3. The password is stored **plaintext**, exactly as climm's `climmrc` and
   Pidgin's `accounts.xml` do on the sibling stations. That is what buys a silent
   sign-in with no prompt on the exhibit screen.

The contact list is **client-local** (`[Contacts]`, `10000 HiveBot`), not the
server-side SSI roster: mICQ 0.4.12 can *fetch* the server list with
`contact show` / `contact import`, but it does not sync it at login the way
Gaim/Pidgin do. The account's SSI roster is seeded anyway
(`rn-tool.py ssi-seed 17600 10000=HiveBot`) so the fleet-wide reconcile in
[`CONTACT-SEEDER.md`](CONTACT-SEEDER.md) stays the single source; a new fleet
contact reaches *this* station by editing `micqrc.tmpl` and re-applying, not by
a reseed.

## Lynx 2.8.2rel.1 — the browser

| | |
|---|---|
| Source | `lynx2.8.2rel.1.tar.gz`, invisible-island.net/archives/lynx/tarballs/, `sha256 cb974227c268269f74072d0e9d26c7b42190cf77d9e1e082bbdd74390ba6a6ec` (released 1999-06-03 — two months before NetBSD 1.4.1) |
| Build | `CFLAGS="-O" ./configure --prefix=/usr/local --with-screen=curses --disable-nls && make && make install`, clean, ~60 s |
| Replay | `scripts/build-guests/tiles/netbsd14/build-browser.sh` |

**Discoverable, per the brief:** it is not a command a visitor has to know. The
session opens an xterm **titled `Web Browser - Lynx`** on `http://search.retronet/`,
so the browser is a window on the desktop like any other. Lynx sends `Host:`, so
it goes straight to the gateway's `:80` origin and needs **no proxy** — the
`:3128` door is for the pre-`Host:` browsers (Mosaic, MacWeb), not this one.

A graphical browser was not attempted: NetBSD/i386 1.4 Netscape binaries are not
on any mirror that still answers, and building a 1999 GUI browser against
XFree86 3.3 with no toolkit was not worth the budget when the accepted floor
renders the corpus correctly.

## The scene

`scripts/build-guests/tiles/netbsd14/kh-xsession` is the whole fixture:

```
xterm 'NetBSD 1.4.1'        80x28 +0+0      root shell (the daemon warps here first)
xcalc                             +640+80
xclock                       120x120-10+10
xterm 'ICQ - mICQ'          80x20 +0+430    -e micq -b /root/.micq/
xterm 'Web Browser - Lynx'  80x20 +510+430  -e lynx http://search.retronet/
```

The two retronet windows sit on the bottom row, side by side, in the space the
original three-window scene left empty. Nothing was moved.

## Checkpoint

`golden` in `disk.qcow2` (still the only block device), re-baked **2026-09-03
08:55:46** on the final retronet device set (second `ne2k_pci` + `restrict=on`)
with the `noaccel` XF86Config: **VM_SIZE 41.8 MiB, VM_CLOCK 0000:00:58.659**
(the pre-retronet golden was 38.6 MiB / `0000:01:01.205`). Cold boot to the
settled scene: **41.6 s**. Restore proven the same minute — `loadvm golden -S` +
`cont` shows the full scene 5.9 s after the launcher starts, and the X
connection-setup handshake on the loopback forward answers `1` in 1.0 s.

**The golden had to be cold-baked, not migrated.** A second PCI device changes
the device set, and `loadvm` of the pre-retronet golden on it is exactly the
combination rule 6 forbids: checkpoint + binary + device set are one thing.

## Reproducing the guest side

Everything is in `scripts/build-guests/tiles/netbsd14/`, replayable from a
transfer CD (`genisoimage -R -J`) mounted at `/mnt`:

```sh
sh /mnt/build-im.sh          # mICQ 0.4.12
sh /mnt/build-browser.sh     # Lynx 2.8.2rel.1
sh /mnt/apply-rn.sh <icq-password>   # link, resolver, micqrc, kh-xsession
```

`apply-rn.sh` is idempotent and is the ICQ/web sibling of `apply-x.sh`.

## The reconnect, and the scroll bug it exposed

**mICQ reconnects on its own — this station needs no watchdog.** Proven the hard
way rather than assumed: the guest was killed, the gateway's TCP timeout reaped
UIN 17600 (session gone from `/session`), and only then was the golden restored.
mICQ printed `Scheduling v8 reconnect in 10 seconds`, reopened the v8 connection
and was `online` again — **the gateway logged `user signed on` ~45 s after
`cont`, unattended**. Measured twice.

That reconnect is also what exposed a **pre-existing rendering bug** on this
guest, invisible until now because the old ready scene never scrolled:

> **XFree86 3.3 on the emulated Cirrus repaints a scroll wrong.** Any window that
> scrolls comes back with a stale vertical-column artifact over every character
> cell; the text underneath is correct and an Expose (`xrefresh`) repairs it
> completely, so it is a repaint bug, not corrupt content. **It is the server,
> not the client** — proven by scrolling a plain `xterm` with `ls -l /usr/bin`,
> which corrupts identically.

The fix is one line in `XF86Config`: **`Option "noaccel"`** next to the existing
`no_bitblt`. `no_bitblt` alone disables the BitBLT engine but leaves the driver's
accelerated CopyArea path in play, and that is the broken one. With `noaccel` a
600-line scroll is pixel-clean, and so is the ICQ window after a reconnect. The
cost is software rendering on a 1024×768×8 desktop, which this station cannot
notice. **This is a station-wide fix, not a retronet one** — it happens to land
here because the retronet is what first made a window scroll.

## Traps this station cost

- **Shifted characters latch the shift key.** Typing `|` or `:` into this guest
  with `qmp-type.py` leaves shift **held**: the rest of the line arrives
  uppercase and every digit arrives as its shifted symbol
  (`lynx http://search.retronet/` → `lynx http:??SEARCH>RETRONET?`). Sending a
  bare `--keys shift` clears it. The working method for this station is to type
  **nothing but lowercase**, put every real command in a file on the transfer CD,
  and type only `mount -r -t cd9660 /dev/cd0a /mnt` and `sh /mnt/<script>`.
- **A ping to the gateway can succeed through the wrong NIC.** Before `ne1` was
  configured *and before `restrict=on`*, `ping 10.99.0.2` from the guest answered
  3/3 at ~300 ms — SLIRP had NAT-routed it out to the host, which *can* reach the
  bridge. It proves nothing about the tap (and it was the symptom that earned
  `restrict=on`). Read `netstat -rn` for a `10.99/24 link#2 ne1` route, and take
  the real proof from the **gateway** side: `remote_addr` on the OSCAR session
  must be `10.99.0.32`.
- **Never type a multi-line config.** `qmp-type.py` consumes backslash escapes,
  so a typed heredoc or `printf 'a\nb' >file` writes one broken line in the
  guest. Every config file on this station arrives on the **transfer CD** and is
  `cp`ed into place by `apply-rn.sh`; the only things typed are
  `mount -r -t cd9660 /dev/cd0a /mnt` and `sh /mnt/<script>`. That is also what
  makes the builder replay trivial — the CD tree *is*
  `scripts/build-guests/tiles/netbsd14/`.
- **Do not `sed` a config in place over a typed command either.** An in-guest
  `sed`-and-`mv` on `XF86Config` left the file truncated and X refused to start
  (`You must specify a keyboard in XF86Config`) on the next cold boot, with no
  X and therefore no xterm to fix it from — recovery was a wscons console login
  (and the console eats the first characters after each prompt change, so type
  Enter, then the line, then Enter). Ship **whole files** on the CD.
- **A one-way console log is worth setting up.** This station has no exec
  channel. `-serial file:<host path>` plus `cmd >/dev/tty00 2>&1` in the guest
  turns a blind framebuffer session into a readable build log. It is a
  **build-phase-only** flag: the golden was baked without it, on the exact
  station device set.

## Known limits

- **mICQ opens with `Warning: Deprecated syntax found in rc file!`** in the ICQ
  window. `format 1` and a `[Group]` section are both present and did not silence
  it, so at least one more parser path in `file_util.c` sets the flag. It is two
  lines of the client's own startup text, above the sign-in it then reports
  correctly, and it **scrolls off on the first reconnect**; letting mICQ rewrite
  the file itself (`save`) would fix the banner at the cost of the hand-authored
  template no longer being the source of truth.
- **The contact list is client-local**, so a fleet contact change does not reach
  this station through `seed_contacts.py ssi --apply` (see §mICQ above).
- **No proof of a HiveBot conversation yet** — the greeter's message arriving in
  mICQ has not been observed; only presence (`HiveBot (online)`), twice, across a
  reconnect.
- **The station's SSI roster is seeded but not cross-listed.** Only
  `10000 HiveBot` is in `17600`'s server-side feedbag. The fleet-wide
  `seed_contacts.py ssi --apply` (which also adds `netbsd14` to every other live
  station) is deliberately left to the coordinator, after the `roster.json` row
  lands.
