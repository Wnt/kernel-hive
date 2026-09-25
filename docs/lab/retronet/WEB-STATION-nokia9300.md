# nokia9300 on the retronet web plane

**LIVE 2026-09-25 (the station itself stays hidden).** The Nokia 9300
Communicator's own browser, **Opera 6.0 for Symbian OS (build 543)**, browses
the archived web. Press **Web**, then **Open Web address**, type a name such
as `www.altavista.com` and press **Go to**, and the corpus page renders. The
ROM's own Nokia home page still opens first, from `Z:` and with no network
involved. This is the web plane only. The IM plane is parked for Series 80:
there is no S80 OSCAR client and no roster row.

## The shape: a netns cage, with no NIC and no proxy

EKA2L1 has no NIC to put on a tap. Its ESock is HLE, meaning the emulator
itself answers the Symbian socket server:

- every `RSocket` is a host socket in the EKA2L1 process;
- `RHostResolver::GetByName` checks `config.yml`'s `hosts:` map first, then
  calls the host's `getaddrinfo()`;
- `RConnection::Start` completes at once (agent N2's EKA1 host access-point
  fallback in the fork).

The join is therefore the amigaos35 cage
([`WEB-STATION-amigaos35.md`](WEB-STATION-amigaos35.md)) around the whole
nspawn container:

| Thing | Value |
|---|---|
| Switch | `NOKIA_NET=retronet` in `station.env.fixture`. `off` = `--private-network`, lo only (the default for rigs) |
| Helper | `streamhost/stations/nokia9300/rn-netns.sh` (an emit aux file), called `up` by `x11-runtime.sh` on every launch. The launcher refuses to start networked if it fails |
| Netns | `rn-nokia9300`; its only interface is veth `nokia9300rn0g` |
| Link | veth `nokia9300rn0` (host end) enslaved to `vmbr-rn` |
| Guest IP | `10.99.0.43/24`, static on the netns veth; reservation kept in `RETRONET_DHCP_RESERVATIONS` (`wave.sh alloc nokia9300 --retronet`) |
| MAC | fleet scheme, tail `:2b`; the real value is only in gitignored `registry/local.env` (`RN_NOKIA9300_MAC`) |
| Default route | none: the netns has only the link route, and the container runs without `CAP_NET_ADMIN` |
| DNS | `/etc/netns/rn-nokia9300/resolv.conf` → `10.99.0.2` (the gateway's wildcard DNS), bound read-only over the container's `/etc/resolv.conf` (`--resolv-conf=off`) |
| Web door | seamless `:80`: every name resolves to the gateway, and Opera sends `Host:` on HTTP/1.1 |
| Guard | `NOKIA9300RN-IN` at INPUT 1, scoped to the guest IP (rigs get a per-interface suffix) |
| `hosts:` map | empty. DNS does the naming; the map is only for exceptions |
| Golden | **unchanged**. There is no proxy, no CommDB IAP and no Opera setting to bake |

### How nspawn enters the netns (the trap)

`systemd-nspawn --network-namespace-path=/run/netns/…` **does not work** with
this station's `--private-users`. nspawn joins the netns from inside the new
user namespace, and the kernel refuses because the netns belongs to the init
user namespace. The failure (measured 2026-09-25 on the rig) was:

```
Failed to join network namespace: Operation not permitted
Child died too early.
```

So the launcher starts nspawn **inside** the netns, as
`nsenter --net=/run/netns/rn-nokia9300 -- systemd-nspawn …` with no
`--private-network`, and the container shares that namespace. `nsenter` execs,
so `$!` and the launcher's `/proc/<pid>/exe` checks still see
`systemd-nspawn`.

### Why the golden did not change

With N2's HLE `Start()`, Opera needs no access point. With no proxy set, it
connects to whatever the name resolves to. `Opera.def` ships with
`[Proxy] Use Automatic Proxy Configuration=0` and no proxy host. N4's
`s80-commdb-patchdll` (a real "Host network" IAP in CommDB) is optional
fidelity and is not needed. A Restore relaunches EKA2L1 **inside the same
container**, so the netns and resolver survive every reset. This was proven
on live: a reset gave a new emulator pid with the same netns inode, and Yahoo
rendered afterwards.

## Containment

There are three layers, and none is load-bearing alone: topology (`vmbr-rn`
has no uplink), routing (no default route **in the netns**), and filter
(fail-closed `NOKIA9300RN-IN`). Measured 2026-09-25 from the EKA2L1
process's own netns (`nsenter -t <mame.pid> -n`):

| To | Result | Lock |
|---|---|---|
| `10.99.0.2` DNS / :80 | `www.altavista.com` → 10.99.0.2; HTTP 200 | intra-bridge (the point) |
| `10.99.0.1:8443` (labhost) | timed out (curl rc 28) | the guard chain |
| `1.1.1.1:80`, `8.8.8.8:53` | "couldn't connect", no packet formed (rc 7) | no default route |
| Opera → `http://1.1.1.1/` | "System: Unspecified error" on the framebuffer | no default route |

`rn-netns.sh up` reads its rules back out of the kernel and refuses to report
up otherwise. It also refuses if the netns has a default route.

## Acceptance (framebuffer)

On the live `streamhost@nokia9300`, driven over XTEST on `:119` under the wake
lease:

- Web opens on the Nokia home page.
- `www.altavista.com` renders "AltaVista Technology, Inc.", the 1998 page.
  Its images point at a literal `209.133.56.10`, which is not in the corpus,
  so Opera draws "Image" boxes. That is a gap in the corpus, not in the
  station.
- `www.netscape.com` renders Netscape Netcenter. The "[an error occurred
  while processing this directive]" line is in the archived page itself.
- `www.yahoo.com` renders with every image, before a Restore and after it.

Rig-first: the same sequence ran on a rig container (its own display, netns
and machine name) before the live unit changed.

Era-browser notes: Opera speaks HTTP/1.1 with `Host:`, sends
`Accept-Encoding: gzip,deflate` (the corpus serves identity; fine) and a fixed
UA, `Mozilla/4.0 (compatible; MSIE 5.0; Series80/2.0 Nokia9300/05.22 …)`.
A bare `text/html` is what the corpus serves.

## Rollback

Set `NOKIA_NET=off` in the fixture, re-emit, and restart the unit. The
container is then back to `--private-network`. `rn-netns.sh down` removes the
cage. The `local.env` reservation stays, because an address is never
re-issued.

## Not done

- The IM plane: no Series 80 OSCAR client has been sourced, and there is no
  roster row. UIN `21900` is claimed by the allocator but is not an account.
- `network.status` still says `host-only`, because the schema has no
  `retronet` value, the same as every joined station.
