# beos on the retronet — the bridge, the exec channel and NetPositive

**Status: LIVE.** `beos` (BeOS R5 Professional 5.0.3) joined the retronet on
**2026-08-23**. It is on a real bridged NIC on `vmbr-rn` with a unique MAC, on
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

> Phase 2 (an ICQ client on this station) is a separate errand and has not been
> done. Nothing here installs or presumes one; the sections below are what phase
> 2 builds on.

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

## What phase 2 inherits

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

### The one thing phase 2 must fix before it can build anything

**There is no compiler on this station.** `/boot/develop` exists and is
**empty** (2 KB, no entries); `gcc` is `command not found`; there are no BeOS
headers (`/boot/develop/headers/be` does not exist) and no development
libraries. `make` is present at `/bin/make`, and that is all.

This is a consequence of how the station was installed: it was built by copying
the Pro CD's track-2 BFS **system** volume onto a fresh BFS partition (see
[`docs/guests/beos.md`](../../guests/beos.md) §Install method), and the
development tree did not come across.

**The tools are recoverable from the media the station was built from**, which
is still staged on the box at
`/data/assets-staging/beos/beos-5.0.3-professional-gobe.bin` (772,302,720 bytes,
sha256 `1889fd6c…0106`, `MANIFEST.sha256` beside it). Grepping that image finds
`develop/headers`, `SupportDefs.h`, `InterfaceKit.h`, `libbe.so` and the string
`2.95.3` — so gcc 2.95.3 and the Be headers are on the disc. Recovering them
means re-splitting the disc's three MODE1/2352 tracks into 2048-byte images (the
recipe and the splitting script are in `scripts/build-guests/tiles/beos.sh`),
mounting/reading the track-2 BFS volume, and delivering `develop/` into the
guest — **over the ftpd door above**, which is exactly what it is for.

Budget for that before budgeting for the IM Kit build itself, and note that a
gcc build on a TCG guest is a long unattended run: turn idle-pause off for it
(§Delivering files into the guest) or the vCPU will freeze mid-compile.
