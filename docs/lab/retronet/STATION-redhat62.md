# redhat62 on the retronet — web + ICQ, as built

**Status: BAKED, staged as a candidate disk; not yet swapped in.** `redhat62`
(Red Hat Linux 6.2 "Zoot", kernel 2.2.14-5.0 UP, GNOME 1.0.55 under
Enlightenment on XFree86 3.3.6, KVM) joins **both** retronet planes on
2026-09-03: it browses the museum corpus with **Netscape Communicator 4.72**
and signs in to the OSCAR gateway as UIN **18100** with **Gaim 0.59.9**, whose
buddy list renders the greeter as **HiveBot** from the server-side SSI roster.

Parents: [`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md), [`ICQ-STATION.md`](ICQ-STATION.md),
[`ICQ-STATION-tru64.md`](ICQ-STATION-tru64.md) (the Gaim 0.59.9 + SSI-patch
recipe this station reuses), [`CONTACT-SEEDER.md`](CONTACT-SEEDER.md),
[`GATEWAY.md`](GATEWAY.md); the guest itself is
[`docs/guests/redhat62.md`](../../guests/redhat62.md).

## The wiring, at a glance

| | |
|---|---|
| NIC 0 | `ne2k_pci` on user-mode SLIRP, **`restrict=on`**, carrying ONLY the loopback X forward `127.0.0.1:6081 -> 10.0.2.15:6000`. This is the x11warp pointer's only path; it is not a network the guest can use |
| NIC 1 | `ne2k_pci` on the persistent tap **`redhat62rn0`**, enslaved to `vmbr-rn` by `streamhost/stations/redhat62/rn-tapnet.sh up` from the launcher on every start |
| Guest IP | **static `10.99.0.33/24`** in `/etc/sysconfig/network-scripts/ifcfg-eth1` (`BOOTPROTO=none`, no `GATEWAY`); `eth0` is static `10.0.2.15/24`, also with no gateway. **No default route on either NIC** (containment Lock 1) |
| Resolver | `/etc/resolv.conf` = `nameserver 10.99.0.2` + `domain retronet.lab`; `/etc/hosts` maps `10.99.0.33 redhat62 redhat62.retronet.lab` |
| MAC | `52:54:00:52:4e:21` (fleet scheme `52:54:00:52:4e:<last-IP-octet>`, `.33 -> 0x21`), real value in gitignored `registry/local.env` as `RN_REDHAT62_MAC`; the committed launcher carries the placeholder `02:00:00:00:00:21`. Reserved in `RETRONET_DHCP_RESERVATIONS` as the plane's uniqueness ledger even though the guest never sends a DISCOVER |
| Guard | `REDHAT62RN-IN`, fail-closed, scoped to `10.99.0.33`: ESTABLISHED replies RETURN, every NEW flow the guest starts toward labhost DROP. Nothing on labhost dials this guest over the bridge today (the pointer rides SLIRP), so in practice it is a pure DROP |
| Browser | **Netscape Communicator 4.72** (in the RH 6.2 install, already on the GNOME panel as the "N" launcher), `network.proxy.type 0` — **seamless, no proxy**: wildcard DNS resolves every name to `10.99.0.2` and the `:80` origin serves the corpus |
| ICQ client | **Gaim 0.59.9** (`/usr/local/bin/gaim`, 2 200 025 bytes), built in the guest from the archived tarball + the tru64 SSI patch; config `/home/gallery/.gaimrc`, auto-signs-in as UIN `18100` |
| Persona | UIN `18100`, password in `registry/local.env` as `RETRONET_ICQ_REDHAT62_PASS` (8 chars — the gateway rejects longer, see below) |
| Exec | **none.** This station has no exec channel. In-guest work is driven from a VT with `scripts/dev/qmp-type.py`, plus `lynx -source` against a throwaway HTTP server on labhost |

## Gaim 0.59.9 — the same recipe as tru64, with one C89 fix

The requirement is a GTK desktop IM client that keeps the fleet's **server-side
SSI/feedbag** contact list, so `HiveBot` renders by name with no client-side
add flow and no golden recapture per contact change. Gaim 0.60+ is GTK+2;
0.59.9 (March 2003) is the last GTK+1.2 release, and RH 6.2 ships GTK+ 1.2.6.

- Source: `gaim-0.59.9.tar.gz`, 2 126 466 bytes, sha256
  `268b630bfab1096b1cff4e02c97ea6bb2bf22b3be387d3c222cfe0453c86dbd8`
  (already in the box's media archive from the tru64 wave), GPLv2.
- Patch: `streamhost/stations/tru64/gaim-0.59.9-icq-ssi.patch`, applied
  unchanged — it removes stock 0.59.9's refusal to use SSI on numeric (ICQ)
  screen names and adds the reconnect backoff.
- **Contradiction with the tru64 doc, and the fix.** That patch does not compile
  under Red Hat 6.2's **egcs 1.1.2** (gcc 2.91): its `account_online()` hunk in
  `src/multi.c` inserts two statements *before* the function's `int i;` and
  `struct signon_meter *meter` declarations. Compaq C accepted that; egcs is
  C89-only and fails with ``'meter' undeclared`` / ``'i' undeclared``. Moving
  both declarations to the top of the block (and assigning `meter` after) is the
  whole fix — the patch is otherwise portable. Any future GTK+1 station on a
  1990s Linux toolchain will hit this.
- Toolchain: `binutils`, `cpp`, `egcs`, `glibc-devel`, `kernel-headers`, `make`,
  `glib-devel`, `gtk+-devel`, `XFree86-devel` — all from the station's own
  `zoot-i386.iso`, extracted on labhost and fetched over HTTP.
- Configure: `--prefix=/usr/local --disable-perl --disable-nas --disable-esd
  --disable-artsc --disable-screensaver --disable-gnome --disable-nls`.
- `~/.gaimrc` is hand-authored to the byte layout `gaimrc.c` writes (tab-exact):
  `user_opts { 5 } { 1 }` = `OPT_USR_AUTO | OPT_USR_REM_PASS` + `PROTO_OSCAR`
  (silent auto sign-in, no login window), `proto_opts { 10.99.0.2 } { 5190 }`
  (auth host/port replacing `login.oscar.aol.com`), `im_options { 8203 }`
  (`OPT_IM_ALIAS_TAB`, so a chat window is titled `HiveBot`, not `10000`),
  `misc_options { 8 }` (no Buddy Ticker toplevel), `away_options { 2 } { 0 }`
  (never auto-away — an away persona is one the bot will not greet).

## The account

`rn-tool.py user-set 18100 <pass>` + `user-open 18100`, then
`rn-tool.py ssi-seed 18100 10000=HiveBot …` wrote the server-side roster
(8 items: HiveBot + the seven other live ICQ stations). The roster row is in
`scripts/retronet/icq/roster.json` (`client: gaim0599`, `onboarded: true`); the
coordinator's `seed_contacts.py ssi --apply` picks redhat62 up into every other
station's list at landing.

**The gateway rejects a password longer than 8 characters** —
`400 invalid password: invalid password length: password must be between 6-8
characters`. `RETRONET_ICQ_REDHAT62_PASS` is therefore 8 chars.

## What the framebuffer proved

| Proof | Frame |
|---|---|
| Gaim buddy list, group `contacts-icq8-18100`, **HiveBot** by name, signed in as 18100 | `/data/vms/sandbox/redhat62-rn/work/proof-gaim-hivebot.png` |
| Netscape 4.72 rendering `http://search.retronet/` (the AltaVista-styled search) with **no proxy configured** | `/data/vms/sandbox/redhat62-rn/work/proof-web-search-retronet.png` |
| The whole scene reproduced by a **cold boot** on the final device set — Netscape on search.retronet, Gaim with HiveBot, gmc, the GNOME Help Browser | `/data/vms/sandbox/redhat62-rn/work/proof-scene-coldboot.png` |
| `loadvm golden` + `cont` restores that scene under the production launcher args (`restrict=on`, both NICs) | `/data/vms/sandbox/redhat62-rn/work/proof-restore.png` |

Off-framebuffer but measured: `ping 10.99.0.2` from the guest; `host
search.retronet`; labhost `ping 10.99.0.33`; the gateway's session list
containing `18100`; and the x11warp handshake — a raw X11 connection setup to
`127.0.0.1:6181` (the clone's forward) answers **byte 0 = 1 (success)** on the
restored golden with `restrict=on`, with `/etc/X0.hosts` = `10.0.2.2` alone.

**Not proven:** a keystroke landing in a *window* of the restored golden. Keys
reach the guest (every VT login, and the Netscape licence dialog was accepted by
a QMP `ret` — the AltaVista page that followed is the framebuffer evidence), but
placing the pointer to give a window focus needs `XWarpPointer` over the x11warp
connection; the PS/2 *relative* pointer cannot be positioned reliably from QMP,
which is exactly why this station's backend is x11warp. The daemon does that in
production.

## Traps this station hit

- **The tap guard is rebuilt from empty on every launch.** `rn-tapnet.sh up`
  flushes `REDHAT62RN-IN`, so a temporary sandbox ACCEPT (a throwaway HTTP server
  on labhost for file transfer) silently disappears on the next relaunch. The
  symptom is a guest command that hangs forever with no output — `lynx` blocked
  on a DROPped SYN — which reads exactly like "the VT stopped working".
- **The guest has no shell service.** RH 6.2 as installed here has **no telnetd,
  no sshd, no wget, no curl, no ftp** — only `lynx` and `perl`. `lynx -source
  <url> > file` is the bootstrap; a 13-line perl fetcher (`IO::Socket`, **not**
  `IO::Socket::INET` — perl 5.005 defines `INET` inside `IO/Socket.pm`) carries
  binaries. telnetd was installed from the CD for the bring-up and **disabled
  again before the bake** (`chkconfig inet off`); re-enable it by uncommenting
  the `telnet` line in `/etc/inetd.conf` and `chkconfig inet on`.
- **`rpm -Uvh` aborts the whole transaction** if any one package is already
  installed. Use `--force`.
- **mingetty gets disabled for 5 minutes** after a few fast login/logout cycles
  ("respawning too fast"), and the dead VT then just *echoes* what you type with
  no shell behind it. Move to the next VT (`ctrl-alt-f3`, `f4`) rather than
  concluding the guest is wedged.
- **Both NICs share IRQ 11** (`eth0, eth1` on one XT-PIC line) and both work —
  RX and TX counters advance on each. No slot juggling was needed.
- **`qmp-type.py --shot` can return a stale frame.** Take proof frames with HMP
  `screendump` and a short settle instead.
- **The guest's X server listens on `0.0.0.0:6000`**, so port 6000 is reachable
  from the retronet as well as through the SLIRP forward. Access is still gated
  by `/etc/X0.hosts` = `10.0.2.2` alone, so no retronet peer can use it, but the
  open port is worth knowing.

## Landing this

1. Swap the disk: `/data/gallery-guests/RedHat62/redhat62.qcow2.rn-candidate`
   -> `redhat62.qcow2` (keep the old file as the rollback; launcher and disk are
   an atomic pair, so the new launcher must land in the same window).
2. `box-deploy.sh --apply` (carries `qemu-streamhost.sh` **and**
   `rn-tapnet.sh` via the `redhat62-rn-tapnet` box-sync pair), then restart the
   station.
3. `seed_contacts.py ssi --apply` so every other live station's roster gains
   `redhat62`.
