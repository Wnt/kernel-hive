# The retronet gateway — CT 951, as built

**Status: LIVE.** The first piece of the [retronet](../RETRONET-BRIEF.md) that
actually exists: an unprivileged Debian container on a bridge with no uplink,
running an OSCAR server that ICQ clients of the era can sign in to. Stream B of
the [PoC plan](POC-PLAN.md).

Everything here is reproducible from one command:

```bash
ssh lab '/data/kernel-hive/scripts/retronet/gateway/provision-gateway-ct.sh'
```

48 seconds from `pct destroy` to every acceptance check green. Each step
(`bridge`, `ct`, `install`, `accounts`, `verify`) can be named on its own and
every one of them is idempotent, so re-running is also the repair path.

## Three amendments to the PoC contract

The plan's constants were written before anyone had run the server. Three of
them do not survive contact with it. **These are the interface values other
streams must build against.**

| Plan said | Reality | Why |
|---|---|---|
| bot UIN `1000`, persona UIN `9898` | bot **`10000`**, persona **`98980`** | Mirabilis reserved every UIN below 10000, and the server enforces it (`ErrICQUINInvalidFormat`, range 10000–2147483646). `POST /user` answers **400**, so this is a hard stop, not a warning. Both numbers are the planned ones shifted one decimal place, so they stay recognisable. |
| `guestfwd` → `10.99.0.2:5190` | `guestfwd` → **`10.99.0.2:5191`** | The guest-visible address is unchanged (`10.0.2.100:5190` — the part typed into ICQ). Only the pinhole's host-side target moves, for the reason in [§Two doors](#two-doors-and-why-one-would-not-do). |
| ICQ "99b/2000b" | **2000b or later, never 99x** | ICQ 98a/99a/99b are pre-OSCAR: they speak the legacy protocol over **UDP 4000**, and QEMU's slirp `guestfwd` is **TCP only**. A 99b persona cannot reach the gateway through a slirp pinhole at all. See [§Which ICQ client](#which-icq-client). |

## The machine

| | |
|---|---|
| CT | **951**, hostname `retronet-gw`, **unprivileged**, `onboot=1` |
| Template | `debian-13-standard_13.6-1_amd64` |
| Resources | 2 cores, 1 GB RAM, 512 MB swap, 8 GB rootfs on `data` |
| Bridge | `vmbr-rn`, `10.99.0.1/24` on labhost, **`bridge-ports none`** |
| Address | `10.99.0.2/24`, **no default route**, `ip6=manual` |
| DNS | `nameserver 10.99.0.2` — itself, where the retronet's own resolver will live. Nothing answers yet, so name lookups fail, which is correct for a machine with nowhere to look things up |
| `features` | `nesting=1` |

`nesting=1` is not about running containers inside. Debian 13 ships systemd 257,
which needs it to mount `/tmp`, `/run/lock` and `/dev/mqueue` in an unprivileged
CT; without it the machine boots **degraded** with three failed mount units and
any service wanting a private `/tmp` inherits the breakage. It grants no host
access — the container stays unprivileged.

## The server

**Open OSCAR Server 0.24.0** — this is Retro AIM Server. Upstream renamed the
project (`mk6i/retro-aim-server` → `mk6i/open-oscar-server`) in 2026; the
binary, the config format and the shipped `ras.service` are continuous across
the rename, and the paths it wants are still `/opt/ras` and `/var/lib/ras`. The
`iserverd` fallback the plan allowed for was **not needed**: RAS serves ICQ UINs
natively, both the OSCAR era and the pre-OSCAR UDP one.

Installed from the pinned upstream release tarball
(`sha256 41ba8f6a…53dfb`, verified before every install), a statically linked Go
binary with no runtime dependencies. **The host fetches it; the CT never can** —
which is also why the version is pinned rather than tracked.

| Path in the CT | What |
|---|---|
| `/opt/ras/open_oscar_server` | the binary |
| `/opt/ras/rn-tool.py` | the lab's own helper — accounts, WAN proof, real logins |
| `/etc/ras/settings.env` | rendered config (`root:ras 0640`) |
| `/etc/ras/accounts.env` | the UINs and their passwords (`root 0600`) |
| `/var/lib/ras/oscar.sqlite` | accounts, buddy lists, offline messages |
| `/etc/systemd/system/retronet-oscar.service` | the unit, enabled |
| `/etc/systemd/journald.conf.d/10-retronet-retention.conf` | journal caps — 200M, 30 days |

### What it logs, and the one line it must not

The pre-OSCAR **v5** login handler logs the account password **in cleartext at
INFO**. Upstream v0.24.0 `server/icq_legacy/v5_handler.go` hands the parsed
password straight to slog (`"password", password`, three call sites), so every
v5 sign-in used to write:

```
level=INFO msg="V5 login attempt" svc=ICQLegacy uin=23000 password=<the real password> port=1537 …
```

Scope, stated exactly, because the first reports of this overstated it: **only
v5**. The v4 handler logs `password_len=8` and no secret, and OSCAR proper never
sees a cleartext password at all — it authenticates by MD5 challenge-response.
On this gateway that made it a one-account problem: `23000` (os2warp, ICQ/2
beta) is the only v5 client; `50000` (beos, ICBM .71) is v4.

The server is a **pinned, statically linked upstream release binary**, verified
by sha256 before every install and deliberately not forked or rebuilt, so the
line cannot be fixed at its source without giving up that property. Its only
logging knob is `LOG_LEVEL`, and `warn` would silence all ~2000 INFO lines
including the session lifecycle an operator actually reads — a bad trade. So the
secret is dropped one layer out, in the unit:

```ini
LogFilterPatterns=~password=
```

`systemd-journald` evaluates that against each message **before writing it**, so
a matching line never reaches the journal at all — it is not written and then
hidden. Matching the field name *with its `=`* is what keeps it surgical:

| line | verdict |
|---|---|
| `V5 login attempt … password=<secret>` | **dropped** |
| `V5 packet received … uin= addr= seq=` | kept — the attempt arrived |
| `V4 login attempt … password_len=8` | kept — no `password=` in it |
| `V5 login FAILED - invalid credentials … uin=` | kept — failures are a separate line, and carry no password |
| `user authenticated successfully` / `V5 login successful` | kept — the outcome |

So nothing operational is lost. The dropped line was redundant: its neighbours
carry the uin, the address and the outcome, and a **failed** sign-in is logged
on its own line that has no password field, so the filter never blinds the
operator to one.

Two things can silently undo this — an edited unit, and a systemd built without
PCRE2, in which case the pattern is **ignored rather than rejected**.
`provision-gateway-ct.sh verify` probes for both, plus for the absence of any
`password=` line since the server last started.

Lines written *before* this landed are still in the journal and are not worth a
purge: the CT is unprivileged, offline and has no uplink, the passwords live in
gitignored `registry/local.env` and protect nothing outside the museum, and
`journalctl --vacuum` is whole-journal — it would destroy the retronet
debugging history to remove nine lines. They expire instead, under the
`MaxRetentionSec=30day` cap the provisioner now installs. If you ever do want
them gone sooner, that is
`pct exec 951 -- journalctl --rotate && pct exec 951 -- journalctl --vacuum-time=1s`,
and it takes the rest of the journal with it.

### Restarting the server, and who comes back

`systemctl restart retronet-oscar` drops **every** signed-in session — the
listener closes and each client sees its socket die. Nothing on the gateway
re-establishes them; each persona comes back only under its own power, and the
three ways that happens have very different latencies:

| Persona | Comes back | When |
|---|---|---|
| `10000` HiveBot | on its own, within seconds | `retronet-bot` is a host-side service with its own retry loop |
| Any station whose guest is **running** | on its own | the client's auto-reconnect: seconds to ~a minute |
| Any station whose guest is **idle-paused** | **not until a visitor wakes it** | the guest is SIGSTOPped; its emulated TCP stack cannot notice the drop, let alone retry |

**A restart is not even needed to produce the symptom.** A guest that
idle-pauses stops answering, and the server reaps the dead session by TCP
timeout on its own — measured at **~2.5 minutes** after the freeze
(`read: connection timed out` → `user disconnected`). So every station goes
offline a few minutes after its last visitor leaves, and an empty gateway at
04:00 is the fleet working exactly as designed. A restart only makes the same
thing happen at once, and for everyone.

**The third row is the one that gets misdiagnosed.** Every station is
`SH_IDLE_PAUSE_SECS=60`, so outside visiting hours the whole fleet is frozen.
Restart the gateway at 03:00 and the bot is back before you finish reading the
log while every station stays signed out — which looks exactly like a fleet of
clients with no reconnect logic, and is nothing of the kind. Confirmed
2026-08-24: `64000` (tru64) sat out a 03:09Z restart for 22 minutes purely
because es40 had been SIGSTOPped since the previous afternoon, then signed back
on **17 s** after the first `labctl reset`, unattended.

Before concluding a station's client cannot reconnect, check that its guest was
actually running:

```bash
ssh lab "p=\$(pgrep -f 'assets/<station>/es40'); awk '/^State:/{print}' /proc/\$p/status"
ssh lab 'journalctl -u streamhost@<station> | grep "\[idle\]"'
```

`State: T (stopped)` and a `[idle] … -> guest paused` with no later resume mean
the guest was frozen through the whole window and proves nothing about its
client. Only `beos` has a genuine gap here — ICBM .71 has no auto-reconnect at
all and carries `icbm-watchdog.sh` for it
([`STATION-beos.md`](STATION-beos.md)).

### Ports

| Port | Proto | Bind | Who dials it |
|---|---|---|---|
| **5190** | TCP | `0.0.0.0` | **The retronet door.** Labhost-side clients: the greeter bot, `nc`, lab tooling. Advertises BOS as `10.99.0.2:5190` |
| **5191** | TCP | `0.0.0.0` | **The slirp door.** The target of a station's `guestfwd`. Advertises BOS as `10.0.2.100:5190` |
| 9898 | TCP | `0.0.0.0` | TOC, for TiK/Java-era clients. Unused so far; costs nothing. (The number is a coincidence — upstream's default, unrelated to the win98se persona) |
| 4000 | UDP | `0.0.0.0` | Legacy ICQ (v2–v5), for pre-OSCAR clients on a **bridged** station. Unreachable through slirp. **In production since 2026-08-23: `beos` / ICBM .71 / UIN `50000`** |
| 8080 | TCP | `127.0.0.1` | Management API. **Loopback inside the CT only** — it has no authentication of its own, so it must never be a retronet address. Reach it with `pct exec` |

The OSCAR server multiplexes auth, BOS, chat and everything else onto the one
listener port, so a station needs exactly **one** pinhole.

### Two doors, and why one would not do

OSCAR authentication is two hops. The client dials a listener, authenticates,
and the server answers with the address of the BOS server to connect to
**next** — and that address is the server as *the client* sees it. A process on
labhost and a station behind slirp do not see the same server:

```
  greeter bot (labhost) ──► 10.99.0.2:5190  ──BOS──► "10.99.0.2:5190"   ✓ routable
  win98se (slirp)       ──► 10.0.2.100:5190
                             │ guestfwd (host-side connect)
                             ▼
                            10.99.0.2:5191  ──BOS──► "10.0.2.100:5190"  ✓ routable
```

One listener could only advertise one of those two. Whichever it chose, the
other client would authenticate and then hang, dialling an address it cannot
route — a failure that looks like "the exhibit froze after signing in", days
later, on a station. So the server runs two named listeners over the same
database: same accounts, same buddy lists, two doors.

`provision-gateway-ct.sh verify` signs in through **both** doors and prints the
BOS address each one hands back. That is the check that keeps this honest.

### What wave 2 adds to win98se

Options-only, on the existing `n0` — no device-set change, so `loadvm` is safe:

```
guestfwd=tcp:10.0.2.100:5190-tcp:10.99.0.2:5191
```

The station then needs, in the guest's registry
(`HKEY_CURRENT_USER\Software\Mirabilis\ICQ\DefaultPrefs`):

- `Default Server Host` = `10.0.2.100`
- `Default Server Port` = `5190` (decimal)

Set these **after** installing ICQ 2000b and **before** the registration wizard
ever sees a hostname: upstream documents a client bug where a hostname entered
through the wizard leaves the client unable to remember saved passwords or the
OSCAR host. Close the wizard, edit the registry, then start ICQ and choose
*Existing User*.

### Which ICQ client

**ICQ 2000b or later. Never 98a/99a/99b.**

The 98/99 clients predate OSCAR. They speak the Mirabilis protocol over **UDP
port 4000**, and QEMU's slirp `guestfwd` forwards **TCP only** — there is no UDP
pinhole to give them. A 99b persona on a slirp station cannot reach this server
by any configuration.

**The legacy UDP listener is no longer a spare — `beos` runs on it.** Since
2026-08-23 the BeOS station signs in as UIN `50000` with ICBM .71 (a 2001
BeCQ-derived client that speaks v4), and it is the only station that can: every
other ICQ station is behind a TCP-only slirp `guestfwd`, and `beos` is on a real
bridge. The door bridges protocol generations — a legacy session joins the same
presence store as the OSCAR ones (management API `/session` lists `10000` and
`50000` side by side), an OSCAR client sees it arrive, and the server translates
an OSCAR IM down onto the legacy wire. Three behaviours of this path are load-
bearing and documented with their evidence in
[`STATION-beos.md`](STATION-beos.md) §The ICQ client:

- **`ICQ_LEGACY_SESSION_TIMEOUT` (120 s) expiring a session is the only thing
  that broadcasts a legacy user's departure.** A management-API
  `DELETE /session/<uin>` does not, and a client that quits does not either
  (ICBM sends no `CMD_LOGOUT`). The greeter bot fires on a sign-on, so this
  reaper is what makes "open the station and get greeted" work at all — do not
  raise the timeout without reading that section.
- **A stale client's keepalive silently re-creates a reaped session**, which is
  how the station comes back after an idle pause without re-authenticating.
- **`CMD_ACK_MESSAGES` (0x0442) is never ACKed** by this server. A client that
  sends it retries and gives up; it is bounded and harmless, but it looks like a
  fault in a packet log.

Peer-to-peer features — direct chat, file transfer — are **off**
(`ICQ_LEGACY_DIRECT_CONNECTIONS=` empty). They work by publishing each client's
own IP and port to the other; behind slirp that is `10.0.2.15`, an address
nobody else on the retronet can reach, so every direct connection would be an
offer that times out, and upstream warns that some clients crash on the request.

## Accounts

| UIN | Who | Password key |
|---|---|---|
| `10000` | the greeter/partner bot (stream C, runs on labhost) | `RETRONET_ICQ_BOT_PASS` |
| `98980` | the `win98se` persona | `RETRONET_ICQ_PERSONA_PASS` |

Passwords are generated on first provision and **never committed**. They live in
exactly two places, and the script keeps them equal:

1. `/etc/ras/accounts.env` inside the CT (`root 0600`) — the copy that matches
   the server.
2. `/data/kernel-hive/registry/local.env` on labhost (gitignored) — where the
   bot and any other lab tooling read them, alongside `RETRONET_ICQ_HOST`,
   `RETRONET_ICQ_PORT`, `RETRONET_ICQ_BOT_UIN` and `RETRONET_ICQ_PERSONA_UIN`.
   `registry/local.env.example` documents the keys with placeholder values.

They are eight lowercase hex characters. That is not laziness: the server
validates ICQ passwords at **6–8 characters** (mirroring what era clients
accepted) and rejects anything longer outright, and era clients mangle
characters outside `[a-z0-9]`.

**Re-creating or rotating.** Re-running `provision-gateway-ct.sh accounts`
re-reads the recorded passwords and converges the server on them — it creates
the account if missing and resets the password if it is not. So a destroyed and
rebuilt CT comes back with the *same* credentials the bot and the station
already hold. To rotate instead, delete the two `_PASS` lines from
`registry/local.env` and re-run; then update anything holding the old value.

To add a third account by hand:

```bash
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py user-set 10001 abc12345'
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py users'
```

## No WAN — two locks, both proven

The CT cannot reach the internet. That is enforced twice, at different layers,
because one of them is an omission and omissions get un-omitted.

**Lock 1 — no default route.** The CT is configured with an address and no
gateway. Its own stack refuses before a packet exists:

```
1.1.1.1:443 unreachable ([Errno 101] Network is unreachable)
```

**Lock 2 — `retronet-fw` on labhost.** labhost runs `ip_forward=1` (the irix
and tru64 host-only veths need it) with a FORWARD policy of `ACCEPT`, so lock 1
is the only thing between the retronet and vmbr0. `/usr/local/sbin/retronet-fw`
(installed by the provisioner, armed from the bridge's `post-up`) adds two
chains:

- `RETRONET-FWD` — retronet↔retronet returns, everything else in or out of
  `vmbr-rn` is dropped. No routing *through* the box.
- `RETRONET-IN` — traffic the retronet *starts* toward labhost may reach
  `10.99.0.1` and nothing else. Without it, a routed guest could open labhost's
  LAN listeners, the gallery included, by dialling the box's LAN address.

Neither lock touches the traffic that matters: the bot's connection and QEMU's
`guestfwd` are both **labhost-initiated**, so their replies arrive addressed to
the bridge address and pass. Only what the retronet starts is refused.

Lock 2 was tested by deliberately breaking lock 1 — adding a default route
inside the CT and re-probing:

```
FAIL  a default route exists via eth0          <- lock 1 broken on purpose
PASS  1.1.1.1:443 unreachable (timed out)      <- lock 2 holding
PASS  <labhost LAN address>:8443 blocked       <- the gallery, unreachable
PASS  10.99.0.1:22 open                        <- the bridge address, allowed
```

Reproduce the standing proof any time:

```bash
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py wan-probe'
```

It dials three well-known addresses **by IP** across three different networks,
so a missing resolver can never be mistaken for isolation, and it reads the
kernel's own routing table rather than trusting `ip`.

### Survives a reboot

The bridge lives in `/etc/network/interfaces.d/vmbr-rn`, which PVE's
`/etc/network/interfaces` sources. The GUI will not show it; ifupdown2 brings it
up at boot and the `post-up` arms the firewall. The CT is `onboot=1` and the
unit is `enabled`. The provisioner uses `ifup <iface>` and **never** `ifreload
-a` — reloading every interface on a box whose only route to the world is vmbr0
is not a risk worth taking for an interface with no dependencies.

Proven by cycling exactly the boot path (`pct stop` → `ifdown` → `ifup` →
`pct start`): the chains disappear with the bridge and come back with it, and
the server answers on 5190 again.

## Operating it

```bash
# is it alive
ssh lab 'nc -z 10.99.0.2 5190 && echo up'
ssh lab 'pct exec 951 -- systemctl status retronet-oscar --no-pager'
ssh lab 'pct exec 951 -- journalctl -u retronet-oscar -n 50 --no-pager'

# accounts and who is signed in right now
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py users'

# ICQ directory nickname (what a client shows a contact — `10000` -> `HiveBot`)
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py nick 10000 HiveBot'
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py nick-get 10000'
# server-side SSI/feedbag roster (the PRIMARY contact store an SSI client reads on
# login) and the legacy clientSideBuddyList shadow (non-SSI ICQ 2000b) — see CONTACT-SEEDER.md
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 98980'
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py client-buddies 98980'
ssh lab 'pct exec 951 -- python3 -c "import urllib.request;print(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read().decode())"'

# does a persona actually sign in? (real OSCAR handshake, not a port check)
ssh lab '. /data/kernel-hive/registry/local.env
  python3 /data/kernel-hive/scripts/retronet/gateway/rn-tool.py \
    login 10.99.0.2 5190 "$RETRONET_ICQ_PERSONA_UIN" "$RETRONET_ICQ_PERSONA_PASS"'

# the whole acceptance suite
ssh lab '/data/kernel-hive/scripts/retronet/gateway/provision-gateway-ct.sh verify'

# firewall state
ssh lab '/usr/local/sbin/retronet-fw status'
```

Config changes go in `scripts/retronet/gateway/settings.env.tmpl` and land via
`provision-gateway-ct.sh install`. **Editing `/etc/ras/settings.env` in the CT
is overwritten by the next run** — that file is rendered, not authored.

## Known limits

- **The management API has no authentication.** It is bound to loopback inside
  the CT and reached only through `pct exec`, which is the whole of its access
  control. Do not move it to a retronet address.
- **The CT can never update itself.** No route to a Debian mirror is the point,
  not an oversight. Security updates mean rebuilding from a newer template with
  the same script; the server binary is pinned and updated by bumping
  `OOS_VERSION`/`OOS_SHA256` in the provisioner.
- **`sshd` runs in the CT** on `10.99.0.2:22`, reachable from labhost over the
  bridge. That is operator convenience on a plane with no WAN, not an exposure.
  The Debian template's `postfix` is disabled — it could never deliver anything.
- **The firewall chains are not `iptables-save`-persisted.** They are armed by
  the bridge's `post-up`, so a boot restores them; a manual `iptables -F` does
  not. `retronet-fw up` re-arms, and `provision-gateway-ct.sh bridge` does it
  for you.
- **One station's worth of scale.** No rate limiting is configured yet. The
  brief ([§8](../RETRONET-BRIEF.md)) wants it before the fleet joins — era TCP
  stacks plus a flood is broadcast-storm nostalgia nobody ordered.
- **Nothing about the exhibit is proven here.** A green `verify` says the server
  authenticates a UIN over TCP. It says nothing about ICQ 2000b on win98se,
  which is wave 2, and the framebuffer is the only proof of that.
