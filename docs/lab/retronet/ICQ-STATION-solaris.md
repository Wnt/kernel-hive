# solaris ICQ station (Pidgin / OSCAR) — the bridge as-built

**Status: LIVE.** `solaris` (Solaris 10 x86, CDE) is the **first non-Windows**
station on the retronet OSCAR gateway, and since **2026-08-22** the first one
whose ICQ surface is a **real desktop application** rather than a terminal: it
runs **Pidgin 2.10.4** (GTK2, `libpurple` 2.10.4), auto-signed-in as UIN `30000`
over a real bridged NIC on `vmbr-rn` — **on DHCP** (reserved `10.99.0.14`), and
browsing the museum corpus with **no proxy** (§Seamless web). Open the station
and Pidgin's **Buddy List** is already there as a proper CDE toplevel, docked at
the right of the 1920×1200 desktop, listing the whole fleet **by name**
(HiveBot, nt4, tru64, win2000, win98se) — downloaded from the gateway's
**server-side SSI roster** with no manual adds (§Contacts) — and the greeter bot
(UIN `10000`, **HiveBot**) messages it, opening a real chat window. Parents:
[`ICQ-ONBOARDING-PLAN.md`](ICQ-ONBOARDING-PLAN.md) (Tier C),
[`ICQ-STATION.md`](ICQ-STATION.md) (the win98se pathfinder — the host-side
tap/containment wiring is shared), [`GATEWAY.md`](GATEWAY.md), [`BOT.md`](BOT.md).

> Until 2026-08-22 this station ran **climm 0.6.4** in a `dtterm`. climm, its
> SSI-login patch and `/.climm/` are **still installed on the golden's disk** and
> remain the documented rollback (§Golden lineage & rollback). Nothing about the
> network, containment or exec planes changed in the swap — only the client.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device e1000,netdev=net0` (**unchanged** — what `savevm`/`loadvm` bind to), backend `tap`: `-netdev tap,id=net0,ifname=solrn0,script=no,downscript=no` |
| MAC | **unique** per-station MAC (the fleet otherwise shares QEMU's default `52:54:00:12:34:56` → one FDB entry, unicast flaps between taps, DHCP-reservation collisions). Real value box-local in `registry/local.env` `RETRONET_ICQ_SOLARIS_MAC` (launcher reads it, scrubbed-placeholder fallback committed). It lives in the golden's device vmstate, so it needed a **cold re-bake** — `loadvm` restores the saved MAC regardless of the launcher `mac=`; verified after `loadvm`, and the bridge FDB maps it to `solrn0`. See `WEB-PROXY.md`. |
| Tap | `solrn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/solaris/rn-tapnet.sh up` from the launcher on every start |
| Guest IP | **DHCP** — `e1000g1` obtains its IP *and* DNS automatically (empty `/etc/hostname.e1000g1` + present `/etc/dhcp.e1000g1` → `ifconfig e1000g1 dhcp`). `retronet-dhcp` hands out the reserved **`10.99.0.14/24`**, DNS **`10.99.0.2`**, and **NO default gateway** (containment stays Lock 1: no default route). Reservation keys on the guest MAC (`RETRONET_ICQ_SOLARIS_MAC`); no `/etc/defaultrouter`. §Seamless web below |
| Seamless web | DNS = `10.99.0.2` (via DHCP) + `nsswitch hosts: files dns` + no proxy → any URL resolves to the gateway and its `:80` origin serves the museum corpus. **Proven from the guest:** `spacejam.com`/`search.retronet` → `10.99.0.2`, `http://spacejam.com/` renders. Plane: [`WEB-PROXY.md`](WEB-PROXY.md) |
| OSCAR server | gateway CT `10.99.0.2:5190` (the labhost door; advertises BOS `10.99.0.2:5190`, routable from the guest over the bridge) |
| Persona / bot | UIN `30000` (solaris) / UIN `10000` (HiveBot); passwords in `registry/local.env` `RETRONET_ICQ_*` |
| ICQ client | **Pidgin 2.10.4 / libpurple 2.10.4** (`/usr/bin/pidgin`, Oracle package `SUNWgnome-im-client`), config dir `/.purple/` — `accounts.xml` (the account + auto-login), `prefs.xml` (Buddy List geometry, show-offline, auto-away OFF), `blist.xml` (the **cache** of the server-side SSI roster; not a source of truth). §Pidgin below |
| Exec | `labctl exec solaris "<cmd>"` → in-guest warpd agent (`/opt/warpd/warpd.py`) at **`10.99.0.14:7777` directly over the bridge** (`exec_kind warpd_e`, `exec_host` → `GEXEC_HOST`, host client `/root/gexec.py`); no hostfwd. Pointer stays on `gallery-hid-pci`; warpd is rollback/exec only |

## Pidgin — nothing to build, nothing to download

Unlike climm (which needed a real `gcc 3.4.3` build and a source patch), Pidgin
required **no media and no compilation**: Oracle's Solaris 10 JDS GNOME2 desktop
already ships it in the base install.

| | |
|---|---|
| Package | `SUNWgnome-im-client`, `pkgchk -l -p /usr/bin/pidgin` → `completely installed` |
| Binary | `/usr/bin/pidgin` (GTK2, Nov 2012 build stamp) |
| Stack | `/usr/lib/libpurple.so.0.10.4`, OSCAR prpl `/usr/lib/purple-2/liboscar.so` |
| Linkage | `ldd` on `pidgin` / `libpurple` / `liboscar` → **zero** unresolved libraries; the JDS desktop already carries the whole GTK+2 stack |
| SSI | real — `liboscar` carries `feedbag`, `ssi: activating server-stored buddy list`, `ssi: syncing local list and server list` |
| Reconnect | libpurple's `autorecon` is a **core, non-optional** plugin (`/usr/lib/purple-2/../plugins/core/autorecon/…`), exponential backoff, nothing to enable |

Sourcing/feasibility evidence: [`ASSETS-MANIFEST.md`](../ASSETS-MANIFEST.md)
§"solaris GUI OSCAR client — Pidgin is ALREADY on the golden disk".

### The account file, and the three schema facts that actually matter

`/.purple/accounts.xml` is **hand-authored** (driving Pidgin's account wizard
through the framebuffer is not worth it). libpurple's parser is unforgiving: get
the schema wrong and the account is **silently not loaded** — no error, no
wizard, just an empty Buddy List. Three details are not what you would guess:

1. **The protocol id is `prpl-icq`, not `prpl-oscar`.** The OSCAR prpl registers
   *two* protocols, `prpl-aim` and `prpl-icq`; `prpl-oscar` is the plugin's
   filename, not a protocol id, and an account naming it never loads.
2. **Auto-login is a UI pref, not an account setting.** It lives in a *second*
   settings block, `<settings ui='gtk-gaim'>` → `<setting name='auto-login'
   type='bool'>1</setting>`. (Pidgin kept `gtk-gaim` as its UI id for backward
   compatibility with Gaim — the name is not a mistake.) An `auto_login` key in
   the main `<settings>` block is ignored, and the account just sits offline.
3. **`server`/`port` are ordinary per-account settings** in the main
   `<settings>` block (`10.99.0.2` / `5190`), overriding the compiled-in
   `login.icq.com:5190` the same way climm's `climmrc` `host`/`port` lines did.
4. **`authorization` ("Require authorization") defaults to ON and must be turned
   OFF** — `<setting name='authorization' type='bool'>0</setting>`. Leave it on
   and everything looks perfect while the greeter goes permanently blind to this
   station. This one cost the most time; the full diagnosis is
   §"The one thing that silently breaks the greeting".

The `<password>` is stored **plaintext**, which is what gives silent sign-in with
no keyring and no prompt (the value comes from `registry/local.env`
`RETRONET_ICQ_SOLARIS_PASS`; the same trust model as climm's `climmrc`). Also set
`allow_multiple_logins` so a stale gateway session cannot lock the persona out,
and `use_clientlogin=0` / `encryption=no_encryption` so it speaks the plain
BUCP/OSCAR the gateway serves.

The file that ships is exactly the one libpurple itself re-serialises after a
successful sign-on — the safest possible proof that the schema parsed.

### Two prefs that decide whether the exhibit looks right

`/.purple/prefs.xml` carries the whole GTK UI state. Two settings are
**exhibit-critical**, and both defaults are wrong for a museum station:

- **`/pidgin/blist/show_offline_buddies` defaults to `0`.** With it off, Pidgin
  shows only contacts that are *currently online* — so the station displays a
  one-line Buddy List with just `HiveBot` and the four fleet peers are invisible,
  even though the SSI roster downloaded correctly. Set it to `1`: the roster is
  the exhibit.
- **`/purple/away/away_when_idle` defaults to `1`, `mins_before_away` to `5`.**
  A station nobody has touched for five minutes flips itself to **Away** and
  grows an "I'm not here right now" message box under the status selector — the
  station advertises itself as absent, and the golden would bake that in. Set
  `away_when_idle` to `0` **and** `idle_reporting` to `none`. (This was caught on
  the pre-bake frame, not in theory: see §The framebuffer is the proof.)

## The fixture: Pidgin as a CDE desktop app

`Xsession.d/9999.golden-fixture` disables the screensaver/DPMS and the animated
front-panel bits exactly as before, then simply backgrounds **`/usr/bin/pidgin`**
where it used to launch `dtterm … -e /usr/local/bin/climm`. That one line is the
whole client swap.

Deliberately **no `-geometry` on the command line.** Pidgin owns its own window
geometry and rewrites it into `prefs.xml` when it exits, so a launcher flag would
be silently overwritten on the next run; placement belongs in `prefs.xml`, which
is baked into the golden's disk. This is the split to keep: the **fixture decides
what runs**, `prefs.xml` decides **how it looks**.

### Window composition — the first GTK toplevels on this fleet

climm was one fixed-geometry terminal. Pidgin is **multi-window** (a Buddy List
plus one chat window per conversation), and this is the fleet's first fixture
managing real GTK toplevels under `dtwm`, so placement is a design decision, not
a default:

- **Buddy List: right-docked**, `/pidgin/blist` `x=1470 y=90`, `380×560` on the
  1920×1200 desktop. That is the authentic ICQ position, it clears the CDE front
  panel (bottom-centre), it is wide enough that the group header
  `contacts-icq8-30000` is not truncated, and it leaves the whole left/centre of
  the desktop free.
- **Chat windows are left to `dtwm`**, which opens them toward the upper-left —
  i.e. into the space the docked Buddy List deliberately leaves empty, so an
  arriving HiveBot message composes with the roster instead of covering it.
- **The golden is baked with the Buddy List only** — no conversation window. A
  chat window baked into the snapshot would show every visitor the *same stale*
  greeting, and then a second, live one on reconnect. Baking it clean means the
  greeting arrives **while the visitor watches**, which is the better exhibit.

## Contacts — server-side SSI roster (no manual adds)

Pidgin/libpurple is fully SSI-aware: on every sign-on it downloads the gateway's
server-side SSI/feedbag roster and renders it. solaris therefore carries all five
fleet contacts **without a single local add** — they live only in the OSCAR
server's feedbag, written once by the contact seeder
([`CONTACT-SEEDER.md`](CONTACT-SEEDER.md) `rn-tool.py ssi-seed`), and the display
name (`win98se`, `nt4`, …) rides in each roster item's `0x0131` alias TLV.

**Proven on the live station**, from a `/.purple` containing *only* the
hand-authored `accounts.xml` (no `blist.xml` at all), Pidgin wrote this cache
itself on first sign-on:

```
group contacts-icq8-30000
  20000 -> win2000     40000 -> nt4        64000 -> tru64
  98980 -> win98se     10000 -> HiveBot
```

and the server agrees — `rn-tool.py buddies 30000`:

```
10000 HiveBot    20000 win2000    40000 nt4    64000 tru64    98980 win98se
```

`/.purple/blist.xml` is a **cache, not a source of truth**: delete it and the
next sign-on rebuilds it from the server. The group is climm's original
`contacts-icq8-30000` — the seeder reused it, so there is one group, not two.
Add a station, re-seed, and it simply appears here.

## Seamless web — DHCP + no proxy

The station browses the museum corpus with **nothing configured but DHCP**.
`e1000g1` obtains its IP *and* DNS automatically, `nsswitch hosts:` is `files
dns`, and there is no proxy. On the lease it gets `10.99.0.14`, DNS `10.99.0.2`,
and **no default gateway**; then every name resolves to the gateway
(`retronet-dns`), lands on its `:80` origin (`proxy.py`), and is served from the
corpus by `Host`. **Re-proven from the guest after the Pidgin swap**
(`/usr/bin/python`): `spacejam.com` and `search.retronet` both resolve to
`10.99.0.2`, and `urllib2.urlopen("http://spacejam.com/")` returns the corpus
HTML. Addressing plane: [`WEB-PROXY.md`](WEB-PROXY.md).

**Static → DHCP conversion (what was done here).** Pidgin talks to the literal
`10.99.0.2:5190` from its per-account `server`/`port` settings, and the
reservation keeps the guest on `10.99.0.14`, so exec-over-bridge stays at
`10.99.0.14:7777`. The exec channel runs a real root shell (redirection works;
Python 2.6.4 is present), so it is scripted in-guest — run the interface switch
**detached** (the unplumb drops the exec socket mid-command; warpd's
`0.0.0.0:7777` listener survives and the same `10.99.0.14` returns) with a
static-IP safety net:

```sh
cp /dev/null /etc/hostname.e1000g1     # empty -> no static addr at boot
touch /etc/dhcp.e1000g1                 # signal: configure e1000g1 via DHCP
# nsswitch hosts: files -> files dns   (python re.sub; Solaris has no sed -i)
ifconfig e1000g1 unplumb; ifconfig e1000g1 plumb
ifconfig e1000g1 dhcp start wait 60     # -> BOUND 10.99.0.14 (reservation)
# Solaris dhcpagent does NOT auto-write resolv.conf; apply the DHCP-supplied DNS:
echo "nameserver `/sbin/dhcpinfo -i e1000g1 DNSserv`" > /etc/resolv.conf
```

Then **recapture the golden** so the DHCP state persists a `loadvm`. On the
gateway (once): add the station's `mac=ip` to `registry/local.env`
`RETRONET_DHCP_RESERVATIONS` and re-run `install-dhcp.sh --apply`.

## Containment — proven from inside the guest (`10.99.0.14`)

Re-proven in full **after** the Pidgin swap (2026-08-22); the client change
touches none of it, and the table is unchanged:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2:5190` (OSCAR) | **OPEN** + `ping` reply (0% loss) | intra-bridge L2 (the point) |
| CT `10.99.0.2:80` (corpus web) | **OPEN** | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` (ICMP) | **100% loss** | the per-station guard chain `SOLRN-IN` |
| gallery `10.99.0.1:8443` | **BLOCKED (timeout)** | `SOLRN-IN` |
| labhost `10.99.0.1:22` | **BLOCKED (timeout)** | `SOLRN-IN` |
| internet `1.1.1.1:443` / `8.8.8.8:53` | **BLOCKED (network unreachable)** | no default route (Lock 1) |

Same three-layer model as win98se (topology → no-default-route → the
fail-closed `SOLRN-IN` INPUT chain scoped to the guest IP). Lock 1 survives the
DHCP conversion because `retronet-dhcp` **withholds option 3 (router)** — the
lease carries an IP + mask + DNS but no default gateway, so the guest's own stack
still refuses every off-subnet packet ("network unreachable"). The exec channel
is **labhost-initiated** (daemon/labctl dials the guest), so its replies pass as
ESTABLISHED while every NEW flow the guest starts toward labhost is dropped;
`rn-tapnet.sh` aborts (QEMU never starts) if the chain does not verify. The live
chain, for the record:

```
-A SOLRN-IN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A SOLRN-IN -j DROP
-A INPUT -s 10.99.0.14/32 -i vmbr-rn -j SOLRN-IN
```

## The reconnect mechanism — how "open the station" greets you

The station is stored **frozen at golden** (`query-status` → `prelaunch`), and a
visitor opening it is what resumes the guest. The golden holds Pidgin connected
on an **ephemeral** BOS source port; by the time anyone opens the station that
gateway session is long gone (it died with the QEMU process that made it). So on
wake the restored socket is stale, libpurple's **`autorecon`** core plugin — the
always-compiled-in exponential-backoff reconnector, nothing to enable and no
host-side nudge — notices, and signs on again from scratch. That fresh sign-on
re-downloads the SSI roster, so the names are always current.

**Measured on the production path** (`systemctl stop` → gateway reaps the session
→ `systemctl start` → the guest comes up `prelaunch` → resume, exactly what a
visitor's open does), 2026-08-22, against the shipped golden:

| event | when |
|---|---|
| visitor resumes the guest | T0 |
| Pidgin re-signs-on **unaided**, roster re-fetched | **T0 + 46 s** |
| HiveBot's greeting arrives, chat window opens | **T0 + 81 s** (= sign-on + ~30 s, `RN_BOT_GREET_DELAY`) |

For comparison the climm build this replaced reconnected in ~18–23 s and was
greeted ~30 s later (~50 s end-to-end); Pidgin's end-to-end is ~81 s. The extra
time is autorecon's backoff plus the delay before libpurple gives up on the
restored socket — no nudge is used, wanted, or needed.

**What a visitor actually sees during that window, and it is not a bug.** For
roughly the first minute after the wake the Buddy List is *empty* and carries a
red banner — `30000 disconnected — Lost connection with server: Connection reset
by peer`, with `Modify Account` / `Reconnect` buttons. That is Pidgin honestly
reporting the stale socket it woke up holding; autorecon then signs on by
itself and the five names come back with no interaction. Verified end-to-end
through `labctl reset solaris`: banner at +25 s, full roster restored and
`Available` by +100 s, nothing clicked. Do not press `Reconnect` to "fix" it,
and do not bake a golden from a frame showing it.

Two variants worth knowing, because they look like failures and are not:

- **Kill the gateway-side socket outright** (`ss -K dst 10.99.0.14`) and Pidgin
  is back in **≤ 40 s** — the fast path, because the RST is immediate.
- **Resume while the gateway still holds the golden's exact session** and Pidgin
  does **not** reconnect at all, because nothing is wrong: both ends agree and
  the restored TCP connection simply carries on (observed: the queued bytes
  drain and the session resumes). This only happens right after a re-bake, and
  it is the same caveat climm had. Give the gateway ~2 minutes to reap the
  session (measured: `reaped at +120 s`) and the wake behaves like production.
  This is also why a `loadvm` alone will not refresh a changed roster.

### The one thing that silently breaks the greeting

libpurple's ICQ protocol has an account option **`authorization` ("Require
authorization"), and it defaults to ON**. With it on, Pidgin publishes
"30000 requires authorization" into SSI on sign-on; the greeter's
`BuddyAddBuddies` for `30000` then never yields presence, so **HiveBot never
sees solaris come online and never greets** — and, exactly as
[`BOT.md`](BOT.md) §"The thing that silently breaks the greeting" warns,
*nothing anywhere logs an error*. The station looks perfect: signed in, full
roster on screen, `rn-tool.py buddies 30000` correct, `is_invisible: false` —
and the bot is simply blind to it, while it keeps tracking every other station
normally.

The fix is one line in `accounts.xml`, and it is **not optional** on this fleet:

```xml
<setting name='authorization' type='bool'>0</setting>
```

Diagnosis, if presence ever goes one-way again: the tell is a bot log that shows
`presence:` transitions for every persona **except** this one, with no rejection
message. Confirm with `rn-tool.py buddies 30000` (roster fine) and the gateway's
`/session` endpoint (`30000` present, `is_invisible: false`) — a station that is
demonstrably online but invisible to the greeter is this bug, not the network.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (~1.01 GiB, 2026-08-22 14:23:38)
  in `/data/vms/streamhost/stations/solaris/solariscde-golden.qcow2`.
  **Tap-native + DHCP + Pidgin** — captured with `e1000g1` DHCP-BOUND on the
  reserved `10.99.0.14` (DNS `10.99.0.2`, no default route), Pidgin signed on and
  showing the five-name SSI roster, status **Available**, Buddy List right-docked,
  **no chat window**, on a clean 1920×1200 frame. `labctl reset solaris` =
  `loadvm golden`.
- **Pre-Pidgin backup** (the climm `golden`, disk state flattened from the live
  image with `qemu-img convert -U -l snapshot.name=golden`, SHA256-verified):
  `/data/gallery-guests/SolarisCDE/golden-backup-pre-pidgin-20260822/`
  — `solariscde-golden-goldensnap.qcow2`, sha256
  `6085d12834cfc605ccab0eb45d6b053235d23bc40e75c445479c188ee327b330`,
  `SHA256SUMS` in the dir (`sha256sum -c` verified at capture time).
  **This is the rollback for the climm→Pidgin swap.**
- **Pre-DHCP backup** (the static-IP climm `golden`):
  `/data/gallery-guests/SolarisCDE/golden-backup-predhcp-20260821/`
  (`solariscde-golden-goldensnap.qcow2` sha256 `6619dd06…bdf6`, `SHA256SUMS`).
- **Pre-swap backup** (QEMU stopped, SHA256-verified) with the old **slirp**
  golden: `/data/gallery-guests/SolarisCDE/golden-backup-rn-netswap-20260820/`
  (`solariscde-golden.qcow2` sha256 `e1fd8d2e…9132c`, `SHA256SUMS` in the dir).
  The pristine gallery image `/data/gallery-guests/SolarisCDE/solaris.qcow2` is
  a separate, older backstop.

**Rolling back to climm.** The climm binary (`/usr/local/bin/climm`), its SSI
patch and `/.climm/` are all still on the Pidgin golden's disk, so the *cheap*
rollback does not need the backup image at all — put the `dtterm` line back in
`streamhost/stations/solaris/9999.golden-fixture` and in the guest's
`/usr/dt/config/Xsession.d/9999.golden-fixture`, kill Pidgin, launch climm, and
recapture. The full disk rollback is:

```bash
systemctl stop streamhost@solaris
cd /data/gallery-guests/SolarisCDE/golden-backup-pre-pidgin-20260822
sha256sum -c SHA256SUMS                       # 6085d128…b330 — verify BEFORE trusting it
cp solariscde-golden-goldensnap.qcow2 \
   /data/vms/streamhost/stations/solaris/solariscde-golden.qcow2
systemctl start streamhost@solaris
# a flattened backup has NO internal snapshot: it cold-boots into that state.
# Re-bake instant restore from a clean frame, via drive.py on the station's qmp.sock:
#   savevm golden-new; querysnap; delvm golden; savevm golden; delvm golden-new
```

## Gotchas that cost real time

**Pidgin / libpurple**

- **`prpl-icq`, not `prpl-oscar`.** Wrong protocol id = the account is silently
  never loaded. No error anywhere; the Buddy List is just empty.
- **`auto-login` lives in `<settings ui='gtk-gaim'>`**, hyphen not underscore,
  and *not* in the account's main `<settings>` block. Put it in the wrong place
  and Pidgin starts up with the account configured but signed **off**.
- **`show_offline_buddies` defaults to OFF.** The SSI roster downloads correctly
  and the station still shows a one-contact Buddy List, because four of the five
  peers happen to be offline. This looks exactly like "the roster failed" and is
  not. Check `/.purple/blist.xml` before believing the screen.
- **Pidgin auto-aways after 5 idle minutes** and paints an "I'm not here right
  now" box into the Buddy List. On an exhibit that is always idle this is
  guaranteed, and baking it into the golden ships a station that advertises
  itself as absent. `away_when_idle=0` **and** `idle_reporting=none`.
- **Pidgin owns its own geometry.** It rewrites `/pidgin/blist` `x/y/width/height`
  into `prefs.xml` on exit, so a `-geometry` flag on the fixture's command line
  is pointless. Set placement in `prefs.xml`; the fixture just runs the binary.
- **Pidgin rewrites `accounts.xml` on exit**, including the status it was in. If
  it exits while Away, the next start comes up Away. When re-baking, re-write the
  account file from the known-good template rather than trusting what is there.
- **Never run Pidgin through the warpd `E` exec channel directly.** It is a
  long-lived GUI process and wedges the fire-and-forget channel — the same rule
  climm had, and worse. Launch it `nohup … &` with `DISPLAY=:0
  XAUTHORITY=/.Xauthority`, or let the fixture do it.
- **`/.purple/blist.xml` is a cache.** Deleting it proves the roster really is
  server-side: the next sign-on rebuilds it from SSI. Never hand-edit it to
  "add" a contact — that is exactly the local-adds failure this station avoids.

**The station and the box**

- **root's `$HOME` is `/`**, so the config dir is `/.purple/`, not
  `/root/.purple/` (the same trap climm's `/.climm/` hit).
- **A restart of `streamhost@solaris` reverts the guest's disk.** The launcher
  runs `-loadvm golden`, and a QEMU internal snapshot restores the *disk* as well
  as RAM, so every in-guest edit made since the last bake is gone. Do the whole
  in-guest sequence and the bake in one uninterrupted session, or script it.
- **A paused guest answers nothing, and its OSCAR socket rots into a "Broken
  pipe" the moment it wakes.** Driving the guest does not need an override —
  `labctl` and `scripts/dev/qmp-type.py` wake it, verify it is running and hold
  a wake lease while they drive ([`../INPUT-DEBUGGING.md`](../INPUT-DEBUGGING.md)).
  For a long unattended step with nothing driving, `SH_IDLE_PAUSE_SECS=0`
  disables idle auto-pause outright. It is a systemd `EnvironmentFile`, which
  does **not** strip trailing comments — `SH_IDLE_PAUSE_SECS=0   # temp` parses
  as the literal string `0   # temp`, fails to parse as a number, and silently falls back to the
  default. Put the comment on its own line. Confirm with
  `journalctl -u streamhost@solaris | grep idle` → `idle auto-pause OFF`.
  **Remove the override before you call the station done.**
- **Solaris userland surprises:** no `wget`/`curl` (fetch with the bundled
  `/usr/bin/python` `urllib`), no `sed -i`, `/usr/bin/grep` has no `-e`/`-E`/`-q`
  and no `\|` alternation (use `/usr/xpg4/bin/grep` or python), and `/bin/sh` is
  the old Bourne shell — backticks, not `$( )`.
- **The bundled python is 2.6.4:** `re.sub()` has no `flags=` keyword (use the
  inline `(?s)`), and `except E, e:` is the syntax. Push scripts in as base64 and
  `exec` them rather than fighting shell quoting through the exec channel; the
  exec reply is also **capped around 8 KB**, so have the guest print an extract,
  not a whole file.
- **Solaris dhcpagent does not write `/etc/resolv.conf`.** It stores the
  DHCP-supplied DNS (`dhcpinfo -i e1000g1 DNSserv` → `10.99.0.2`) but leaves
  resolv.conf alone; the conversion applies it explicitly. Also set
  `nsswitch hosts: files dns`, or names never reach the resolver.
- **A `loadvm` does NOT re-fetch the SSI roster while the gateway still holds the
  golden's session.** Right after a recapture the gateway agrees with the
  restored socket, so the client never re-signs-on. To bake a *changed* roster
  you need a genuine fresh sign-on — restart Pidgin, confirm the names, then
  recapture. In production the golden's session is long gone (it died with the
  QEMU process that made it), so the wake reconnect always re-fetches.

## Operating it

```bash
# is the persona online?
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;d=json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read());print([s[\"screen_name\"] for s in d[\"sessions\"]])"'
# exec over the bridge
ssh lab 'labctl exec solaris "uname -a"'
# is Pidgin up, and what does it think the roster is?
ssh lab 'labctl exec solaris "/usr/bin/ps -ef | /usr/bin/grep pidgin | /usr/bin/grep -v grep"'
ssh lab 'labctl exec solaris "cat /.purple/blist.xml"'
# DHCP lease + no default route (containment)
ssh lab 'labctl exec solaris "ifconfig e1000g1 dhcp status; netstat -rn"'
# solaris server-side SSI/feedbag roster (should list 10000/20000/40000/64000/98980)
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 30000'
# the tap + guard chain
ssh lab 'bash /data/vms/streamhost/stations/solaris/rn-tapnet.sh show'
# the framebuffer is the only proof it reacted
ssh lab 'labctl shot solaris /tmp/solaris.png'
# re-capture the golden — CLEAN, signed-on, full-roster, Available, no chat window.
# To refresh the roster first RESTART Pidgin (a reset won't re-fetch, see gotchas):
#   savevm golden-new; querysnap; delvm golden; savevm golden; delvm golden-new
```
