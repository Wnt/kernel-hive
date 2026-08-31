# beos on the retronet — the bridge, the exec channel, NetPositive, and ICBM on the pre-OSCAR door

**Status: LIVE, fully onboarded.** `beos` (BeOS R5 Professional 5.0.3) joined
the retronet on **2026-08-23** and got its ICQ client the same day. It is on a
real bridged NIC on `vmbr-rn` with a unique MAC, on **DHCP** (reserved
`10.99.0.16`), it browses the museum corpus in **NetPositive** — R5's own
browser, no proxy — and it is signed in to the gateway as UIN **`50000`** with
**ICBM .71**, the BeCQ successor, over the pre-OSCAR **UDP 4000** door. Open the
station and NetPositive is showing a corpus page with ICBM's contact list beside
it; HiveBot says hello about half a minute after the client signs on.

Two things make this station different from every other one on the retronet,
and both are wins:

- **It had NO exec channel at all** (`exec_kind: null`); the only way to run a
  command was to type into a Terminal window and read the framebuffer. It now
  has a real one, and it needed **no agent, no build and no download**: BeOS R5
  ships a **telnetd**, and the Network preferences panel turns it on.
- **Its browser was already installed.** R5 ships NetPositive, so the "era
  browser" deliverable cost nothing but a DNS server and a route-less lease.

Parents: [`ICQ-STATION.md`](ICQ-STATION.md) (the win98se pathfinder — the
host-side tap/containment wiring is shared verbatim),
[`ICQ-STATION-solaris.md`](ICQ-STATION-solaris.md) (the non-Windows worked
example), [`GATEWAY.md`](GATEWAY.md), [`WEB-PROXY.md`](WEB-PROXY.md).
The guest itself: [`docs/guests/beos.md`](../../guests/beos.md).

> **The one thing to know before touching the ICQ half.** ICBM .71 has no
> auto-reconnect: when the gateway drops its session the client tears the
> connection down cleanly and then stays offline for ever. Everything the
> exhibit does about that lives in one small guest-side loop,
> [`icbm-watchdog.sh`](../../../streamhost/stations/beos/icbm-watchdog.sh) —
> see [§The ICQ client](#the-icq-client--icbm-71-becq). A Terminal-based IM
> client remains out of bounds; ICBM is a native Be-API desktop app, which is
> the requirement.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device rtl8139,netdev=n0,mac="$RN_BEOS_MAC"`, backend `-netdev tap,id=n0,ifname=beosrn0,script=no,downscript=no`. R5 drives it with its own **`rtl8139`** driver (`/dev/net/rtl8139/0`). This **is** a device-set change from the station's shipped `ne2k_pci`, and it was not optional — §The NIC had to change. |
| MAC | **unique, fleet scheme `52:54:00:52:4e:10`** (`52:4e` = RN, last octet = last IP octet, `.16` → `0x10`). Real value in gitignored `registry/local.env` `RN_BEOS_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:10` and reads the one line at boot. It lives in the golden's device vmstate, so it was baked by a **COLD boot** — see §The cold re-bake. |
| Tap | `beosrn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/beos/rn-tapnet.sh up`, invoked from the launcher on **every** start. Chain `BEOSRN-IN`, scoped to the guest IP. Fail-closed: the launcher runs under `set -e` and `rn-tapnet.sh` exits non-zero if it cannot read its own rules back out of the kernel, so **QEMU never starts an uncontained guest**. |
| Guest IP | **DHCP**, reserved **`10.99.0.16/24`**, DNS **`10.99.0.2`**, domain `retronet.lab`, and **NO default gateway** — `retronet-dhcp` withholds option 3, and R5 records that faithfully as an empty `ROUTER =` in its own settings file. Reservation keys on `RN_BEOS_MAC`. `.13` is reserved for a future win95 and is untouched. |
| Seamless web | DNS = `10.99.0.2` (via DHCP) + **no proxy** → any URL resolves to the gateway and its `:80` origin serves the corpus by `Host`. §Seamless web |
| Browser | **NetPositive** (`/boot/apps/NetPositive` → `/boot/beos/apps/NetPositive`), R5's own. Already on the disk; nothing sourced, nothing added to the asset manifest. |
| Exec | `labctl exec beos "<cmd>"` → **R5's own telnetd at `10.99.0.16:23`, straight over the bridge**. `exec_kind: telnet_unix_e` (the existing kind, shared with sunos414), host client `/root/sunexec.py`. No agent in the guest, no hostfwd, no new protocol. §The exec channel |
| File transfer | **R5's own ftpd at `10.99.0.16:21`**, same login, enabled by the same checkbox. §Delivering files into the guest |
| ICQ | **ICBM .71** (`/boot/home/apps/ICBM/ICBM.x86`), UIN **`50000`**, auto-login, to `icq.mirabilis.com:4000` — the shipped default hostname, which `retronet-dns` answers with `10.99.0.2`, so no server override is configured anywhere. Kept signed on by `icbm-watchdog.sh`. §The ICQ client |
| Audio | still **OFF**, deliberately, and untouched by this work. |

## The NIC had to change — ne2k_pci → rtl8139

The plan was to keep `ne2k_pci` (a device-set change costs a golden re-bake, and
`loadvm` is only valid against the device set it was baked with). The guest
overruled it.

`ne2k_pci` is fine while the link is idle. Under a **real page load** — one
corpus page full of images — R5's `etherpci` driver loses the NE2000 receive
ring and storms the serial console:

```
etherpci_read: bad next packet! (1d,11,ace7) (77)
Receive errors now 132959
```

**144,683 of those lines in a single page load.** By the end the NIC was dead,
the browser had painted the page's text and none of its images, the guest's MAC
had aged out of the bridge FDB, labhost got `No route to host` (so the exec
channel was gone too) and QEMU sat pegged at 100% CPU.

It is **load-dependent**, which is why it did not show up immediately: the same
page loaded cleanly, twice, on a bring-up rig started with `-display none`, and
killed the link every time under the production capture path. Capturing at 30
fps under TCG leaves the guest much less CPU, the driver drains the ring more
slowly, and it overruns. A station that is only ever tested with a fast host
loop will not see this.

R5's own **`rtl8139`** driver carries the same page with **zero** errors, a 3 ms
ping and all images. The switch cost nothing extra because the retronet MAC
change already required a cold re-bake.

**The order that avoids a chicken-and-egg.** R5 pins the interface by driver
name in its settings file (`DEVICECONFIG`, `DEVICELINK`), so a guest whose
hardware changes underneath it comes up with no network — and therefore no exec
channel to fix it with. Retarget the config **first, while the old NIC still
works**, and only then change the device:

```sh
# while still on ne2k_pci, over the exec channel:
sed "s|etherpci|rtl8139|g" /boot/home/config/settings/network > /tmp/n \
  && cp /tmp/n /boot/home/config/settings/network && rm -f /tmp/n
sync
# then stop the station, change -device in the launcher, cold boot
```

The driver names are exactly the file names in
`/boot/beos/system/add-ons/kernel/drivers/dev/net/`, and the device node follows
them (`/dev/net/rtl8139/0`). If it ever goes wrong the recovery is a Terminal
window on the framebuffer, not a reinstall.

## The exec channel — R5's own telnetd, and nothing else

This is the single most useful thing on the station, and it is the answer to
"what does phase 2 stand on".

`Netscript` — R5's own boot script, `/boot/beos/system/boot/Netscript` — already
ends with exactly this:

```
start beos/system/servers/net_server
startsync beos/system/servers/net_server -waitstart
start beos/bin/dhcp_client -E
start beos/bin/ftpd -E
start beos/bin/telnetd -E
start beos/system/servers/mail_daemon -E
```

The `-E` means *only if enabled in the settings*. So the daemons were always
going to start; the station simply had no network settings file at all. Ticking
**FTP server** and **Telnet server** on the Network preflet's **Services** tab,
setting **Login Info…**, and saving is the whole installation.

| | |
|---|---|
| kind | `telnet_unix_e` — the SAME kind sunos414 uses. No new exec kind, no new host client, no new protocol. |
| host / port | `10.99.0.16:23` (`exec_host` in the registry), directly over the bridge. There is no slirp on this station any more and therefore no hostfwd. |
| user | `baron` (`exec_user`). R5's traditional single user; `$HOME` is `/boot/home`. |
| password | `registry/local.env` `RN_BEOS_EXEC_PASS` (gitignored). The launcher republishes it into `<station dir>/telnet-exec.passwd`, mode 0600, on every start, and `labctl` reads it from there — **never from the committed registry**. Same rule and shape as rhapsody's `serial-exec.passwd`. |
| client | `/root/sunexec.py` (`streamhost/guest-agents/sunos414/sunexec.py`) |
| shell | `exec_shell: "sh"` in the registry → `SUN_RC=$?`. This has to travel all the way through `LABCTL_KEYS` → `labctl-declarations.json` → `labctl gen` → `stations.json`; a key that is set in the station file but missing from the allowlist is dropped silently and the exit code is then `-1` on every call while the output looks perfect. |
| wake | the `telnet_unix_e` arm re-issues QMP `cont` every 15 s for as long as the client runs. `ensure_running` only thaws the guest **once**, and the daemon's reconciler re-asserts idle-pause ~60 s after the last visitor — which a telnet login plus one command on a TCG guest outlives. Measured: a `labctl exec beos "uname -a"` against a fully idle-paused station takes **~29 s** end to end and succeeds; without the keepalive it timed out on an empty read. |

Two env knobs were added to that client so one file serves both stations, and
**both default to sunos414's behaviour**, so that station is byte-for-byte
unaffected:

- **`SUN_PASS`** — the answer to the guest's `Password:` prompt. Default `""`,
  which is right for a fresh suninstall root. beos sets it.
- **`SUN_RC`** — how the guest's login shell spells the last exit code. Default
  `$status` (sunos414's login shell is csh). **beos' login shell is bash, so it
  needs `$?`**, which the registry requests with `exec_shell: "sh"`. Get this
  wrong and there is no error anywhere: the command output is perfect and the
  exit code is silently `-1` on every single call.

The login, for the record — this is what the client matches against:

```
BeOS (beos) (p1)
beos login: baron
Password:
Welcome to the BeOS shell.
$
```

### Delivering files into the guest — ftpd on `:21`

This is the other half of the handoff, and it is proven, not assumed. R5's ftpd
is a **standalone daemon**, not an `inetd` service (R5 has no classic `inetd` —
each service in `Netscript` is its own process), and it is switched on by the
same **Services** checkbox as telnetd, with the same `baron` login.

From labhost, with `ftplib`:

```
banner: 220 beos FTP server (Version 5.60) ready.
login : 230 User baron logged in.
pwd   : /boot/home
stor  : 226 Transfer complete.
round-trip identical: True 6000 bytes
mkd   : /boot/home/ftp-delivery-testdir
```

STOR, RETR (byte-identical round trip) and MKD all work, `$HOME` is
`/boot/home`, and the guest sees the file immediately (`sh` ran it and printed
its output through `labctl exec`). That is a complete source-tree delivery
route: `MKD` the tree, `STOR` the files, build over `labctl exec`.

**But a raw FTP (or telnet) client from labhost does NOT wake the guest.** Only
`labctl` calls `ensure_running`. Against an idle-paused station a bare
`ftplib.FTP().connect()` fails with `No route to host` and looks like a network
fault. Two ways round it, and for phase 2 the second is the right one:

- for a one-off transfer, hold the guest awake with a `cont` every ~10 s
  (momentary connect → `cont` → close on the QMP socket; **never hold the QMP
  connection open** — this build serves a limited number of concurrent QMP
  clients and the daemon already holds one, so a persistent extra connection
  makes `labctl shot` and pointer calls fail with `EAGAIN`);
- for a **long** session — and a gcc build on a TCG guest is a long session —
  turn idle-pause off properly: put `SH_IDLE_PAUSE_SECS=0` on its own line in
  the station's `station.env`, `systemctl restart streamhost@beos`, confirm
  `idle auto-pause OFF` in the journal, and **remove it when you are done**.

### Containment: the door opens inward only

The exec channel is **labhost-initiated** — `labctl` dials the guest, the guest
never dials labhost. So its traffic passes `BEOSRN-IN` as `ESTABLISHED` while
every NEW flow the guest starts toward labhost is dropped. The guest's own
`netstat` shows exactly that posture, and it is the proof that the door did not
become a hole:

```
-Local Address- LPort Remote Address- RPort ---State--- RecvQ SendQ
     10.99.0.16    21         0.0.0.0     0      LISTEN     0     0
     10.99.0.16    23         0.0.0.0     0      LISTEN     0     0
     10.99.0.16    23       10.99.0.1 48372 ESTABLISHED     0     0
```

`ftpd`/`telnetd` bind `0.0.0.0`, but the only network the guest has is
`vmbr-rn`, which has no uplink — so "everywhere" is the retronet and labhost,
and labhost is the only one that may open a connection.

## Seamless web — DHCP + no proxy, and no resolv.conf

The station browses the corpus with nothing configured but DHCP. R5's
`dhcp_client` is better behaved than Solaris' `dhcpagent`: it writes the
DHCP-supplied DNS **into R5's own settings file itself**, so there is no
resolv.conf step and no manual DNS entry. R5 does not use
`/boot/beos/etc/resolv.conf` at all — the resolver reads the settings file, and
looking for a resolv.conf to "fix" is a dead end.

`/boot/home/config/settings/network` after the lease (password redacted):

```
GLOBAL:
	HOSTNAME = beos
	USERNAME = baron
	FTP_ENABLED = 1
	TELNETD_ENABLED = 1
	DNS_ENABLED = 1
	DNS_DOMAIN = retronet.lab
	DNS_PRIMARY = 10.99.0.2
	DNS_SECONDARY =
	ROUTER =
	IP_FORWARD = 0
	VERSION = V1.00
	INTERFACES = interface0
interface0:
	DEVICECONFIG = etherpci
	DEVICELINK = /dev/net/etherpci/0
	DEVICETYPE = ETHERNET
	IPADDRESS = 10.99.0.16
	NETMASK = 255.255.255.0
	PRETTYNAME = NE2000 compatible PCI (1)
	ENABLED = 1
	DHCP = 1
```

**`ROUTER =` is empty, and that is containment Lock 1 written down by the guest
itself.** The lease carries an IP, a mask and a DNS server and nothing to route
through, so R5's own stack refuses every off-subnet packet with *"Network is
unreachable"* before a firewall is ever consulted.

Proven from inside the guest: `ping spacejam.com` answers **from 10.99.0.2**,
and NetPositive renders the corpus at full 1024×768 with no proxy configured
anywhere.

### What NetPositive does with each kind of page — all three PASS

The corpus is late-90s content, so a 2000-era renderer was never the risk there.
The open question was our **own lab-authored pages**, which are modern HTML/CSS.
All three were checked on the framebuffer, and NetPositive renders every one of
them correctly:

| Page | URL | Result |
|---|---|---|
| A corpus page | `http://spacejam.com/` | **PASS.** Full colour, every image, the imagemap live (the status bar reports `.../bin/index.map?x,y` on hover). Indistinguishable from the real thing. |
| The museum search UI + results | `http://search.retronet/`, then `?q=modem` | **PASS.** The front page and the results page both lay out correctly: "Documents 1-10 of about 446", ranked hits with title links, snippets with the query term bolded, corpus URLs in green, `[score N]`, and a working search form. |
| A deliberate proxy miss | `http://www.nosuchsite-kernelhive.com/` | **PASS.** The "Not in the Museum's Internet" page renders with correct headings, rules and typography, a working search box, and the AltaVista/Yahoo-style entry links. Window title picks up `404 Not Found`. |

So there is **no** finding to hand on here: the lab pages do not out-run this
renderer, and nothing needs redesigning for BeOS. §Evidence frames has the shots.

## The ready scene, and why it is a boot script

`streamhost/stations/beos/UserBootscript` is tracked in the repo and installed
at `/boot/home/config/boot/UserBootscript`. It launches the Terminal (the
original fixture), then NetPositive on a corpus page, then
`icbm-watchdog.sh` — which is what starts ICBM, rather than the boot script
launching the client directly. That indirection is the point: the same loop that
brings ICBM up at boot is the one that brings it back after the gateway drops
it, so there is exactly one place that owns "is the client signed on".

The **wait** in it is load-bearing: `UserBootscript` can win the race against
`dhcp_client`, and a NetPositive that starts before the lease resolves nothing
and paints an error page — which is then exactly what a cold-booted fixture
looks like. It polls the gateway until it answers, then opens the browser.

Keeping this as a boot script rather than hand-arranging windows before the bake
means the fixture is **reproducible from a cold boot**, not only from `loadvm`,
which is what made the MAC re-bake and the golden re-bake cheap and repeatable.

## Containment — proven from inside the guest (`10.99.0.16`)

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (ICMP) | **reply**, 7–14 ms | intra-bridge L2 (the point) |
| CT `10.99.0.2:80` (corpus web) | **OPEN** | intra-bridge L2 (the point) |
| CT `10.99.0.2:5190` (OSCAR) | **OPEN** | intra-bridge L2 (ready for phase 2) |
| `spacejam.com` → `10.99.0.2` | **resolves + reply** | DNS via DHCP, no proxy |
| labhost bridge `10.99.0.1` (ICMP) | **timed out**, 3/3 | the guard chain `BEOSRN-IN` |
| gallery `10.99.0.1:8443` | **BLOCKED (timeout)** | `BEOSRN-IN` |
| labhost `10.99.0.1:22` | **BLOCKED (timeout)** | `BEOSRN-IN` |
| internet `1.1.1.1:443` | **Unable to connect: General OS error** | no default route (Lock 1) |
| internet `8.8.8.8` (ICMP) | **Network is unreachable** | no default route (Lock 1) |

Same three-layer model as win98se and solaris (topology → no-default-route →
the fail-closed per-guest INPUT chain). The live chain:

```
-A BEOSRN-IN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A BEOSRN-IN -j DROP
-A INPUT -i vmbr-rn -m mac --mac-source 52:54:00:52:4e:10 -j BEOSRN-IN
-A INPUT -s 10.99.0.16/32 -i vmbr-rn -j BEOSRN-IN
```

**Two hooks, and the second one is not decoration.** The fleet convention scopes
the guard chain to the guest's IP, and that alone contains the guest exactly as
long as the guest keeps the IP you expect. This station showed the hole: after a
warm QMP `system_reset` (as opposed to a QEMU restart) R5's `dhcp_client` sent
its DISCOVER with an **all-zero chaddr**, `retronet-dhcp` could not match the
reservation, and the guest came up on a **pool** address — `10.99.0.100`, still
route-less so still no WAN, but no longer matched by an `-s 10.99.0.16` rule and
therefore free to dial labhost's own listeners. The second hook scopes the same
fail-closed chain to the guest's source **MAC**, which is the station's stable
identity: the NIC keeps transmitting with it even when the DHCP payload does
not, so containment follows the guest to whatever address it lands on. Both
hooks are read back by `verify_rules`, so the launch aborts if either is
missing. (physdev matching is the obvious alternative and does **not** work
here: the box runs `bridge-nf-call-iptables=0`, so nothing populates physdev.)

**Never warm-reset this station.** Use `systemctl restart streamhost@beos`,
which gives QEMU a fresh NIC from the launcher's `mac=`. A `system_reset` is
what produced the zero-chaddr lease above.

R5 has no `nc` and its `sh` has no timeout builtin, so the TCP rows were taken
with a small in-guest prober that runs `telnet host port < /dev/null` under a
background killer and **classifies on what telnet printed**, never on exit
timing — R5's `sh` keeps `kill -0` succeeding on an unreaped child, so timing
says "timeout" even for a connection that plainly succeeded. The prober is
reproduced in §Operating it; it is deliberately not left on the golden.

## Gotchas that cost real time

**The pointer is relative, and its gain is not a constant.**
R5 has no absolute tablet, and it applies its own acceleration on top of the raw
PS/2 delta stream — and the gain depends on *how fast the deltas arrive*, not
just their size. There is no open-loop "send N unit deltas" formula that lands
on a target twice in a row: measured on this guest, the same 668-px request
landed at 776 px at one event rate and at 670 px at another. Scripted pointer
work therefore has to be **closed loop**: slam to `(0,0)` with a burst of large
negative deltas (the guest clamps there, and that is the only absolute reference
a relative device has), screendump that as a reference, step toward the target,
screendump, locate the cursor by frame diff, and repeat the residual. Two
iterations converge to within a few pixels. The driver used here is
`streamhost/stations/beos/beosptr.py`.

**The GUI can wedge while the kernel stays perfectly healthy.**
After a long framebuffer-driven session the Deskbar clock froze at 3:35 while
the guest's own `date` said 3:54, the cursor stopped being drawn, and keystrokes
stopped reaching the active window — and all the while `telnet`, `bash`,
`net_server` and `ps` were completely responsive over the exec channel, and
`input_server` was alive with its event loop running. **Do not read a frozen
Deskbar clock as "the guest is hung"**; check the exec channel first. A reboot
clears it. This is a good reason to prefer the exec channel over framebuffer
typing for everything except what genuinely needs the GUI.

**Idle auto-pause will freeze a cold boot half-way.**
The station idle-pauses when no streamhost visitor is connected, and a cold boot
with nobody watching simply stops (`query-status` → `paused`) with no DHCP and
no desktop. Set `SH_IDLE_PAUSE_SECS=0` in the station's `station.env` while
working — it is a systemd `EnvironmentFile`, which does **not** strip trailing
comments, so the value must be alone on its line and any comment on its own.
Confirm with `journalctl -u streamhost@beos | grep idle` → `idle auto-pause OFF`,
and **remove the override before calling the station done**.

**Idle auto-pause also silently eats a `cont`.** Resuming the guest by hand with
QMP `cont` and then doing something slow does not work with idle-pause on: the
daemon re-pauses 60 s later (`[idle] no sessions for 60s -> guest paused`) and
the next probe gets `No route to host`. `labctl exec` is fine — it calls
`ensure_running` first — but a raw client dialling the guest IP is not. Use
`labctl exec`, or turn idle-pause off while working.

**`kill` takes a thread, not a team.** `kill 533` on a team id says *No such
thread*, and `kill -9 <main thread>` did not take down NetPositive either. Quit
BeOS applications through the GUI, or just reboot — which is what the boot
script makes cheap.

**R5's `netstat -r` is not a routing table.** It ignores the flag and prints
interfaces plus TCP state. The route posture is read off `ROUTER =` in the
settings file, and confirmed by the guest's own *"Network is unreachable"*.

**Do not look for `ifconfig`.** R5 has none. Interfaces are configured by
`net_server` from `/boot/home/config/settings/network`, and that file is written
by the Network preflet. `dhcp_client`, `ftpd`, `telnetd`, `ftp`, `telnet`,
`ping`, `netstat` and `hostname` are all in `/boot/beos/bin`.

## The cold re-bake

The MAC lives in the golden's device vmstate, so `loadvm` restores the **saved**
MAC no matter what the launcher's `mac=` says. Changing it requires a cold boot:

1. Back the golden up byte-for-byte with QEMU stopped, and `sha256sum -c` it —
   this is the change-level rollback (the guard takes its own per-run copy too).
2. Apply the DHCP reservation for the NEW mac on the gateway **first**
   (`install-dhcp.sh --apply`).
3. `qemu-img snapshot -d golden` on the disk so the launcher cannot fall through
   to `-loadvm`.
4. Boot cold with the new `mac=`, do the in-guest work, then recapture with
   `ssh lab 'checkpoint-guard recapture beos'` — it handles a first capture with
   no label present, and asserts the restored guest is **running** (a checkpoint
   captured while stopped restores paused: perfect screenshot, dead station).
   [`checkpoint-guard.md`](../checkpoint-guard.md).
5. Verify **in the bridge FDB** (`bridge fdb show dev beosrn0` → the new MAC)
   **and** in the gateway's DHCP log (`… 52:54:00:52:4e:10 -> ACK 10.99.0.16`).

Both verifications passed here.

### What forces a re-bake here, and what does not

The launcher's own comment reads as a contradiction if taken in isolation, and it
misled a later agent into the right plan for the wrong reason. It says the netdev
backend went `user` -> `tap`, that this is **"invisible to savevm/loadvm"**, and
then that **"the pre-swap slirp golden does NOT loadvm on the tap"**. Both are
true, and the resolution is the sentence at the top of this section rather than
anything about the backend:

| change | forces a cold re-bake? | why |
|---|---|---|
| netdev backend `user` -> `tap` | **no** | genuinely invisible to `savevm`/`loadvm`; it is a host-side plumbing property and nothing about it is captured |
| **MAC** | **YES** | it lives in the golden's **device vmstate**, so `loadvm` restores the *saved* MAC whatever the launcher's `mac=` says |
| `-device` model, e.g. `ne2k_pci` -> `rtl8139` | **YES** | `loadvm` is only valid against the device set it was baked with |

The pre-swap slirp golden therefore fails to restore usefully on the tap because
it carries a **different MAC in its vmstate**, not because the backend changed.
The `rtl8139` swap would have forced a re-bake on its own, but it **cost nothing
extra** because the MAC change had already forced one — which is why the two land
in the same bake and are easy to mistake for one cause.

**Why the distinction is worth keeping straight.** Believing the *backend* is what
`savevm` captures leads directly to concluding that a substitute MAC would be safe
for a bake — the one thing that cannot work, since the MAC is precisely what is
baked. And believing the *NIC model* was the sole blocker leads to the opposite
error: assuming an unenslaved, bridgeless tap is unsafe for `loadvm` when it is
perfectly safe, because bridge membership is pure backend. A rig on a bridgeless
tap with an **unchanged** `-device` and the **same** MAC restores the golden
correctly and can sit beside the live station.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** in
  `/data/vms/streamhost/stations/beos/beos-golden.qcow2`, **re-baked
  2026-08-23** by the ICQ errand (`bridge-bake-golden`, restore-verified;
  VM_SIZE 168 MiB → 412 MiB). **Tap-native + DHCP + MAC
  `52:54:00:52:4e:10`**, with NetPositive on a corpus page, ICBM signed on as
  `50000` with its contact-list window open, and `icbm-watchdog.sh` running.
  `labctl reset beos` = `loadvm golden`. The MAC and device set are unchanged
  from the phase-1 cold bake, so this was a warm re-bake of the running
  station, not a cold boot.
- **Pre-retronet backup** (the hand-baked 2026-08-18 slirp golden; QEMU stopped,
  full byte copy, SHA256-verified, and it still carries its internal `golden`
  snapshot so it is directly `loadvm`-able once restored):
  `/data/gallery-guests/Beos/golden-backup-rn-netswap-20260822/`
  — `beos-golden.qcow2`, sha256
  `f39ae8d6fca8d9071d7818b0a3dcb91f97e9d447fbdd14136f163fdb62d13b0d`,
  `SHA256SUMS` in the dir. **This is the rollback for the whole swap.** Before
  this errand the hand-baked golden had no verified backup at all.
- **Pre-ICQ-errand backup** (2026-08-23, taken with QEMU stopped, full byte
  copy, `cmp`-verified byte-identical against the live file, and it carries its
  internal `golden` snapshot so it is directly `loadvm`-able):
  `/data/gallery-guests/Beos/golden-backup-prephase2-icq-20260823/`
  — `beos-golden.qcow2`, sha256
  `f961bfaa4523ccad439df1f526714d2f6f48186e51922c293d1a7978fafaa9ae`,
  `SHA256SUMS` in the dir. **This is the rollback for the ICQ errand**: it is
  the last golden without ICBM in it, and it is `loadvm`-able as it stands.
  Restoring it removes the ICQ client and returns the station to
  retronet+NetPositive only; the repo-side undo is this document, the registry
  note, `roster.json` (`onboarded` back to false), the `beos-*` pairs in
  `box-sync-pairs.sh`, `icbm-watchdog.sh`, the `UserBootscript` line that starts
  it, and dropping `50000:beos` from `RN_BOT_PERSONAS` in
  `/etc/retronet/bot.env`.
- The pristine, never-booted-by-the-station image
  `/data/gallery-guests/Beos/beos-r5.qcow2` remains as the older backstop.

Full rollback:

```bash
systemctl stop streamhost@beos
cd /data/gallery-guests/Beos/golden-backup-rn-netswap-20260822
sha256sum -c SHA256SUMS          # f39ae8d6… — verify BEFORE trusting it
cp beos-golden.qcow2 /data/vms/streamhost/stations/beos/beos-golden.qcow2
# revert the launcher + tap script (git), the registry exec_* block, and the
# gateway reservation (drop 52:54:00:52:4e:10 from RETRONET_DHCP_RESERVATIONS in
# registry/local.env, then install-dhcp.sh --apply)
bash /data/vms/streamhost/stations/beos/rn-tapnet.sh down   # releases beosrn0 + BEOSRN-IN
systemctl start streamhost@beos
```

The backup carries its own `golden` snapshot, so it restores straight into
instant-resume; no re-bake is needed on rollback.

## Evidence frames

Kept beside the golden backup, not in a sandbox that gets pruned —
`/data/gallery-guests/Beos/evidence-rn-beos-net-20260823/` (QMP `screendump`
PPMs, 1024x768, `SHA256SUMS` in the dir):

| file | what it shows |
|---|---|
| `01-golden-fixture-corpus-page.ppm` | the shipped golden's fixture, restored by `loadvm` |
| `02-netpositive-search-results.ppm` | `search.retronet/search?q=modem` — 446 ranked hits |
| `03-netpositive-proxy-miss.ppm` | the proxy's "Not in the Museum's Internet" page |
| `04-r5-network-preflet.ppm` | R5's Network panel, driven entirely by relative PS/2 deltas |
| `05-prebake-frame.ppm` | the clean frame the golden was baked from |
| `06-restored-from-golden.ppm` | the same frame after `loadvm` — differs only in the Deskbar clock (183 px) |

From the first (abandoned) ICQ pass —
`/data/gallery-guests/Beos/evidence-rn-beos-icq-20260823/` (PNG, 1024x768,
`SHA256SUMS` in the dir):

| file | what it shows |
|---|---|
| `01-icbm-signed-on-deskbar-green.png` | ICBM signed on as UIN `50000` over legacy UDP 4000, with **no** contact-list window. Kept because it is the failure mode a wrong first launch produces — set `uin`/`password`/`autologin` before the first run and the window is there (frame `03` below) |
| `02-toolchain-restored-gui-proof.png` | a titled BeOS window from a `BApplication` compiled **in the guest** with the recovered gcc 2.9-beos, linked against `libbe` |
| `03-fixture-intact-after-teardown.png` | the phase-1 fixture after teardown — Terminal + NetPositive on the corpus page, unchanged |

From the errand that shipped the client —
`/data/gallery-guests/Beos/evidence-rn-beos-icbm-20260823/` (PNG, 1024x768,
`SHA256SUMS` in the dir):

| file | what it shows |
|---|---|
| `01-greeting-window-hivebot.png` | HiveBot's greeting, in a chat window ICBM opened **by itself** (`incomingopen`), titled `HiveBot [10000]` — the seeded People file is why it is a name and not `10000 [10000]` |
| `02-llm-conversation.png` | the full round trip on the framebuffer: greeting, the visitor's typed reply, and the LLM's answer back |
| `03-ready-scene-signed-on.png` | the shipped ready scene — Terminal, NetPositive on a corpus page, ICBM's contact list with HiveBot under **Online** |
| `04-restored-from-golden.png` | the same scene after `labctl reset beos`, i.e. what every visitor actually gets |

## Operating it

```bash
ssh lab 'labctl exec beos "uname -a"'                  # exec over the bridge
ssh lab 'labctl exec beos "cat /boot/home/config/settings/network"'   # IP, DNS, empty ROUTER
ssh lab 'labctl exec beos "netstat"'                   # interfaces + who is connected
ssh lab 'labctl exec beos "ps | grep NetPositive"'     # is the browser up
ssh lab 'bash /data/vms/streamhost/stations/beos/rn-tapnet.sh show'   # tap + guard chain
ssh lab 'bridge fdb show dev beosrn0'                  # the unique MAC, on the right port
ssh lab 'pct exec 951 -- journalctl -u retronet-dhcp | grep 4e:10'    # the lease
ssh lab 'labctl shot beos /tmp/beos.png'               # the framebuffer is the only proof
ssh lab 'labctl reset beos'                            # loadvm golden

# --- the ICQ half ---
ssh lab 'labctl exec beos "ps | grep ICBM"'            # client + watchdog alive
ssh lab 'labctl exec beos "tail -40 /boot/home/icbm.log"'   # the packet log; the fastest instrument here
ssh lab 'labctl exec beos "listattr /boot/home/config/settings/BeCQ-50000/BeCQ-preferences"'
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"id\"] for s in json.load(urllib.request.urlopen(\"http://127.0.0.1:8080/session\"))[\"sessions\"]])"'
ssh lab 'journalctl -u retronet-bot --since -10min | grep 50000'   # presence + GREETED
ssh lab 'pct exec 951 -- journalctl -u retronet-oscar -n 50 | grep ICQLegacy'
```

Forcing a greeting by hand (what a visitor gets for free): make the persona go
offline and come back. `systemctl restart retronet-bot` re-reads presence and
re-greets everything it believes newly online, which is the cheapest way to see
the whole chain on the framebuffer without waiting for an idle cycle.

The in-guest TCP prober used for the containment table (not left on the golden):

```sh
#!/bin/sh
# tcpprobe HOST PORT [SECS] — classify a TCP connect from inside BeOS R5.
H=$1; P=$2; T=${3:-8}
rm -f /tmp/.tp.out
telnet $H $P < /dev/null > /tmp/.tp.out 2>&1 &
pid=$!
( sleep $T; kill -9 $pid 2>/dev/null ) > /dev/null 2>&1 &
wid=$!
wait $pid > /dev/null 2>&1
kill -9 $wid > /dev/null 2>&1
o=`tr -d "\r" < /tmp/.tp.out | tr "\n" " "`
case "$o" in
  *Connected*)               echo "$H:$P OPEN" ;;
  *refused*|*Refused*)       echo "$H:$P REFUSED     [$o]" ;;
  *nreachable*)              echo "$H:$P UNREACHABLE [$o]" ;;
  *)                         echo "$H:$P BLOCKED (timeout) [$o]" ;;
esac
```

## The ICQ client — ICBM .71 (BeCQ)

The station signs in to the gateway as UIN **`50000`** with **ICBM .71**, and
this is the only station on the fleet that reaches the gateway through the
**pre-OSCAR UDP 4000 door**. Everything else is behind a slirp `guestfwd`, which
is TCP-only; beos is on a real bridge, so the legacy door is reachable at all.

**What it is.** *Inter-Continental Ballistic Messenger*, the continuation of the
open-source **BeCQ** project — a native BeOS ICQ client with a contact list,
chat windows, history and a Deskbar replicant. **GPL-2.0**, dated
**2001-02-10**, shipped as a prebuilt `ICBM.x86` for "Intel/PPC R4.5 and R5", so
it needs no compiler. Era-correct for a 2000 machine. Recovered from
`icbm.8k.com` via the Wayback Machine (`curl` from Bash; `WebFetch` cannot reach
`web.archive.org`), archived as sha256
`c8902f40714ef439a8abf5d8c92982eb144bc10ee0a0fb30f4255e08b8dd2dd1`
(182 919 bytes, `ICBM.71.zip`). Installed at `/boot/home/apps/ICBM/` with its
`Readme.txt` and `COPYING-2.0` beside it.

### The Readme's `NetPacket.h` bug is not in the shipped binary

This matters because it was the reason a previous pass abandoned ICBM, and it is
checkable in ten seconds without a guest. ICBM's own Readme warns that R5's
`add-ons/netserver/NetPacket.h` declares `BStandardPacket::operator new` /
`operator delete`, that this breaks the client at runtime, and that the remedy
is to comment those two lines out **and recompile** — which we cannot do,
because no `.71` source survives.

The shipped binary does not need it. `nm -D` on `ICBM.x86` lists
`__15BStandardPacketUi` (the constructor) and `Base__15BStandardPacket`, and
**no `__nw__15BStandardPacket…` / `__dl__15BStandardPacket…` import at all** —
while `__nw__8BMessageUl` and `__nw__10BGameSoundUl` *are* imported, so the
compiler was plainly emitting class-scoped `new` where a class declared one.
The author built `.71` with the fix already applied. The Readme is advice for
people compiling from source, not a description of this artefact.

```bash
nm -D ICBM.x86 | grep -E 'StandardPacket|__nw__|__dl__'
```

The binary is also a gift for debugging: it is not stripped of dynamic symbols
and exports its own class methods with full gcc-2 signatures
(`HandlePacket__10BeCQServerP10BeCQPacket`, `EncDecV4Packet__10BeCQPacket`,
`PacketIsDuplicated__10BeCQServerl`, …), and it writes a verbose packet log to
stdout. That log is the fastest instrument on this station — it prints every
`ReceivePacket [Cmd: 0x….] [Seq: …]` with a hexdump, so the wire can be read
without a `tcpdump`.

### Configuration is BFS attributes, so the whole install scripts

There is no config file. `/boot/home/config/settings/BeCQ-preferences` is a
**zero-byte** file whose *attributes* are the settings, with a per-UIN mirror at
`…/BeCQ-<UIN>/BeCQ-preferences` and a `contacts/` directory beside it. So the
client is configured entirely from the exec channel with `addattr`, with no
pointer work at all:

```sh
F=/boot/home/config/settings/BeCQ-preferences
addattr -t int  uin 50000 $F          # NB: the type is "int", not "int32"
addattr -t string password '<pass>' $F
addattr -t bool autologin 1 $F        # NB: 1/0 — "true" silently stores 0
```

Set those **before the first launch** and ICBM comes up already signed in, with
its contact-list window open. It then writes the full schema on a clean quit
(`quit application/x-vnd.ICBM`), which is the moment to set the two that matter
for an exhibit:

| attribute | value | why |
|---|---|---|
| `incomingopen` | **1** | an incoming message **opens its chat window by itself**. This is the whole visitor-facing behaviour: HiveBot's greeting arrives and a real window appears, unprompted. Default is 0, and with 0 the greeting lands silently in a collapsed list. |
| `entertosend` | **1** | Enter sends. A visitor should not have to find the Send button. |
| `serversend` | 1 (already the default) | route messages through the server instead of ICBM's direct client-to-client TCP. Correct for containment, and the bot has no direct-TCP listener anyway. |

**`mimeset -f` is mandatory after an FTP delivery.** A BeOS application's
signature lives in its ELF resources, but the roster only sees it once the
`BEOS:APP_SIG` / `BEOS:TYPE` *attributes* are derived from them, and FTP carries
no BFS attributes. Before `mimeset`, ICBM runs but never registers; after it,
`roster` shows `application/x-vnd.ICBM`.

### HiveBot shows as a name, not a number — one seeded contact

An unknown sender shows in the chat window's title bar and From column as a bare
UIN (`10000 [10000]`), because ICBM never asks the server for a stranger's
directory nickname. A contact is just a **BeOS People file** at
`contacts/<uin>`, so seeding the one contact that matters is three lines:

```sh
C=/boot/home/config/settings/BeCQ-50000/contacts/10000
touch $C
addattr -t string BEOS:TYPE application/x-person $C
addattr -t int    BECQ:uin 10000 $C
addattr -t string META:name 'HiveBot' $C
addattr -t string META:nickname 'HiveBot' $C
addattr -t bool   META:shownick 1 $C
addattr -t bool   BECQ:authorised 1 $C
addattr -t bool   BECQ:onlinealert 0 $C
mimeset -f $C
```

ICBM reads `contacts/` once at startup (`List: found 1 contacts`), so this needs
a relaunch, not a golden re-bake of a GUI-driven Add flow. The full attribute
set it understands is `BECQ:uin`, `BECQ:authorised`, `BECQ:onlinealert`,
`META:name`, `META:email`, `META:nickname`, `META:shownick`.

**Only HiveBot is seeded.** The other stations are deliberately *not* in ICBM's
list: the server-side SSI cross-list is written for `50000` like every other
live station, but ICBM keeps its contacts locally and never reads SSI, so the
exhibit shows one contact — the one a visitor actually talks to. The reverse
direction is live: beos is `"onboarded": true` in
[`roster.json`](../../../scripts/retronet/icq/roster.json) and appears in the
other five stations' rosters.

### The watchdog, and why the station needs one

**ICBM .71 has no auto-reconnect.** When the gateway drops the session it sends
`0x00F0`, and ICBM's log reads:

```
Server:	ReceivePacket	[Cmd: 0x00F0] [Seq: 0x0]
Server:	Disconnection started
Server:	Disconnection finished
Server:	SendPacketLoop	break!
```

…and then nothing, for ever. It also sends **no `CMD_LOGOUT` (0x03FC)** on quit,
so a clean exit does not tell the server anything either.

That is fatal on this station in a way it would not be on a workstation: `beos`
is `loadvm golden` + idle-pause, so every visitor restores a snapshot whose
in-RAM session the server forgot minutes ago, and the greeter bot only fires on
a **sign-on**. Sibling stations get the reconnect for free — ICQ 2001b self-heals
after its zombie socket is nudged, Gaim has autorecon in-core. On BeOS it has to
be supplied.

[`icbm-watchdog.sh`](../../../streamhost/stations/beos/icbm-watchdog.sh) is the
supply, and relaunching **is** the reconnect: `autologin` is set, so a fresh
ICBM signs straight back in. It loops every 10 s and does exactly two things —
launch ICBM if the process is gone, and quit-and-relaunch it if the last
`Disconnection finished` in the log is newer than the last `LoginSuccessful`.
Both markers are ICBM's own, and the log is truncated on every launch, so the
line numbers are always relative to the current run. It lives at
`/boot/home/config/boot/icbm-watchdog.sh` and is started by `UserBootscript`.

**Wake detection was tried and deliberately left out.** The obvious refinement —
notice the guest was paused by watching `date +%s` jump, and force a fresh login
immediately — does not survive this guest. Under TCG with QEMU's timer catch-up
the BeOS clock does not merely resume, it *runs fast* to make up the missed
ticks (measured: 24 m 25 s of guest time across 16 m 42 s of real time), so a
"the clock jumped, we must have been paused" test also fires while a visitor is
sitting in front of a running station — and the cost of a false positive is
their chat window closing mid-conversation. The latency it would have saved is
described below and is not worth that.

### How a visitor gets greeted, and how long it takes

The cycle is the gateway's session reaper plus ICBM's keepalive, and it was
measured end to end on the live station:

| | |
|---|---|
| station idle-pauses (60 s grace) | ICBM stops sending keepalives with it |
| ~120 s later | `ICQ_LEGACY_SESSION_TIMEOUT` expires the legacy session and the gateway **does** broadcast the departure — `retronet-bot`: `presence: 50000 offline` |
| a visitor opens the station | the guest resumes; ICBM's next keepalive (~100 s interval) lands on a server that no longer has the session, and the server silently re-creates it |
| that arrival is a sign-on | `50000 (beos) signed on — greeting in 30s` → `GREETED 50000 (beos)` |

Measured twice on 2026-08-23, the second time as the acceptance run against the
deployed commit: reaped 13:43:29 → signed on 13:44:02 → greeted 13:44:32, and
reaped 14:32:25 → woken the same second → signed on 14:33:25 → greeted 14:33:55.
So the greeting lands **60–120 s** after a visitor arrives, against ~30 s on the
ICQ-2001b stations, and the variable part is which point of ICBM's ~100 s
keepalive cycle the wake falls in.

Two consequences worth stating plainly:

- **Back-to-back visitors share one greeting.** If the station was idle for less
  than about three minutes the persona never went offline, so there is no new
  sign-on and no new greeting — `retronet-bot` logs `arrival while already
  online — duplicate, not greeting again`. [`BOT.md`](BOT.md) already accepts
  that outcome for the fleet; on beos the window is a little wider.
- **The way to close the gap is a host-side nudge**, not a guest-side timer: the
  fleet already has that shape in `win98se-icq-nudge` / `nt4-icq-nudge`. It
  would have to watch QEMU's run state over momentary QMP connects (never a held
  connection — see §Gotchas) so that polling does not itself keep the guest
  awake, and quit ICBM on a paused→running edge. Not built; the exhibit works
  without it.

### Proven, on the live station

| | evidence |
|---|---|
| signs on over legacy UDP 4000 | gateway `V4 login attempt uin=50000` → `user authenticated successfully version=4`; ICBM's own `App: LoginSuccessful`; management API `/session` lists `50000` |
| the DNS hijack carries the shipped default | `App: Connecting... [icq.mirabilis.com:4000]` — no server override set anywhere |
| receives an OSCAR-originated message | `Server: SERVER_INSTANT_MESSAGE - 10000, 1` → `ProcessMessage type = 1, uinfrom = 10000`, and the greeting text in the BMessage |
| the chat window opens by itself | framebuffer: `HiveBot [10000]`, From `HiveBot`, the greeting in the list, a Send box below |
| the visitor can reply | `labctl type` + Enter → `retronet-bot`: `<- 50000: hi! yes, BeOS R5 here` → LLM reply `-> 50000: woah, still running R5? …` back on the framebuffer |
| survives a pause | 3 m 30 s QMP `stop`/`cont` — session intact, messaging still works afterwards |
| the golden restores signed on | after `labctl reset beos`: contact list up, HiveBot under **Online**, ICBM in the Deskbar |
| it stays up | a liveness sampler took the client's process count every ~110 s from 12:35 to 14:21 — **57 consecutive samples, ICBM alive in every one**. The first pass's "exits unattended within minutes" does not reproduce; what it most likely saw was the client sitting disconnected after a teardown it never recovers from, which is what the watchdog now handles |

### The one thing the gateway does not do

`CMD_ACK_MESSAGES` (0x0442, sent once per login after
`SRV_END_OF_OFFLINE_MESSAGES` to purge offline messages) is **never ACKed** by
Open OSCAR Server. ICBM retries it five times and gives up —
`SendPacketLoop [Cmd: 0x0442] [Seq: 0x7] -- FAILED!`. It is bounded, once per
login, and has no visible effect; every other command the client sends
(`CMD_LOGIN`, `CMD_LOGIN_1`, `CMD_LOGIN_2`, `CMD_INFO_REQ`, `CMD_STATUS_CHANGE`,
`CMD_CONTACT_LIST`, `CMD_KEEP_ALIVE`) is ACKed cleanly. Recorded here so the
next reader does not mistake it for a fault.

Two gateway details worth knowing before touching the legacy door:

- **ICQ UIN passwords are capped at 6–8 characters** by the server
  (`400 invalid password: invalid password length`). Generate 8, not 14.
- **`ICQ_LEGACY_SESSION_TIMEOUT` and `ICQ_LEGACY_KEEPALIVE_INTERVAL` are both
  120 s.** Being equal leaves a client no slack, and it is what makes the
  reap-then-greet cycle above work at all — do not raise the timeout without
  re-reading that table.

### IM Kit — measured, and still not the answer

The other candidate, kept because the measurement is worth more than the
verdict. `github.com/HaikuArchives/IMKit` at `9c80ad1`, archived as sha256
`4eb6f38c3417dc6cb99610bd02fd86b32013f938b574d31462e1bb2221bd34e0`.

**Its entire OSCAR protocol engine compiles on BeOS R5** under
gcc 2.9-beos-991026: `protocols/OSCAR/OSCARManager.cpp`, 1 842 lines, produced a
**412 356-byte object file with zero errors**, needing only two trivial shims — a
`be_prim.h` that includes `<SupportDefs.h>` (ZETA shipped `be_prim.h`; R5's
equivalent is `SupportDefs.h`), and a declaration-only `openssl/md5.h` (R5 ships
no OpenSSL; `OSCARManager` touches MD5 in exactly one place, hashing an
*optional* buddy-icon upload — ICQ login uses plain XOR password roasting and no
crypto library, so the code path is never reached). That settles the recon's
biggest open question: the "OSCAR is gated on OpenSSL" blocker really is
avoidable.

**The client that draws the buddy list is not portable.**
`clients/im_contact_list` is written against **Haiku's Layout Kit**, which does
not exist in R5 in any form — no layout-aware `BView` constructor, no
`SetLayout()`, no `BSize`/`BGroupLayout`/`BGroupLayoutBuilder`/`BLayoutUtils`/
`BControlLook`. There is also **no `jam` on BeOS R5** (the Development package
ships the GNU toolchain and `make`, not Jam) and IM Kit's whole build system is
Jam, and `common/columnlistview` ships only `haiku/` and `zeta/` variants. That
is a Haiku→R5 port of a multi-component framework, not a patch job — and with
ICBM shipping there is no reason to start it.

## Restoring the compiler — the reusable recipe

Phase 1 recorded that `/boot/develop` is empty on this station and that the
tools would have to be carved out of the disc image. They do not: the Pro CD
carries them as a **ready-made install package**, and the whole job is a mount
and a tar. This works for any BeOS R5 package, not just Development.

**1. Split the CD's tracks into 2048-byte images.** The staged medium is
`/data/assets-staging/beos/beos-5.0.3-professional-gobe.bin` (MODE1/2352, three
tracks per the `.cue`). The splitter is already in
[`scripts/build-guests/tiles/beos.sh`](../../../scripts/build-guests/tiles/beos.sh)
step 1 — take each track's sectors and keep bytes 16..2064 of each 2352-byte
sector. Track 1 is `BeOS_Tools` (ISO 9660, bootable); tracks 2 and 3 are BFS
volumes.

**2. Mount the BFS volume read-only on labhost.** No emulator, no guest:

```bash
modprobe befs
mount -t befs -o ro,loop track02.img /mnt/<your-session>/t2
```

The Proxmox kernel ships `befs.ko` in-tree. It is read-only, which is all this
needs.

**3. Take the package.** `_packages_/` on the volume holds the installer's own
package trees — `Development`, `GNU Sources`, `Media`, `Experimental`,
`us_english`, … `Development` is 63 MB and is laid out exactly as it lands on
`/boot`:

```
_packages_/Development/develop/headers/{be,cpp,gnu,posix}
_packages_/Development/develop/lib/x86/libbe.so
_packages_/Development/develop/tools/gnupro/bin/{gcc,g++,c++,ld,as,ar,nm,strip,…}
_packages_/Development/develop/tools/gnupro/lib/gcc-lib/i586-beos/2.9-beos-991026/{cpp,cc1,cc1plus,collect2,crtbegin.o,crtend.o}
_packages_/Development/beos/bin/{cc,c++,bison,flex,…}
```

**Take `develop/headers`, `develop/lib`, `develop/etc`, `develop/tools/gnupro`
and `beos/bin`. Skip `develop/BeIDE` (15.6 MB) and `PackageBuilder`** unless you
want the IDE — they are most of the bulk and nothing needs them to compile.

**4. Deliver it over the ftp door and untar in the guest** (§Delivering files
into the guest). Build **separate small tarballs**, one per subtree — see the
trap below.

**THE TRAP THAT COSTS AN HOUR: a `labctl exec` that outlives its window takes
your job down with it.** The exec channel's client has a timeout, and when it
gives up the telnet session closes and **every process started from it dies,
including one backgrounded with `&` inside a detached subshell**. A single
`tar` of the whole 19 MB tree gets killed part-way and leaves a tree that looks
plausible — in this errand it left `develop/tools/gnupro/bin` present and the
`lib/gcc-lib/…` backends missing, so `gcc` ran and reported
`installation problem, cannot exec 'cpp'`. Split the work into chunks that each
finish inside one exec:

```sh
labctl exec beos "cd /boot && gzip -dc /boot/home/dev-headers.tar.gz | tar xf - && echo OK"
labctl exec beos "cd /boot && gzip -dc /boot/home/dev-bin.tar.gz     | tar xf - && echo OK"
labctl exec beos "cd /boot && gzip -dc /boot/home/dev-gnupro.tar.gz  | tar xf - && echo OK"
```

**5. Prove it, on the framebuffer.** Compiling is not the proof; a window is:

```sh
labctl exec beos "cd /boot/home && PATH=/boot/develop/tools/gnupro/bin:/boot/beos/bin:\$PATH; \
  export PATH; gcc -o rnhello rnhello.cpp -lbe && mimeset -f rnhello && ./rnhello < /dev/null &"
labctl shot beos /tmp/proof.png
```

This errand did exactly that: `gcc --version` → **`2.9-beos-991026`**, a 24 049-byte
binary linked against `libbe`, and a titled BeOS window on a clean 1024×768
frame (`evidence-rn-beos-icq-20260823/02-toolchain-restored-gui-proof.png`).

**Remember it is transient.** The station's launcher restores `loadvm golden`,
so the whole toolchain vanishes on the next `systemctl restart streamhost@beos`
— which is exactly why it is safe to do this on a live station, and why anything
you actually want to keep has to be baked into the golden or copied back out.

## Driving the pointer — `beosptr.py`

Phase 1 described a closed-loop pointer driver but never committed one. It now
exists at
[`streamhost/stations/beos/beosptr.py`](../../../streamhost/stations/beos/beosptr.py):
`where` / `move x y` / `click x y [--double] [--button right]` / `shot out.ppm`,
talking QMP directly (momentary connect per command — never hold the socket
open, the daemon already holds one).

It converges to the pixel — measured, `move 500 400` landed `(500,401)` in 6 s —
and getting there needed three things that are not obvious:

- **R5's acceleration depends on the event RATE, not just the delta size.** A
  train of 40-unit deltas 12 ms apart travelled the full screen width; the same
  deltas 50 ms apart moved ~39 px each. So the driver holds magnitude and gap
  constant and calibrates *pixels per event*, rather than trying to compute a
  gain from the delta values.
- **The coarse phase deliberately aims at HALF the residual**, because an
  overshoot lands in a screen clamp, which destroys the position estimate and
  costs a re-slam. The last leg is a slow one-unit drip whose multiplier
  (~2.0 px/unit here) is measured live and divided out.
- **Locating the cursor by diffing against a reference frame does not work on a
  live desktop.** Moving across a NetPositive page repaints the status bar with
  the imagemap URL under the pointer, and a Terminal's caret blinks — both
  produce large changed regions nowhere near the cursor, and the loop chases
  them. The driver instead **jiggles the pointer two pixels and diffs those two
  frames**: hover state does not flip over two pixels, so whatever moved is the
  cursor. Changed regions larger than a cursor are rejected outright.

Note also that the Deskbar tray is only clickable if the clock mask is kept
tight around the clock text — an over-wide mask makes a region where the cursor
can never be found.

## What is left, and what the next errand inherits

Open, in the order they are worth doing:

1. **A host-side wake nudge**, if the operator wants the greeting inside ~30 s
   like the ICQ-2001b stations instead of up to ~2 minutes. The shape is
   `win98se-icq-nudge`; the beos-specific part is that it must detect the
   paused→running edge over **momentary** QMP connects and must not poll the
   guest itself (a `labctl exec` poll would hold the station permanently awake
   and defeat idle-pause). See §How a visitor gets greeted.
2. **Nothing about the client.** ICBM ships, is era-correct, GPL, needs no
   compiler, and its `.72` source is not recoverable — every Wayback copy of
   `ICBM.72-beta{1,4}{,-src}.zip` is a 403 hotlink stub, re-checked 2026-08-23
   (13 snapshots, all HTML). There is no reason to look for it: the `.71` binary
   does not carry the defect the source fix was for (§The Readme's
   `NetPacket.h` bug).

What any further errand on this station inherits:

- A real **exec channel** — `labctl exec beos "<cmd>"`, stdout and the guest's
  own exit code — and a real **file-delivery door**, ftpd on `:21` with the same
  `baron` login, STOR/RETR/MKD all proven. No framebuffer typing needed for
  either.
- L2 to the gateway CT, with `10.99.0.2:5190` and the legacy `4000/UDP` door
  **both proven end to end**, the second one only from here.
- A **reproducible fixture**: edit `UserBootscript`, reboot, re-bake. No window
  juggling, no hand-arranged golden.
- A **verified golden backup** with a documented rollback, and a `loadvm golden`
  that demonstrably reverts the **disk** as well as RAM — every file an errand
  puts in the guest is gone after one `systemctl restart` unless it re-bakes. Do
  the in-guest work and the bake in one uninterrupted session, or script it.
- The pointer caveats above — but note that the entire ICQ install was done with
  `addattr` over the exec channel and needed the pointer for **nothing**.
- A **restored, proven compiler recipe** (§Restoring the compiler) and a
  **committed pointer driver** (§Driving the pointer).
