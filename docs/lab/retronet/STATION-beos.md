# beos on the retronet — the bridge, the exec channel, NetPositive, and why it has no ICQ client

**Status: LIVE, and deliberately retronet-only — there is no ICQ client on this
station and, on the evidence below, there is no client that can ship today.**
`beos` (BeOS R5 Professional 5.0.3) joined the retronet on **2026-08-23**. It is on a real bridged NIC on `vmbr-rn` with a unique MAC, on
**DHCP** (reserved `10.99.0.16`), and it browses the museum corpus in
**NetPositive** — R5's own browser, no proxy, nothing sourced and nothing
installed. Open the station and NetPositive is already showing a corpus page.

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

> **The ICQ question is settled, not open.** Two clients were sourced, installed
> and measured against the real gateway on 2026-08-23, and both were rejected on
> evidence — see [§The ICQ client: two candidates, both
> rejected](#the-icq-client-two-candidates-both-rejected). Do not re-open the
> search without reading that section: it records what was tried, what the
> gateway proved it can do, and the one thing that would have to change for a
> client to ship. A Terminal-based IM client is **not** an acceptable
> substitute — the operator removed those from two other stations this week, and
> retronet-only is the better outcome than undoing that.

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
original fixture) and then NetPositive on a corpus page.

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

1. Back the golden up byte-for-byte with QEMU stopped, and `sha256sum -c` it.
2. Apply the DHCP reservation for the NEW mac on the gateway **first**
   (`install-dhcp.sh --apply`).
3. `qemu-img snapshot -d golden` on the disk so the launcher cannot fall through
   to `-loadvm`.
4. Boot cold with the new `mac=`, do the in-guest work, recapture.
5. Verify **in the bridge FDB** (`bridge fdb show dev beosrn0` → the new MAC)
   **and** in the gateway's DHCP log (`… 52:54:00:52:4e:10 -> ACK 10.99.0.16`).

Both verifications passed here.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** in
  `/data/vms/streamhost/stations/beos/beos-golden.qcow2`. **Tap-native + DHCP +
  MAC `52:54:00:52:4e:10`**, cold-baked on the production launcher with
  NetPositive showing a corpus page on a clean 1024×768 frame.
  `labctl reset beos` = `loadvm golden`.
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
  `SHA256SUMS` in the dir. This is the rollback for the ICQ errand. **In the
  event it is nothing but insurance: the ICQ errand shipped no golden change at
  all**, and the live golden is bit-for-bit the one phase 1 baked — everything
  the errand put in the guest was reverted by one `systemctl restart
  streamhost@beos`, which is what `loadvm golden` does to the disk.
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

From the ICQ errand —
`/data/gallery-guests/Beos/evidence-rn-beos-icq-20260823/` (PNG, 1024x768,
`SHA256SUMS` in the dir):

| file | what it shows |
|---|---|
| `01-icbm-signed-on-deskbar-green.png` | ICBM signed on as UIN `50000` over legacy UDP 4000 — the Deskbar replicant has gone green, and there is no contact-list window anywhere, which is the rejection in one frame |
| `02-toolchain-restored-gui-proof.png` | a titled BeOS window from a `BApplication` compiled **in the guest** with the recovered gcc 2.9-beos, linked against `libbe` |
| `03-fixture-intact-after-teardown.png` | the phase-1 fixture after teardown — Terminal + NetPositive on the corpus page, unchanged |

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
```

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

## The ICQ client: two candidates, both rejected

This is the record of the 2026-08-23 attempt to put beos on the ICQ gateway.
**Nothing shipped.** Both candidates were sourced, installed on the real station
and measured against the real gateway; each failed for a different, concrete
reason. The station was returned byte-for-byte to its phase-1 fixture
afterwards.

Read this before spending another agent on the search. The costly part of this
errand was not finding a client — it was discovering *which* half of the stack
each candidate breaks on, and both answers are now known.

### What the gateway proved it CAN do — the legacy UDP door works

The most valuable result here is a **positive** one about the gateway, and it
was not previously verified anywhere.

[`GATEWAY.md`](GATEWAY.md) documents a `4000/UDP` listener for pre-OSCAR ICQ
(v2–v5), kept enabled "because a Lane-B station (bridged, real L2) could use it,
and it costs nothing while unused". **beos is that station** — every other ICQ
station reaches the gateway through a slirp `guestfwd`, which is TCP-only, so
until beos went onto a real bridge no station could reach that door at all.

It works, and it bridges protocol generations:

| Step | Evidence |
|---|---|
| A legacy client authenticates | gateway log: `V4 login attempt uin=50000 password_len=8` → `user authenticated successfully version=4` → `created legacy session session_id=…` |
| The legacy session joins the SAME presence store as OSCAR | management API `/session` returned `['10000', '50000']` — HiveBot (OSCAR) and beos (legacy UDP) side by side |
| An OSCAR client SEES the legacy client | `retronet-bot` log: `presence: 50000 ONLINE` → `50000 (beos) signed on — greeting in 30s` → `GREETED 50000 (beos)` |
| The gateway TRANSLATES an OSCAR message down to the legacy wire | gateway: `OSCAR message pump: received SNAC uin=50000 food_group=4 sub_group=7`, and a `tcpdump` on `vmbr-rn` caught the resulting **`10.99.0.2.4000 > 10.99.0.16.49204: UDP, length 61`** at the exact greeting timestamp |

So a pre-OSCAR client on this station is a *supported* configuration
server-side. That is a real capability the retronet now has evidence for, and it
is what a future era-correct client would stand on. **The failure below is
entirely client-side.**

Two gateway details worth knowing before the next attempt:

- **ICQ UIN passwords are capped at 6–8 characters** by the server
  (`400 invalid password: invalid password length`). Generate 8, not 14.
- **`ICQ_LEGACY_SESSION_TIMEOUT` is 120 s and `ICQ_LEGACY_KEEPALIVE_INTERVAL` is
  also 120 s.** Those are equal, which leaves a client no slack: miss one
  keepalive and the session is reaped (`cleaning up expired session … last_activity=…`).
  A client that goes quiet for two minutes disappears. Raise the timeout before
  blaming a client for dropping.

### Candidate A — ICBM .71 (BeCQ), era-correct, killed by a client-side R5 bug

**What it is.** *Inter-Continental Ballistic Messenger*, the continuation of the
open-source **BeCQ** project — a real, native BeOS ICQ client with a contact
list, chat windows, history and a Deskbar replicant. **GPL-2.0**, dated
**2001-02-10**, distributed as a prebuilt `ICBM.x86` for "Intel/PPC R4.5 and R5".
Era-correct for a 2000 machine in a way IM Kit (a 2005–09 Haiku/Zeta codebase)
is not, and — decisively — it needs **no compiler**.

**Recovered** from `icbm.8k.com` via the Wayback Machine (`curl` from Bash;
`WebFetch` cannot reach `web.archive.org`). Archived in the media cache as
sha256 `c8902f40714ef439a8abf5d8c92982eb144bc10ee0a0fb30f4255e08b8dd2dd1`
(182 919 bytes, `ICBM.71.zip`). **The `.72` betas are NOT recoverable** — every
Wayback snapshot of `ICBM.72-beta{1..4}{,-src}.zip` is a 403 hotlink-protection
stub, not the archive. `.71` is the only surviving build, and no `.71` source
exists anywhere.

**How far it got — further than expected:**

- Installed by FTP into `/boot/home/apps/ICBM/`, byte-identical on read-back.
- **`mimeset -f` is mandatory after an FTP delivery.** A BeOS application's
  signature lives in its ELF resources, but the roster only sees it once the
  `BEOS:APP_SIG` / `BEOS:TYPE` *attributes* are derived from them, and FTP
  carries no BFS attributes. Before `mimeset`, ICBM ran but never registered;
  after it, `roster` showed `application/x-vnd.ICBM`.
- **It is configured entirely by BFS attributes, with no config file at all.**
  `/boot/home/config/settings/BeCQ-preferences` is a **zero-byte** file whose
  attributes are the settings, and there is a per-UIN mirror at
  `…/BeCQ-<UIN>/BeCQ-preferences` plus a `contacts/` directory. That makes it
  scriptable from the exec channel with `addattr` — no GUI driving needed:

  ```sh
  F=/boot/home/config/settings/BeCQ-preferences
  addattr -t int  uin 50000 $F          # NB: the type is "int", not "int32"
  addattr -t string password '<pass>' $F
  addattr -t bool autologin 1 $F        # NB: 1/0 — "true" silently stores 0
  ```

  The full attribute schema it writes on a clean quit: `allworkspaces`,
  `inworkspaces`, `alwaysontop`, `autohide`, `snaptoedge`, `entertosend`,
  `incomingopen`, `replyclose`, `autologin`, `authorizeadd`, `hideip`,
  `webaware`, `dateshow`, `serversend`, `fw_use`, `encoding_in`, `encoding_out`,
  `fw_servername`, `fw_serverport`, `fw_authreq`, `fw_authname`,
  `fw_authpassword`, `uin`, `password`, and (per-UIN) `icq_servername`,
  `icq_serverport`.
- **Auto-login worked, unprompted, and the DNS hijack carried it.** Its log:
  `App: Connecting... [icq.mirabilis.com:4000]` — the shipped default hostname,
  resolved by `retronet-dns` straight to `10.99.0.2`. No server-override setting
  was needed, exactly as predicted.
- **It signed on.** UIN `50000` appeared in the gateway session store and the
  Deskbar replicant turned green.

**Why it was rejected — three independent, load-bearing failures:**

1. **No contact-list window, ever.** The app installs a Deskbar replicant and
   nothing else. Single-click, double-click and right-click on the replicant all
   produce no window (verified by frame diff — only the Deskbar clock changes),
   with `autohide=0`, `alwaysontop=1` and `allworkspaces=1` set. A desktop
   buddy list is the whole requirement, and it never appears.
2. **It never receives messages.** The gateway demonstrably put the greeting on
   the wire (the 61-byte UDP packet above). ICBM's own log did **not grow by a
   single line** across delivery — 174 lines before, 174 after — and no
   "unknown contact" file appeared in `BeCQ-50000/`. Its send loop meanwhile
   sits retransmitting its own ACK (`SendPacketLoop [Seq: 0x3] [Attempt #1]`).
3. **The process dies on its own, within minutes.** Repeatedly, from a clean
   start, with and without `stdin` redirected to `/dev/null` — once in 40 s. An
   exhibit client that exits unattended is unusable regardless of the other two.

**The cause is almost certainly the one its own Readme warns about**, and it is
not fixable without a rebuild:

> *"There is a significant bug that causes problems compiling and running ICBM
> under R5. It is caused by a declaration in the system include file
> NetPacket.h … `void *operator new(size_t size); void operator delete(void
> *ptr);`"*

That is a heap `new`/`delete` mismatch in `BStandardPacket` — precisely the
shape of defect that produces silent thread death, a looper that stops servicing
its queue, and random exits. The Readme's remedy is to comment those lines out
**and recompile**. We cannot: `.71` source is not archived, and the only
surviving artefact is the affected binary.

**Not a launch artefact.** The obvious objection — "your telnet-launched app
just loses its window" — is disproved on the same station in the same session: a
`BApplication` compiled in-guest and launched exactly the same way *did* open a
normal titled window and register in the Deskbar (§Restoring the compiler). The
environment is fine; ICBM is not.

### Candidate B — IM Kit, buildable at the protocol layer, blocked at the UI

**What it is.** `github.com/HaikuArchives/IMKit` at `9c80ad1`, archived as
sha256 `4eb6f38c3417dc6cb99610bd02fd86b32013f938b574d31462e1bb2221bd34e0`
(3 300 733 bytes). A framework — `libim` + an `im_server` daemon + per-protocol
add-ons (`protocols/OSCAR/ICQ.cpp`) + separate client apps.

**The good news, measured rather than assumed.** With the compiler restored
(below), **the entire OSCAR protocol engine compiles on BeOS R5 under gcc
2.9-beos-991026**: `protocols/OSCAR/OSCARManager.cpp`, 1 842 lines, produced a
**412 356-byte object file with zero errors**. It needs exactly two shim headers,
both trivial:

```c
/* be_prim.h — OSCARConstants.h includes this on every non-Haiku target because
 * ZETA shipped it. R5's equivalent is SupportDefs.h. */
#include <SupportDefs.h>
```

```c
/* openssl/md5.h — R5 ships no OpenSSL. OSCARManager touches MD5 in exactly one
 * place: hashing an OPTIONAL buddy-icon upload. Login uses ICQ's plain XOR
 * password roasting and no crypto library at all, so a declaration-only stub is
 * enough to build, and the code path is never reached by this exhibit.
 * The struct tag matters: the source names MD5state_st. */
#define MD5_DIGEST_LENGTH 16
typedef struct MD5state_st { unsigned char unused[92]; } MD5_CTX;
int MD5_Init(MD5_CTX *); int MD5_Update(MD5_CTX *, const void *, unsigned long);
int MD5_Final(unsigned char *, MD5_CTX *);
```

That settles the recon's biggest open question — the "OSCAR is gated on OpenSSL"
blocker really is avoidable, and gcc 2.95 really does swallow this C++.

**The bad news, also measured.** The client that draws the buddy list —
`clients/im_contact_list` — is written against **Haiku's Layout Kit**, which
does not exist in BeOS R5 in any form. Compiling `ContactListView.cpp` on the
station fails at the constructor, not at some detail:

```
ContactListView.cpp:21: no matching function for call to `BView::BView (const char *&, const uint32 &)'
  candidates are: BView::BView(BRect, const char *, long unsigned int, long unsigned int)
ContactListView.cpp:32: implicit declaration of function `int BGroupLayoutBuilder(...)'
```

R5's `BView` has no layout-aware constructor, no `SetLayout()`, no `MinSize()`/
`PreferredSize()` virtuals, and R5 has no `BSize`, `BGroupLayout`,
`BGroupLayoutBuilder`, `BLayoutUtils` or `BControlLook` at all. This is the
brief's explicit stop condition — a **missing Be API**, not a compiler quirk.

Three further gaps found while measuring, so the next agent does not rediscover
them:

- **There is no `jam` on BeOS R5.** The Development package ships the GNU
  toolchain and `make`, but not Jam, and IM Kit's entire build system is Jam.
  Every component would need a hand-written makefile.
- **`common/columnlistview` ships only `haiku/` and `zeta/` variants**, no R5
  one, and the `haiku` one also uses `ControlLook` + `LayoutUtils`.
- **The SSI alias fix is bigger here than it was on tru64.** The defect is real
  and exactly where recon said — `OSCARManager::HandleSSI()`'s `BUDDY_RECORD`
  case does a bare `reader->OffsetBy(len)` and never reads alias TLV `0x0131`,
  three lines below a `GROUP_RECORD` case that already has the inner-TLV loop to
  copy. But Gaim's `add_buddy()` already took an alias argument, whereas IM Kit's
  `OSCARHandler::SSIBuddies(std::list<BString>)` carries **ids only**. The alias
  would have to be threaded through `OSCARHandler` → `ICQProtocol` → the libim
  message → `im_server` → the UI. It is not a 15-line change on this codebase.
  (IM Kit renders contacts from BeOS **People files**, so an alternative is to
  seed People files instead of patching SSI at all — at the cost of a
  hand-seeded roster baked into the golden.)

**Verdict.** IM Kit is not a patch job on R5; it is a Haiku→R5 port of a
multi-component framework — a rewritten build system, a rewritten contact-list
UI, and only then the three functional patches. That is a different errand from
the one that was scoped, and it should be scoped honestly before it is started.
`im_chat` (the chat window) is, for what it is worth, **layout-free classic
BeOS** and looks portable; the contact list is the hard part.

### What would have to change for a client to ship

In rough order of cost:

1. **Recover ICBM `.72-beta4-src`** from somewhere other than Wayback (every
   Wayback copy is a 403 stub). With source, the Readme's own `NetPacket.h`
   fix is a two-line change, the compiler is now restored and proven, and
   everything else about ICBM — era-correct, GPL, auto-login, native contact
   list, and a gateway door already proven to serve it — is right.
2. **Port IM Kit's `im_contact_list` to R5's manual-layout InterfaceKit** and
   hand-write makefiles for `libim`, `im_server`, `protocols/OSCAR` and
   `im_chat`. The protocol half is proven to build; this is the UI half.
3. Anything that puts a **Terminal** IM client on the framebuffer is explicitly
   out of bounds.

### The persona account is provisioned and proven — leave it

UIN **`50000`** exists on the gateway, is **open for unattended contacts**
(`rn-tool.py user-open`), has ICQ directory nickname `beos`, and has been proven
to authenticate over **both** doors — OSCAR (`rn-tool.py login 10.99.0.2 5190`)
and legacy UDP 4000. Its password is `RETRONET_ICQ_BEOS_PASS` in gitignored
`registry/local.env` and in the CT's `/etc/ras/accounts.env`.

It is deliberately **not** cross-listed: `scripts/retronet/icq/roster.json`
carries beos with `"onboarded": false`, so the SSI seeder leaves it out of every
other station's contact list, and `RN_BOT_PERSONAS` does not include it. That is
the correct state while no client runs — an onboarded station that is never
online would show as a permanently-offline contact on five other exhibits.
**Onboarding beos is two edits and one seeder run** once a client exists.

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

## What a future ICQ errand inherits

- A real **exec channel** — `labctl exec beos "<cmd>"`, stdout and the guest's
  own exit code — and a real **file-delivery door**, ftpd on `:21` with the same
  `baron` login, STOR/RETR/MKD all proven. No framebuffer typing needed for
  either.
- L2 to the gateway CT, with **`10.99.0.2:5190` already proven OPEN** from the
  guest.
- A **reproducible fixture**: edit `UserBootscript`, reboot, re-bake. No window
  juggling, no hand-arranged golden.
- A **verified byte-for-byte golden backup** with a documented rollback, and a
  `loadvm golden` that demonstrably reverts the **disk** as well as RAM — every
  file this errand put in the guest was gone after one `systemctl restart`. Do
  the in-guest work and the bake in one uninterrupted session, or script it.
- The pointer caveats above — budget for closed-loop targeting if any client
  needs GUI configuration, and prefer the exec channel wherever it will do.
- A **restored, proven compiler recipe** (§Restoring the compiler) and a
  **committed pointer driver** (§Driving the pointer).
- A gateway **legacy UDP-4000 door proven end to end**, and a persona
  (UIN `50000`) already provisioned, opened and proven on both doors.
- Two candidates already eliminated on evidence, with the exact next steps that
  would revive either one.
