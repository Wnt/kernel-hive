# irix on the retronet — the web plane, and the first MAME station on the bridge

**Status: LIVE (2026-08-24).** `irix` — SGI IRIX 6.5 on an emulated Indy, in
MAME — is on the retronet bridge `vmbr-rn` at **10.99.0.24**, statically
addressed, browsing the museum's corpus with **Netscape Communicator 4.8a**
pointed at **www.sgi.com** as the corpus holds it (12 Apr 1997). The station's
own vendor's website, on the station.

Web plane only. **No ICQ:** no OSCAR client is built for IRIX/MIPS yet, so
there is no roster row and no persona — see [Not done](#not-done).

Parents: [`../RETRONET-BRIEF.md`](../RETRONET-BRIEF.md) §4 (the web plane),
[`GATEWAY.md`](GATEWAY.md) (the CT and its two containment locks). The station
itself is [`../../guests/irix.md`](../../guests/irix.md) — read that first if
you have not met this tile: it is **not QEMU**, and almost everything about how
it is driven follows from that.

## What made this one different

Every other bridged station is a QEMU guest with a `-netdev tap`. irix is MAME
with `-video none`, and three things follow:

| | |
|---|---|
| **The NIC** | The Indy's on-board **SEEQ 80C03**, driven through MAME's `taptun` provider. MAME picks its host interface from the machine **CFG FILE**, not a switch — `network_manager::config_load` reads `<system><network><device>` and calls `set_interface()` — so `x11-runtime.sh` SEEDS `cfg/indy_4610.cfg` before every launch, exactly as it already did on the sandbox link. |
| **The MAC** | Stays SGI's OUI, `08:00:69:12:34:56`, and does NOT take the fleet's `52:54:00:52:4e:<octet>` scheme. IRIX programs the SEEQ's station address itself from the PROM `eaddr`; the launcher's `mac=` only has to agree with it. Same exception `macos753` has for Apple's OUI, for the same reason — the guest owns the address. It is L2-distinct from every other bridged station regardless. |
| **The reset** | `resetMode=relaunch`. There is no `loadvm`/QMP snapshot: the station boots by restoring a **baked MAME savestate paired with its disk**, so a guest-config change means a new seed **and** a recaptured checkpoint. Both are below. |

## The wiring, at a glance

| | |
|---|---|
| Link | tap **`irixrn0`**, persistent, enslaved to `vmbr-rn`, created + guarded by [`streamhost/stations/irix/rn-tapnet.sh`](../../../streamhost/stations/irix/rn-tapnet.sh) `up` from the launcher on **every** start (chain `IRIXRN-IN`, scoped to the guest IP) |
| Mode switch | `IRIX_NET_MODE=retronet` in `station.env` (`sandbox` is the rollback — see [Rollback](#rollback)) |
| Guest IP | **static 10.99.0.24/24**, baked in the golden. IRIX 6.5 resolves its primary interface's address by looking its hostname up in `/etc/hosts`, so the address of this machine IS its hosts entry — the same lever every irix network bake has used. A `RETRONET_DHCP_RESERVATIONS` row keeps the address unique fleet-wide without ever leasing it. |
| Default route | **NONE.** Containment Lock 1, enforced by the guest's own stack: `/etc/config/static-route.options` is removed and `routed` is off, so IRIX cannot form a packet to anything off `10.99.0.0/24`. |
| Seamless web | `/etc/resolv.conf` = `10.99.0.2` + **no Netscape proxy** → type any URL and the gateway's wildcard DNS resolves it to itself, where the `:80` origin serves the corpus or the museum's miss page |
| Browser | Netscape Communicator **4.8a**, `network.proxy.type 0`, home page `http://www.sgi.com/`, prefs seeded for **every interactive account** ([below](#the-quiet-browser-what-a-visitor-must-not-see)) |
| Golden | `irix65-apps-v11.chd`, md5 `2308405a14310b29f43be52027ad09c9` (v10 + the quiet-browser fix below) |
| Exec | **unchanged and non-network**: `labctl exec irix` rides a serial pty (`irixagent.pl` on `/dev/ttyd2`). Nothing about the retronet touches it — which is also why labhost never dials this guest. |

## Containment — the guest reaches the gateway and nothing else

Layered, so that no single failure opens anything:

1. **Topology.** `irixrn0` is enslaved ONLY to `vmbr-rn`, which has
   `bridge-ports none` and **no uplink**. The guest is never on the LAN's L2.
2. **Routing.** No default route in the guest (above). labhost's `retronet-fw`
   `RETRONET-FWD` chain drops anything trying to route *through* the box in or
   out of `vmbr-rn` regardless.
3. **Filter.** `IRIXRN-IN`, scoped to `10.99.0.24`, inserted at INPUT position 1
   above `RETRONET-IN`: every NEW flow the guest starts toward labhost is
   dropped, only replies to labhost-initiated flows return. Without it the guest
   could open labhost's `0.0.0.0` listeners — the gallery included — by dialling
   the bridge address `10.99.0.1`, which `retronet-fw` deliberately leaves
   reachable and which no-default-route does not close, because `10.99.0.1` is
   **on the guest's own subnet**.

`rn-tapnet.sh` reads its rules back out of the kernel (`verify_rules`) and
refuses to report the link up if they are not there — a lost `xtables` race
otherwise brings the tap up fail-OPEN while every message still says "up".

**What this link does expose, stated plainly:** the other guests on `vmbr-rn`
can address `10.99.0.24`, and what they would find is this guest's telnetd and
its two root-owned Apaches. The Apaches are `chkconfig`-off in the golden
(`irix-net-bake.sh` §2). The plane is the invited museum's, not the LAN's; that
is the accepted trade for being on the retronet at all, and every bridged
station makes it.

### What joining RETIRED

From 2026-08-03 to 2026-08-24 this station could **dial the real internet** —
`IRIX_NET_EGRESS=on`, a masquerade on labhost's uplink, verified with a telnet
session to `telehack.com` and pings to `1.1.1.1`. That was an explicit operator
decision at the time, and nothing could ever dial IN.

The retronet is **offline by construction** ([brief §1](../RETRONET-BRIEF.md):
stations reach the gateway's local services and nothing else), so joining
replaces that NAT with the corpus. `IRIX_NET_EGRESS=on` is now **refused** in
retronet mode rather than ignored — `vmbr-rn` has no uplink to masquerade out
of, and a station whose config claims an egress it does not have is worse than
one that will not start. The exhibit trades the live internet for a 1990s one
that is period-correct on a 1993 Indy. The [rollback](#rollback) brings the old
one back.

## Acceptance — measured, from inside the guest

All four on a clone of **v10** on a tap enslaved to `vmbr-rn`
(`irix-serial-rig.sh` + `IRIX_RIG_TAP_IF`), 2026-08-24:

```
### ifconfig ec0
ec0: flags=8400c43<UP,BROADCAST,RUNNING,FILTMULTI,MULTICAST,IPALIAS,IPV6>
        inet 10.99.0.24 netmask 0xffffff00 broadcast 10.99.0.255

### netstat -rn                      <- NO default route. Lock 1, from the guest.
Destination      Gateway            Netmask    Flags
10.99            link#1             0xffffff00 UC          ec0
127.0.0.1        127.0.0.1                     UH          lo0

### ping -c 3 10.99.0.2
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max = 0.499/0.884/1.166 ms

### ping -c 2 hamsterdance.com       <- wildcard DNS: ANY name is the gateway
PING hamsterdance.com (10.99.0.2): 56 data bytes
2 packets transmitted, 2 packets received, 0.0% packet loss

### GET / HTTP/1.0  Host: www.sgi.com   (a perl socket in the guest)
HTTP/1.0 200 OK
Server: RetroNetProxy/1.0
Content-Type: text/html
Content-Length: 27937

<TITLE>Welcome to SGI</TITLE>
```

The framebuffer acceptance — **Netscape rendering that page**, which is the only
proof that counts ([AGENTS.md](../../../AGENTS.md) rule 9) — is in
[the shot below](#the-shot).

## The quiet browser — what a visitor must NOT see

Reported by the operator against the first cut of this join, and reproduced on
the live station: *"netscape always seems to open with the error / warning
dialogs, and then after a longish wait the real browser window opens."* Two
separate causes, both now fixed in the golden (v11):

**1. The first-run flow.** The v10 bake seeded `preferences.js` for **root**
only — following the egress bake before it, which was written when a bake ran
things as root. But a visitor logs in at the iconlogin chooser as **demos**, and
`/usr/demos/.netscape` had no `preferences.js`. Netscape 4 reads that as a first
run: it opens `http://home.netscape.com/home/first.html` ("SmartUpdate"), then
`http://home.netscape.com/home/su_setup.html` — neither of which is in the
corpus, so the visitor's first impression of the exhibit is two misses and a
long wait, and never the SGI home page.

v11 seeds every interactive account — `root`, `demos`, `guest`, `chronic` — and
**chowns each profile to its account**, because Netscape rewrites
`preferences.js` on exit and cannot when the file is root-owned.

**2. The lock dialog.** *"Netscape has detected a `.netscape/lock` file. This
may indicate that another user is running Netscape using your `.netscape`
files."* The lock is a **symlink** naming `host:pid` (here
`10.99.0.24:1003`) that Netscape leaves behind whenever it does not exit
cleanly — a killed process, a station relaunch mid-session. The bake removes it
from every profile, so no golden carries one.

The prefs also turn off the era's four modal security warnings
(`security.warn_entering_secure` and friends). On a plane that serves **no
https at all** these can only ever fire spuriously, and a modal box a visitor
has to dismiss is the worst thing an exhibit can open with.

**Two shell traps found writing that bake**, both worth knowing before editing
anything that runs *inside* this guest: IRIX 6.5's `/bin/sh` is a real Bourne
shell with **no `$(...)` command substitution** — it prints the text literally
rather than running it, which made the first version silently skip its `chown`
while every line of its own output claimed success — and **no
`${var%%pattern}`**. The bake therefore uses a function with explicit arguments
and no substitution at all. (`grep -E` is absent too; `egrep` is the portable
spelling here.)

## The trap this station set: a cold boot with a MISMATCHED address wedges

Worth knowing before anyone bakes another seed here.

The **first** bake attempt attached the tap to a clone still carrying v9's
config — a guest addressed `172.31.20.2/30` sitting on a `/24` bridge with
fourteen other stations chattering on it. It **never finished booting**: the
framebuffer stayed pure black (`fbstat.py` = `0.000000`) and the serial agent
never answered, through emulated time 540 s — where a healthy cold boot answers
at ~103 s.

The same seed on the same rig with **no tap** booted and answered in 102 s, and
v10 (correctly addressed `10.99.0.24/24`) **with** the tap booted and answered
in **104 s**. So it is not the tap and not the bridge: it is a guest whose
addressing does not match the link it is on.

**Therefore: bake the config first, on a clone with NO tap, and only then boot
it on the bridge.** `irix-net-retronet-bake.sh` needs no live network — it only
edits files — and [`irix-retronet-install.sh`](../../../scripts/build-guests/irix/irix-retronet-install.sh)
pushes and runs it over the guest's console getty.

## How it was built, end to end

```bash
R=/data/vms/sandbox/<yours>/repo
export IRIX_SERIAL_ROOT=/data/vms/sandbox/<yours>/irix-serial

# 1. bake the guest config — NO tap (see the trap above)
$R/scripts/build-guests/irix/irix-serial-rig.sh boot rnbake2 \
    --chd /data/vms/streamhost/assets/irix/irix65-apps-v9.chd --capture shm --console
$R/scripts/build-guests/irix/irix-retronet-install.sh rnbake2
$R/scripts/build-guests/irix/irix-serial-rig.sh halt rnbake2      # bake-safe halt

# 2. promote the seed (444 + chattr +i, beside its siblings)
cp <rig>/rnbake2/disk.chd /data/vms/streamhost/assets/irix/irix65-apps-v10.chd

# 3. prove it on the bridge — tap first, then boot from v10
RN_TAP_IF=irixrnc0 bash $R/streamhost/stations/irix/rn-tapnet.sh up
IRIX_RIG_TAP_IF=irixrnc0 $R/scripts/build-guests/irix/irix-serial-rig.sh boot rnnet \
    --chd /data/vms/streamhost/assets/irix/irix65-apps-v10.chd --capture shm

# 4. recapture the instant-restore checkpoint against the NEW seed, then start
ssh lab 'systemctl stop streamhost@irix'
ssh lab '/data/kernel-hive/scripts/build-guests/irix/irix-savestate/capture-checkpoint.sh'
ssh lab 'systemctl start streamhost@irix'
```

Step 4 is not optional: the station boots by restoring a savestate **paired with
its disk**, so a new seed orphans the old checkpoint and the station falls back
— loudly — to a ~390 s cold boot.

## Rollback

**Golden and mode are ONE combination.** v10 can address nothing on the sandbox
link; v9 can address nothing on the retronet link. Roll them back together, in
`station.env`:

```
IRIX_NET_MODE=sandbox
IRIX_NET_EGRESS=on                                  # the internet exhibit, if wanted
IRIX_GOLDEN=…/irix65-apps-v9.chd                    # md5 10f6071c71170639243af8fbd523decd
```

then recapture the checkpoint against v9 and start the station. `IRIX_NET=off`
remains the third option and restores the no-network exhibit exactly — not one
MAME argument changes. The v9 seed is still staged beside v10.

## Not done

- **ICQ.** No OSCAR client is built for IRIX 6.5/MIPS. `climm` (which
  [`solaris`](ICQ-STATION-solaris.md) uses, built from source with the on-box
  compiler) is the obvious candidate — IRIX 6.5 ships a C compiler in the
  golden's `/usr/bin`, so this is a build job, not a sourcing one. Until it
  exists there is deliberately **no roster row**: the registry declares
  `planes: ["web"]`, and `stations-registry.py` checks that in both directions.
- **The corpus's SGI estate is broader than the home page.** `support.sgi.com`
  (1998), `techpubs.sgi.com` (1999) and `www.electricarc.com` are already
  curated in `era-sites.json` with this station in mind; none of them are
  bookmarked in the guest yet.

## The shot

See the acceptance capture referenced from the station's own doc
([`../../guests/irix.md`](../../guests/irix.md), §retronet).
