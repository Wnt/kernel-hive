# The walk-in network plane — as built

**Status: LIVE, 2026-08-25.** The isolated segment a walk-in visitor's clone
lives on. One sentence is the whole specification, and everything below is in
service of it:

> **A walk-in clone reaches the corpus web and nothing else** — not the fleet,
> not labhost, not the internet, not another clone.

Frozen values: [`CONTRACT-LEDGER.md`](CONTRACT-LEDGER.md) §6. Reproducible from
one command, and re-running it is the repair path as well as the build path:

```bash
ssh lab '/data/kernel-hive/scripts/retronet/walkin-net/provision-walkin-net.sh --apply'
ssh lab '/data/kernel-hive/scripts/retronet/walkin-net/prove-containment.sh'
```

The second command is not optional dressing. **Containment is proven, never
assumed**: every interesting failure on this box has been a rule that read back
correctly and did nothing.

---

## The shape

```
                     vmbr-wi   (bridge-ports none, NO ADDRESS on labhost)
                        │
      ┌─────────────────┼──────────────────┬─────────  … one per clone, 9 total
      │                 │                  │
  veth952i0         wiv152o (isolated) wiv153o (isolated)
      │                 │                  │
  ┌───┴────────┐   ┌────┴─────────┐   ┌────┴─────────┐
  │  CT 952    │   │ wicell152    │   │ wicell153    │    NAT netns: SNAT the
  │ walkin-gw  │   │ peer .52     │   │ peer .53     │    baked guest address
  │ 10.99.0.2  │   │ FWD → .2 only│   │ FWD → .2 only│    to 10.99.0.<slot-100>
  └────────────┘   └────┬─────────┘   └────┬─────────┘
   DNS 53 · 3128        │ wiv152i          │ wiv153i
   origin 80 · search   │                  │
   no OSCAR · no sshd   wibr152 (cell)     wibr153 (cell)     one bridge per
   corpus read-only     │                  │                  clone: identical
                        wi-os2warp-1       wi-os2warp-2       MACs never share
                        │                  │                  an FDB
                   ┌────┴───┐         ┌────┴───┐
                   │ clone  │         │ clone  │   every os2warp clone believes
                   │ .19    │         │ .19    │   it is 10.99.0.19 — and in
                   └────────┘         └────────┘   its own cell, it is right
```

Nothing else is on this segment. labhost is not on it (it holds no address on
`vmbr-wi` or on any cell bridge; the cells' NAT lives inside their namespaces,
never in labhost's own routing).

**Why cells exist.** `loadvm` restores the NIC's MAC from saved device state,
so every clone of one station is identical on the wire — same MAC, and the
same baked IP its golden held on `vmbr-rn`. On one shared bridge three such
machines collide: the FDB entry for the shared MAC follows whichever
transmitted last, and the gateway sees one host claiming to be three. Each
clone therefore gets its own L2 domain (`wibr<slot>`), and a NAT namespace
(`wicell<slot>`) joins it to `vmbr-wi` as a unique peer. The guest is a
pristine restore — no reconfiguration, no agent, no recaptured golden — and
CT 952 is not modified at all: it simply serves more peers on its own `/24`.

## Why it looks like the retronet

**The numbering is the retronet's, on purpose.** `10.99.0.0/24`, gateway
`10.99.0.2`, the same addresses the stations hold on `vmbr-rn`.

Every golden carries the network identity it was captured with, and these guests
do not re-DHCP inside a 20-minute session: os2warp believes it holds
`10.99.0.19`, win311 `10.99.0.27`, rhapsody `10.99.0.22`. Renumbering the
walk-in plane to a fresh block would have meant three broken network stacks or
three recaptured goldens ([ledger §5.4](CONTRACT-LEDGER.md#54-a-pool-of-identical-machines-and-the-cell-that-carries-it)).
Presenting the numbering they already expect means each clone boots believing
exactly what it believed when it was captured, and is right.

**The trap this creates, stated once so nobody has to rediscover it:**

> From **labhost**, `10.99.0.2` is **CT 951, the retronet gateway** — labhost has
> a route to that /24 via `vmbr-rn` and none via `vmbr-wi`, because it holds no
> address there. A `curl` or `dig` aimed at `10.99.0.2` from a shell on labhost
> tests the *wrong machine*, and passes.

This is why `provision-walkin-net.sh` deliberately does **not** run the retronet
installers' own `verify` steps against CT 952, and why the walk-in services can
only honestly be checked from a port of `vmbr-wi` — which is what
`prove-containment.sh` does.

## The pieces, as built

| | |
|---|---|
| Bridge | `vmbr-wi`, `/etc/network/interfaces.d/vmbr-wi`, `iface … inet manual`, `bridge-ports none`, **no address** |
| labhost rules | `/usr/local/sbin/walkin-fw`, called from the bridge's `post-up`/`post-down` |
| Gateway | **CT 952 `walkin-gw`** — unprivileged Debian 13, `nesting=1`, 2 cores, **2 GB**, 8 GB rootfs, `onboot=1` |
| Gateway address | `10.99.0.2/24` on `eth0`, **single-homed**, **no default route**, `ip6=manual` |
| Corpus | `mp0 /data/vms/retronet-corpus → /data/retronet/corpus`, **`ro=1`** |
| Services | `retronet-dns`, `retronet-proxy` (`:3128` + `:80` origin), `retronet-search` — the retronet's own programs, installed by the retronet's own installers with `RN_VMID=952` |
| Not served | OSCAR `5190`/`5191`/`9898`/`4000`, **and sshd** — see below |
| Miss journal | **off** (`RN_PROXY_REQUESTS=` blank) |
| Helpers | `/usr/local/sbin/wi-isolate` (per port of `vmbr-wi`), `/usr/local/sbin/wi-clonecell` (per clone: cell + NAT + prime), `/usr/local/sbin/wi-warm-arp` (flat-plane ancestor, kept for the plane's own tooling) |

The gateway runs the **same programs** as CT 951, not a fork of them: a second
container, installed by the same installers, pointed at a different VMID. There
is no walk-in copy of `proxy.py` to drift.

### Why CT 952 exists at all

The first cut of this plane gave **CT 951 a second leg**. It was built, proven
and then removed, for two reasons that are worth keeping written down:

1. **One container cannot carry `10.99.0.2/24` twice**, and the numbering above
   is not negotiable.
2. CT 951 serves five live ICQ stations and the corpus web. A second interface
   on it put the live retronet at risk for no gain — and a dual-homed box *is* a
   router until something stops it, which meant a second lock (`ip_forward=0`
   plus an nft `FORWARD` drop) whose only job was to undo a decision nobody had
   to make.

**CT 951 is not modified at all.** A single-homed gateway has nothing to
forward, so the transit problem does not exist rather than being defended
against.

### Why there is no DHCP

Each clone keeps the address its golden was captured with. There is no scope, no
pool and no lease on this plane. (The first cut ran a second DHCP scope here,
which needed `SO_BINDTODEVICE` to stop the two scopes answering each other's
broadcasts — all of it deleted with the second leg.)

### Why sshd is off in CT 952

`sshd` binds `0.0.0.0`, and on this plane `0.0.0.0` includes the segment the
visitors are on. Nobody reaches this container over the network anyway — labhost
is not on `vmbr-wi`, so `pct exec` is the only door — which makes an sshd here
pure attack surface offered to anonymous strangers. Disabled and the socket
masked by the provisioner.

The same reasoning is why the plane withholds OSCAR, and it got a free proof:
lane 7's os2warp clone dialled `10.99.0.2` with its ICQ client, reached CT 952,
and was told *"ICQ server not accepting your login"* — the same client signs in
fine against CT 951.

## The five locks

Each is independent. None of them is the only thing standing between a visitor
and the museum's LAN.

| # | Lock | Where | What it stops |
|---|---|---|---|
| 1 | **No uplink** | `bridge-ports none` | There is no physical port to leak onto |
| 2 | **No host L3** | `iface vmbr-wi inet manual` | labhost is not a participant: nothing to dial, nothing to route through, no second route to `10.99.0.0/24` |
| 3 | **No second leg** | CT 952 single-homed, no default route | The gateway cannot forward, because it has nowhere to forward to |
| 4 | **Port isolation** | `bridge link set … isolated on` on every cell's outer veth (`wiv<slot>o`) | Cell ↔ cell on `vmbr-wi`. A Linux bridge switches between its own ports, and `bridge-nf-call-iptables` is `0` on this box, so this traffic reaches **no** netfilter hook — isolation is the only thing that stops it |
| 5 | **Cell fail-closed NAT** | `wicell<slot>`: `FORWARD` policy DROP, guest→`10.99.0.2` only; `INPUT` DROP | The first rule-based lock a clone's packets meet: even a spoofed destination is dropped one hop from the guest, before `vmbr-wi` ever carries it |

`walkin-fw` adds the backstops:

- **`FORWARD`** — `-i vmbr-wi -j DROP` and `-o vmbr-wi -j DROP`, plus the same
  by wildcard for every cell bridge (`-i wibr+`, `-o wibr+`). labhost runs
  `ip_forward=1` with a `FORWARD` policy of `ACCEPT` (the irix and tru64
  host-only veths need it), so without this the only thing between a clone and
  the WAN is the absence of a NAT rule.
- **`INPUT`** — `-i vmbr-wi -j DROP` and `-i wibr+ -j DROP`, unconditional. No `ESTABLISHED` allowance
  and no bridge-address exemption, unlike the retronet's `RETRONET-IN`.
- **`arp_ignore=8`** on the bridge — and `wi-clonecell` sets the same knobs on
  every cell bridge it creates. This one is not obvious: with the default
  `arp_ignore=0` the kernel answers an ARP request for **any** local address
  arriving on **any** interface, including one with no address of its own. A
  clone ARPing for `10.99.0.1` — labhost's *retronet* address, which its golden
  believes is on-link — could otherwise learn labhost's MAC on `vmbr-wi`.
  `arp_announce=2`, `rp_filter=1` and `disable_ipv6=1` go on at the same time.

Every rule is read back out of the kernel before `walkin-fw` reports success: a
lost `xtables` race is how an open plane comes to be described as "up".

## The helpers other lanes call

Both are installed on labhost by the `bridge` step and are self-contained.

### `wi-isolate` — per tap, called by lanes 7/8/10

```bash
/usr/local/sbin/wi-isolate on <tap>        # after enslaving to vmbr-wi
/usr/local/sbin/wi-isolate verify <tap>
/usr/local/sbin/wi-isolate gateway <port>  # assert the gateway port is NOT isolated
/usr/local/sbin/wi-isolate show
```

A station's `wi-tapnet.sh` creates and enslaves its own tap, exactly as its
`rn-tapnet.sh` sibling does, then calls `wi-isolate on "$IF"` as the last step of
`up`. `down` needs nothing: deleting the tap takes its port flags with it.

It is shared rather than copied — the one exception to the per-station rule —
because it is a property of the **bridge**, not of any station, and because
forgetting it does not break the station that forgot: it silently opens every
*other* clone to it. `on` refuses unless the tap is already a port of `vmbr-wi`,
and reads the flag back out of the kernel (`bridge -j -d link show`) before
reporting success, because the command that sets it succeeds even on a bridge
driver that does not have the flag.

The gateway's own port must stay **un-isolated**: two isolated ports cannot
talk, so an isolated `veth952i0` would take the corpus web away from every clone
at once with no rule anywhere to blame.

### `wi-clonecell` — per clone, called by the broker

```bash
/usr/local/sbin/wi-clonecell up     <slot> <guest-ip>   # cell bridge + NAT netns; prints wibr<slot>
/usr/local/sbin/wi-clonecell prime  <slot> <guest-ip> [--wait SECS]
/usr/local/sbin/wi-clonecell down   <slot>              # idempotent
/usr/local/sbin/wi-clonecell verify <slot>              # every lock, read back
/usr/local/sbin/wi-clonecell ls
```

One call builds everything a clone's identical wire identity needs: the cell
bridge `wibr<slot>` (hardened like `vmbr-wi`), the NAT namespace `wicell<slot>`
with its two veth legs, the `wi-isolate`d outer port on `vmbr-wi`, the SNAT to
peer `10.99.0.<slot-100>`, and the fail-closed FORWARD/INPUT rules. The broker
runs `up` before the station's `wi-tapnet.sh` (whose `WI_TAP_BRIDGE` is then
the cell bridge) and `down` after it; a leaked cell blocks its slot the way a
leaked tap blocks its pool index, so the broker's watchdog sweeps orphan cells
too. Inside the cell the namespace answers ARP for exactly one address — the
gateway — via a pneigh entry: every other address fails exactly as it fails on
the flat plane.

**`prime` is the cell's version of the warm-ARP repair.** The golden's stale
belief that `10.99.0.2` lives at CT 951's MAC can no longer be repaired by CT
952 pinging (the namespace terminates L2 between gateway and guest), so the
cell speaks the gateway's ARP itself, from its inner leg. The guest's ARP
**reply** — addressed to the very MAC it just merged — is the proof the repair
landed, and `prime` pins the guest's MAC (learned from that reply) into the
namespace so the return path never depends on the guest answering an
addressless probe. The guest must be **running** to answer; the broker resumes
it under a wake lease first, and `prime` fails loudly otherwise.

### `wi-warm-arp` — the flat-plane ancestor, kept for the plane's own tooling

```bash
/usr/local/sbin/wi-warm-arp <clone-ip> [--wait SECS] [--vmid 952]
#   exit 0  the gateway got an ICMP reply — the clone's ARP entry for the
#           gateway is now correct and its first page load will work
#   exit 1  no reply within --wait; do NOT hand the clone to a visitor
```

Production clones live in cells and are primed by `wi-clonecell prime`;
`wi-warm-arp` still primes anything attached to `vmbr-wi` **directly** — the
containment harness's throwaway namespaces, a bring-up rig on the flat bridge —
and its two measured lessons carry over unchanged:

**This is the one real cost of not renumbering, and it hits every station.** A
golden restores with a warm ARP cache from its retronet capture, so the guest
already believes `10.99.0.2` lives at **CT 951's** MAC — an address that does not
exist on `vmbr-wi`. Measured (lane 8): 100% loss from clone to gateway until CT
952 pinged the clone, then 0% immediately and permanently. Inbound was fine
throughout, because *receiving* the gateway's ARP is what repairs the entry.

So the fix is to make the gateway talk first — and **a ping alone is not
enough**. Every clone of a station carries its golden's MAC (`loadvm` restores
it; `mac=` cannot override it), so a respawned clone puts that same MAC on a
**new** bridge port while CT 952 still holds a `STALE` neighbour entry pointing
at the port that has gone away. A stale entry is not a silent one: the kernel
**unicasts** its probe to the old address, into nothing, and no broadcast is ever
sent. The symptom is nasty precisely because it is not the first thing anyone
tests — the *first* clone primes perfectly and every clone after a reset does
not. Lane 1 measured a fresh clone 16.9% from pristine with its network dead;
with `ip neigh del` before the ping, 0.003%.

`wi-warm-arp` therefore drops the neighbour entry before **every** attempt, then
pings, and treats the ICMP reply as the proof that the repair landed.

**The guest must be running to hear any of this.** A `-S` (SIGSTOPped) pool
member processes no frames, so priming a paused clone fails on a plane that is
working perfectly. The caller resumes it under a wake lease first
([`debug-live-station-hold-wake-lease`](../INPUT-DEBUGGING.md) is the same
mechanism); this helper fails **loudly** rather than quietly if it is not
running, because a silent pass here is a dead browser later.

## Containment proofs

Two harnesses, and both **try** things rather than inspecting rules.

`prove-containment.sh` proves the flat plane the cells stand on: two throwaway
network namespaces on isolated walk-in taps, addressed statically the way a
golden restores, one primed with `wi-warm-arp`, then everything a clone must
not be able to do, attempted. Run 2026-08-25: **31 passed, 0 failed.**

`prove-cell-containment.sh` proves the layer `wi-clonecell` adds — with the
constraint mimicked exactly: two cells whose guests carry the **same MAC and
the same IP**, both primed down the real path from a seeded stale ARP entry,
both fetching the corpus **concurrently** while the gateway neighbours two
distinct peers, and neither able to reach the other (including through the
cells' NAT peers — the new attack surface), the fleet, labhost or the
internet. It uses proof slots 198/199 from the top of the range and the proof
address `10.99.0.239`, all clear of real clones, and tears down after itself.

It is safe to run while real clones are on the plane — the two proof addresses
(`10.99.0.240`, `.241`) are outside every station's baked address — and it tears
down after itself.

| It must | Result |
|---|---|
| reach the gateway, DNS, `:80` origin, `:3128` proxy | PASS — `0% packet loss`, `HTTP 200` |
| render `search.retronet` for real | PASS — `<title>AltaVista: web</title>`, 10 corpus links, through **both** doors |
| **not** reach labhost's retronet address `10.99.0.1` | PASS — 100% loss |
| **not** reach live stations `10.99.0.24` (irix), `.25` (nextstep) | PASS — 100% loss |
| **not** reach labhost's LAN address | PASS — `Network is unreachable` |
| **not** reach the internet (`1.1.1.1`, and DNS off-box) | PASS — `Network is unreachable` |
| **not** reach OSCAR `5190`/`5191`/`9898`, sshd `22`, search backend `8090` | PASS — refused |
| **not** reach another clone (v4 and TCP, both directions) | PASS — 100% loss |
| the other clone still reaches the gateway | PASS — isolation is not an outage |
| the live retronet is unharmed | PASS — CT 951 single-homed, OSCAR/web/DNS all answering |

Lanes 7, 8 and 10 reproduced the same result with **real clones**: a clone ARPing
`10.99.0.24`/`.25` got zero replies, `10.99.0.19` could not reach `10.99.0.22`,
labhost was unreachable, and `bridge -d` showed `isolated on` on both station
taps with `veth952i0` correctly un-isolated.

### Reading a "must not" result honestly

Two different negatives show up, and both are containment:

- **`Network is unreachable`** — the clone's own stack refused before a packet
  existed. This is the *addressing* lock: no default route, so anything off the
  `/24` is unreachable by construction.
- **100% packet loss** — the packet was built and sent, and nothing on this L2
  answered. This is the *topology* lock: the address exists on the retronet, not
  here.

A "must not" that came back as `Destination Host Unreachable` **from labhost's
MAC** would be the interesting failure — it would mean `arp_ignore` had regressed.

## Operating notes

- **`search` takes ~6.5 minutes to come up.** `search.py` builds its inverted
  index over the whole corpus (41 485 documents) *before* it binds `:8090`, so
  the unit reports `active` while refusing every connection, and the proxy
  renders the period **"Search Is Offline"** page in the meantime. That is
  expected after a restart or a box reboot, on CT 951 too. It is not a walk-in
  bug and it is also not nothing: a visitor arriving in that window gets a
  browser with no way to find anything.
- **Two startup bugs were found by building this CT and fixed at the root**, both
  in the shared `web/` tree rather than worked around here:
  - `search.py` installed its `SIGHUP` handler *after* the first index build, so
    a reindex arriving in that ~6-minute window **killed the service** — default
    `SIGHUP` action is terminate. A fresh install reindexes as its last step, and
    the reindex timer fires every 15 minutes, so this was a live latent bug on
    CT 951 as well.
  - The same window plus `install-search.sh`'s own `search.py index` verify put
    ~1 GB of index building in flight at once; CT 952 at 1024 MB was
    **OOM-killed**, and the symptom was again a service reporting `active` while
    refusing connections. CT 952 is 2048 MB, matching CT 951, and
    `provision-walkin-net.sh` reconciles memory on an existing container, not
    only on create.
- **`walkin-fw`, `wi-isolate`, `wi-warm-arp` and `wi-clonecell` live in `/usr/local/sbin`, outside
  `/data/kernel-hive`.** `box-deploy` does not update them; the provisioner's
  `bridge` step does. After changing any of them, re-run:
  `ssh lab '…/provision-walkin-net.sh --apply bridge'`.
- **A portless bridge reads `DOWN`.** `ip -br addr show vmbr-wi` shows `DOWN`
  until a tap is attached, because the operational state follows carrier. The
  admin flag is up and taps enslave normally.

## Teardown

```bash
ssh lab 'pct stop 952 && pct destroy 952'
ssh lab '/usr/local/sbin/walkin-fw down vmbr-wi && ifdown vmbr-wi'
ssh lab 'for s in $(/usr/local/sbin/wi-clonecell ls | awk "{print \$3}"); do /usr/local/sbin/wi-clonecell down "$s"; done'
ssh lab 'rm -f /etc/network/interfaces.d/vmbr-wi /usr/local/sbin/{walkin-fw,wi-isolate,wi-warm-arp,wi-clonecell}'
```

The retronet is untouched by all of it.
