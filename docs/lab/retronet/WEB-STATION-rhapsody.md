# rhapsody on the retronet web plane — the bridge as-built

**Status: wired, awaiting the cold re-bake.** `rhapsody` (Apple Rhapsody 5.1
Developer Release 2 for Intel, 1998) is on the retronet over a **real bridged
NIC** on `vmbr-rn`, with a **unique MAC**, **static** addressing, and no default
route. Read [`ICQ-STATION.md`](ICQ-STATION.md) for the shared bridge/containment
design that this station copies; this doc records what is specific to rhapsody,
and it is mostly about two things: **the NIC had to change**, and **where an
OPENSTEP-lineage system really keeps its network config**.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device tulip,netdev=n0,mac="$RN_RHAPSODY_MAC"` — DEC 21143, driven by DR2's bundled **"DEC Generic 21X4X"** driver. **This replaced the install-time `i82557b`** (see below), backend `-netdev tap,id=n0,ifname=rhaprn0,script=no,downscript=no` |
| **MAC** | unique, fleet scheme `52:54:00:52:4e:16`. Real value in gitignored `registry/local.env` as `RN_RHAPSODY_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:16` and reads the one line at boot. **Baked by a COLD boot** — `loadvm` restores the MAC from the vmstate regardless of `mac=` |
| Tap | `rhaprn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/rhapsody/rn-tapnet.sh up`, called from the launcher on every start (chain `RHAPRN-IN`, scoped to the guest IP) |
| Guest IP | **STATIC `10.99.0.22/24`** in `/etc/iftab`. DNS `10.99.0.2` in NetInfo `/locations/resolver`. **No default gateway** — `ROUTER=-NO-` in `/etc/hostconfig` |
| DHCP | **none, and none possible** — DR2 ships no DHCP client anywhere on the image. The `52:54:00:52:4e:16 -> 10.99.0.22` reservation in `RETRONET_DHCP_RESERVATIONS` exists **only to keep the address unique** on the plane |
| Browsing | the gateway's **`:80` origin**, seamlessly: wildcard DNS resolves every name to `10.99.0.2` and `Host:` picks the corpus site. **No proxy configured** |
| Pointer / exec | root getty on a **COM1 unix-socket serial chardev** (`labctl exec`), pointer is PS/2 through the daemon's abs->rel bridge — **neither rides this netdev**, which is why the slirp->tap swap was free |
| Launcher | `streamhost/stations/rhapsody/qemu-streamhost.sh` (TCG, `-cpu pentium2`, `-m 64`, `pc-i440fx-11.0`, `-vga cirrus`, `KH_I8259_LENIENT_CASCADE=1`, QEMU from `/opt/qemu-rhapsody`) |

## The NIC had to change: QEMU's eepro100 cannot feed Apple's driver

DR2 was installed with Configure.app told **"Intel EtherExpress PRO/100B PCI LAN
Adapter (v5.00)"**, matching QEMU's `-device i82557b` (PCI ID `8086:1229`, which
the driver's `Auto Detect IDs` names exactly). The driver binds, the interface
registers, and **transmit works** — on the bridge the guest's ARP requests and
gratuitous ARP appear on `rhaprn0` normally.

**Receive never works.** Measured on the bring-up rig, with echo requests
arriving on the tap addressed to the guest's own MAC:

```
en0   1500  <Link>      52.54.00.52.4e.16        0     0       22     0     0
                                              Ipkts Ierrs   Opkts Oerrs  Coll
```

`Ipkts` sits at **0** forever while `Opkts` climbs, `Ierrs` stays 0, and the
kernel log gives the mechanism:

```
en0: Intel EtherExpress PRO/100B PCI memory 0xfe000000 irq 11 100Base-TX full duplex
Intel82557: more than 1 rbd, frame size 0
en0: resetting adapter
```

Apple's `Intel82557` driver programs the chip in the 82557's **flexible receive
mode** — a receive frame descriptor pointing at separate *receive buffer
descriptors* — and QEMU's `eepro100` model does not implement that path, so the
driver reads back a descriptor chain it considers malformed (`more than 1 rbd,
frame size 0`) and resets the adapter on every inbound frame. The interrupt is
fine (IRQ 11 is delivered; this is not the i8259 cascade bug that
`KH_I8259_LENIENT_CASCADE=1` exists for). **No amount of guest-side
configuration fixes this**; the pairing is structurally TX-only.

The fix is **QEMU's `tulip`** (DEC 21143, PCI ID `1011:0019`) against DR2's
bundled **`DEC21X4XNetwork`** driver — "DEC Generic 21X4X", whose
`Auto Detect IDs` is `0x00191011 0x00091011 0x00141011 0x00021011` and so covers
`tulip` exactly. hpuxvue already proved QEMU's tulip on this bridge. With it,
`Ipkts` climbs, ARP completes, and the guest answers pings.

Activating it inside the guest is two files under `/private/Drivers/i386/`:

```sh
cp DEC21X4XNetwork.config/Default.table DEC21X4XNetwork.config/Instance0.table
# System.config/Instance0.table: "Active Drivers" — Intel82557NetworkDriver -> DEC21X4XNetwork
```

`Default.table` already carries `"Instance" = "0"`, so the copy needs no edit.

> A `-device` change alters the guest-visible device set, which `loadvm golden`
> will not tolerate. That is acceptable **only** because this join requires a
> cold re-bake anyway (the `mac=` binds on a cold boot too). It is not licence to
> change device sets elsewhere.

## Where Rhapsody actually keeps its network config

DR2 is OPENSTEP-lineage and the answer is "three places, and NetInfo is not the
one that matters for the interface".

| What | Where | Read by |
|---|---|---|
| interface address + netmask | **`/etc/iftab`** — `en0     inet 10.99.0.22 netmask 255.255.255.0 up` | `/etc/startup/0400_Network`, which feeds each line straight to `ifconfig` |
| default route | **`/etc/hostconfig`** — `ROUTER=-NO-` | `/etc/startup/0800_Routing`. `-NO-` prints *"No network routing"* and adds nothing; a bare IP there would become `route add default` |
| DNS resolver | **NetInfo `/locations/resolver`** — `nameserver`, `domain` | `lookupd`. There is **no `/etc/resolv.conf`** on this image and none is needed |
| name -> address for the host itself | NetInfo `/machines/rhapsody` `ip_address` | `lookupd`; **not** the interface configuration |

The trap: `/etc/hostconfig` has **no `INETADDR`** line, and NetInfo
`/machines/rhapsody` *does* hold an address, which makes NetInfo look
authoritative for the interface. It is not — changing it alone and rebooting
leaves `en0` on the old address. `/etc/iftab` is the file that configures the
interface. (`/etc/iftab`'s trailing wildcard rule `*  inet -AUTOMATIC- ...` is
what would trigger BOOTP autoconfiguration; the explicit `en0` line matches
first, so it never runs.)

Set all four, and keep `/machines/rhapsody` in step with `/etc/iftab` so the
guest resolves its own name correctly.

### There is no DHCP client, so static is not a preference

`find / -iname "*dhcp*"` and `-iname "*bootp*"` return **nothing** on the single
root filesystem, and there is no `ipconfig`. The only autoconfiguration DR2 has
is `bpwhoami` — a **BOOTP** whoami used by `ROUTER=-AUTOMATIC-` — and the
retronet gateway serves DHCP, not BOOTP. Rhapsody's DHCP support arrives later,
in Mac OS X Server 1.0. So this station is static for the same reason chokanji
is: the client does not exist. The reservation is kept anyway so nothing else on
the plane can be handed `10.99.0.22`.

### `grep -r` lies on this userland

DR2's `grep` does not support `-r`; with stderr redirected it returns silently
empty. Early searches for `10.0.2.15` across `/etc` and `/private` "found
nothing" and pointed the investigation at NetInfo, when the address was sitting
in plain text in `/etc/iftab` the whole time. Use `find ... -exec grep` or grep
named files.

### `arp -a` hangs

`arp -a` reverse-resolves every entry, and against the wildcard resolver that
blocks for minutes and holds the serial getty open, so the next `labctl exec`
gets *"could not log in over the serial line"*. Use `netstat -rn` (numeric),
which shows the resolved link-layer addresses anyway.

## Containment — the three layers, and what was measured

Layered exactly as [`rn-tapnet.sh`](../../../streamhost/stations/rhapsody/rn-tapnet.sh)
documents: topology (`vmbr-rn` has no uplink), routing (no default route), filter
(`RHAPRN-IN`, hooked at `INPUT 1`, scoped to `10.99.0.22`).

Measured on the cold-booted rig:

- **Reaches the gateway.** `ping spacejam.com` resolves to `10.99.0.2` through
  the wildcard DNS and replies; a hand-typed `GET /index.html HTTP/1.0` +
  `Host: spacejam.com` through `telnet 10.99.0.2 80` returns **`HTTP/1.0 200 OK`,
  `Server: RetroNetProxy/1.0`** and the 1996 Space Jam page. No proxy configured.
- **Cannot reach labhost.** `telnet 10.99.0.1 8443` (the gallery) and
  `telnet 10.99.0.1 22` (sshd) both end in *"Unable to connect to remote host:
  Operation timed out"*, while `ss -lntp` on labhost shows the gallery **is**
  listening on `0.0.0.0:8443` — the refusal is the chain, not an absent service.
  `RHAPRN-IN`'s DROP counter advances across those attempts while the
  ESTABLISHED,RELATED counter does not.
- **Cannot route off the subnet.** `ping 8.8.8.8` and `ping 192.0.2.10` both
  return **`ping: sendto: No route to host`** from the guest's own stack, and
  `netstat -rn` carries no default entry — only the on-link `10.99/24`.

## What is deliberately NOT configured

No proxy (the `:80` origin + wildcard DNS is seamless here). No default route,
ever. AppleTalk is left as the install set it (`APPLETALK=-YES-` in
`hostconfig`) but has no peer on the plane and no uplink to leak to. The station
is not on the ICQ plane and has no `inetd` exposure beyond what the fail-closed
chain already contains.

## Applying this to a fresh golden

The guest-side changes live on the **disk**, so a cold boot picks them up; the
golden vmstate does not carry them. To reproduce on any rhapsody disk, over
`labctl exec` as root:

```sh
# 1. the NIC driver (device set becomes -device tulip)
cd /private/Drivers/i386
cp DEC21X4XNetwork.config/Default.table DEC21X4XNetwork.config/Instance0.table
sed "s/Intel82557NetworkDriver/DEC21X4XNetwork/" System.config/Instance0.table > /tmp/sc \
  && cp /tmp/sc System.config/Instance0.table
# 2. the address
sed "s|^en0.*|en0     inet 10.99.0.22 netmask 255.255.255.0 up|" /etc/iftab > /tmp/ift \
  && cp /tmp/ift /etc/iftab
# 3. no default route
sed "s/^ROUTER=.*/ROUTER=-NO-/" /etc/hostconfig > /tmp/hc && cp /tmp/hc /etc/hostconfig
# 4. resolver + own name
niutil -createprop . /locations/resolver nameserver 10.99.0.2
niutil -createprop . /locations/resolver domain retronet.lab
niutil -createprop . /machines/rhapsody ip_address 10.99.0.22
sync
```

Then **cold boot** (no `-loadvm`) with `-device tulip,...,mac="$RN_RHAPSODY_MAC"`
and re-bake the `golden` snapshot from the settled desktop.

That recipe was replayed onto the production disk on 2026-08-23 and the golden
re-baked from it, so the station's live checkpoint **is** a retronet member: it
restores with `en0` at `10.99.0.22`, no default route, and OmniWeb 3.0 open on
the Space Jam corpus page. Verified after the re-bake, from the restored
checkpoint, on the wire (`tcpdump -i rhaprn0`):

```
10.99.0.22.1062 > 10.99.0.2.80: GET /index.cgi HTTP/1.0 / Host: spacejam.com
10.99.0.2.80 > 10.99.0.22.1062: HTTP/1.0 200 OK
```

## Operating notes — three things that look like faults and are not

**`systemctl stop streamhost@rhapsody` stops the GUEST, not just the daemon.**
The unit's `ExecStop` runs `stop-station-qemu.sh`, which tears QEMU down by
pidfile. To detach the daemon while keeping the guest up you cannot use the
unit; launch `qemu-streamhost.sh` by hand instead. Stopping the unit mid-bake
costs a boot cycle (the disk is fine — the guest is killed, and DR2 fscks on the
next boot).

**While the daemon runs it owns `serial.sock`,** so a direct
`serialexec.run(...)` against the station dir fails with *"could not log in over
the serial line (no login prompt)"*. That is contention, not a broken getty: use
`labctl exec rhapsody '<cmd>'`, which goes through the daemon. Direct
`serialexec` is for a bring-up rig the daemon is not attached to.

**Raw QMP `input-send-event` does not drive the pointer after a `loadvm`
restore.** Injecting relative deltas straight into QMP works on a cold-booted
guest (that is how the golden's OmniWeb window was opened), but after a
checkpoint restore the same events produce no cursor motion and no clicks. The
production input path is the daemon's abs->rel bridge, which re-homes itself on
resume (`rel_bridge.rs`, SIGUSR2); raw injection bypasses that and desyncs
against the restored PS/2 state. **Consequence for evidence:** a post-restore
*browser* interaction cannot be proven by QMP injection — prove the restored
network with `labctl exec` plus a wire capture, as above, and leave pointer
behaviour to the operator eyeball this station is still pending.
