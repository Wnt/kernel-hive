# nokia9300rom on the retronet web plane

**LIVE 2026-09-25 (the station itself stays hidden).** The ROM window-server
sibling of [`nokia9300`](WEB-STATION-nokia9300.md) joins the web plane the same
way, so the operator can compare Opera 6.0 on both tracks. Press **Web**, then
**Open Web address**, type a name such as `www.yahoo.com` and press **Go to**.

The mechanism is nokia9300's netns cage, unchanged: read
[`WEB-STATION-nokia9300.md`](WEB-STATION-nokia9300.md) for why a netns (EKA2L1's
ESock is HLE: host sockets and `getaddrinfo()`), the `nsenter --net` trap under
`--private-users`, and why the golden needs no Opera setting. This page records
only what is this station's own.

## Its own claims

`wave.sh alloc nokia9300rom --retronet`, run under the station's session
`nokia9300rom`, so slot 220, UDP 54220 and VMID 220 were reused.

| Thing | nokia9300 | nokia9300rom |
|---|---|---|
| Switch (fixture) | `NOKIA_NET=retronet` | `NOKIA_NET=retronet`, `NOKIA_RN_IP=10.99.0.44` |
| Netns | `rn-nokia9300` | `rn-nokia9300rom` |
| Veth (host / netns end) | `nokia9300rn0` / `nokia9300rn0g` | `nokia9300romrn0` / `nokia9300romrng` (IFNAMSIZ: 15 chars) |
| Guest IP | `10.99.0.43/24` static | `10.99.0.44/24` static; reservation in `RETRONET_DHCP_RESERVATIONS` |
| MAC | `RN_NOKIA9300_MAC` in `local.env` | `RN_NOKIA9300ROM_MAC` in `local.env` (fleet scheme, tail `:2c`) |
| Guard | `NOKIA9300RN-IN` | `NOKIA9300ROMRN-IN` |
| DNS | `/etc/netns/rn-nokia9300/resolv.conf` → 10.99.0.2 | `/etc/netns/rn-nokia9300rom/resolv.conf` → 10.99.0.2 |
| UIN (allocator only, no account) | 21900 | 22000 |

## One shared helper, parameterised by station

Both stations emit `streamhost/stations/nokia9300/rn-netns.sh`. `x11-runtime.sh`
calls it with `RN_STATION=$SH_STATION` and `RN_GUEST_IP=$NOKIA_RN_IP`; the
station id names the netns, veth, chain and the `local.env` MAC variable. The
address has a default **only** for nokia9300 (10.99.0.43), so a sibling whose
fixture forgets `NOKIA_RN_IP` fails to start networked instead of coming up on
nokia9300's address. nokia9300's derived names and address are unchanged.

## Containment and acceptance

See the N9 proof below; the three layers are nokia9300's (no uplink on
`vmbr-rn`, no default route in the netns, the fail-closed guard at INPUT 1).

Measured 2026-09-25 by agent N9 on the live `streamhost@nokia9300rom`, from
the EKA2L1 process's own netns (`nsenter -t <mame.pid> -n`):

| To | Result | Lock |
|---|---|---|
| `10.99.0.2` DNS / :80 | `www.yahoo.com` → 10.99.0.2 (via the netns resolv.conf); HTTP 200 | intra-bridge (the point) |
| `10.99.0.1:8443` (labhost) | timed out (curl rc 28); the guard's DROP counter rose | the guard chain |
| `1.1.1.1:80`, `8.8.8.8:53` | `ip route get 1.1.1.1`: "Network is unreachable"; curl rc 7 | no default route |
| Opera → `http://1.1.1.1/` | "System: Unspecified error" on the framebuffer | no default route |

Framebuffer acceptance, driven through the real `/os/nokia9300rom` page (the
drawn phone, the SPA's own `<video>`), with the ROM window server painting:
Desk → **Web** opens the Nokia home page → **Open Web address** → the Go to
address dialog → `www.yahoo.com` + **Go to** renders Yahoo! with its images
and the Opera scroll bar; `http://1.1.1.1/` then gives the error note above;
Restore returns to Desk in about 3 s with the stream up.

A Restore relaunches EKA2L1 inside the same container, so the netns survives
resets, as on nokia9300.

## Rollback

Set `NOKIA_NET=off` in `streamhost/stations/nokia9300rom/station.env.fixture`,
re-emit (`station-up.sh nokia9300rom`) and restart the unit; then
`RN_STATION=nokia9300rom RN_GUEST_IP=10.99.0.44 rn-netns.sh down` removes the
cage. The `local.env` reservation stays: an address is never re-issued.
