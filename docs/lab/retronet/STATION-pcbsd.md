# pcbsd retronet station (Konqueror + Kopete / OSCAR) — as built

**Status: BAKED, staged, not yet promoted.** `pcbsd` (PC-BSD 1.5.1 "Edison" —
FreeBSD 6.3-RELEASE + KDE 3.5.8, i386) joins **both** retronet planes on
**2026-09-03**: it browses the museum corpus with **Konqueror 3.5.8** and no
proxy, and signs into the OSCAR gateway as UIN **17900** with **Kopete 0.12.7**,
whose contact list carries the whole live fleet by name — **HiveBot** included —
from the server-side SSI roster. Both clients were already on the disk; nothing
was sourced, downloaded or compiled. Parents:
[`ICQ-STATION.md`](ICQ-STATION.md) (containment model, `rn-tapnet.sh`),
[`ICQ-STATION-solaris.md`](ICQ-STATION-solaris.md) (the Unix-GUI-client
pathfinder), [`WEB-PROXY.md`](WEB-PROXY.md) (the `:80` origin + DHCP plane),
[`CONTACT-SEEDER.md`](CONTACT-SEEDER.md), [`GATEWAY.md`](GATEWAY.md).

The golden was baked on the sandbox clone `/data/vms/sandbox/pcbsd/abs/` and is
staged at `/data/vms/streamhost/stations/pcbsd/disk.qcow2.rn`. Promotion (swap
it in, restart the station) is the coordinator's step, not this one's.

## The wiring, at a glance

| | |
|---|---|
| NIC (retronet) | `-netdev tap,id=n1,ifname=pcbsdrn0,script=no,downscript=no -device e1000,netdev=n1,mac=$RN_PCBSD_MAC` → FreeBSD 6.3 names it **`em1`**. e1000 works on the tap as-is; the `rtl8139`/`re0` fallback was never needed |
| NIC (pointer) | `-netdev user,id=n0,restrict=on,hostfwd=tcp:127.0.0.1:6079-10.0.2.15:6000 -device e1000,netdev=n0` → **`em0`**. Unchanged from phase 2 except **`restrict=on`**, which is what makes this station offline-by-construction (below). Its only job is the x11warp door into the guest's X server |
| MAC | **unique** per-station, fleet scheme `52:54:00:52:4e:xx`. Real value box-local in `registry/local.env` `RN_PCBSD_MAC` (launcher reads it; scrubbed placeholder committed). It lives in the golden's device vmstate, so a change needs a **cold re-bake** |
| Tap | `pcbsdrn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/pcbsd/rn-tapnet.sh up` from the launcher on every start |
| Guest IP | **DHCP** — `ifconfig_em1="DHCP"` in `/etc/rc.conf`. `retronet-dhcp` hands out the reserved **`10.99.0.29/24`**, DNS **`10.99.0.2`**, and **no router option** |
| DNS | `/etc/resolv.conf` ends up `search retronet.lab` + `nameserver 10.99.0.2`. **The em1 lease wins over em0's slirp lease on its own** — no `supersede`, no `prepend`, no pinned resolv.conf was needed. (dhclient rewrites the file per lease and em1's is the later one; see §What is unproven) |
| Guard chain | `PCBSDRN-IN` — ESTABLISHED,RELATED → RETURN, everything else the guest opens toward labhost → DROP, hooked into `INPUT` at 1 scoped to `-s 10.99.0.29` |
| Web plane | **Konqueror 3.5.8 (KHTML), no proxy configured.** `http://search.retronet/` renders the period AltaVista page. Frame: `/data/vms/sandbox/pcbsd/abs/w1.png` |
| ICQ plane | **Kopete 0.12.7** (`kdenetwork-kopete-0.12.7`, `/usr/local/bin/kopete`), UIN **17900**, server `10.99.0.2:5190`, autostarted and auto-signed-in |
| Persona / bot | UIN `17900` (pcbsd) / UIN `10000` (HiveBot); passwords in `registry/local.env` `RETRONET_ICQ_*` |
| Pointer / exec | unchanged: absolute **x11warp** through `em0` (`x11ptr.py 127.0.0.1 6079 X,Y`). No exec channel. Pointer readback stays exact with `restrict=on` |

## Guest-side changes (all on the golden's disk)

```
/etc/rc.conf            + ifconfig_em1="DHCP"
/etc/pf.conf            + # kernel-hive retronet: the vmbr-rn link (em1, 10.99.0.29) talks to the gateway CT 10.99.0.2
                          pass in quick on em1 from 10.99.0.0/24 to any
                          pass out quick on em1 from any to 10.99.0.0/24
~visitor/.kde/Autostart/kopete.sh   #!/bin/sh + exec kopete   (mode 755)
~visitor/.kde/share/config/kopeterc  [Account_ICQProtocol_17900]
                          AccountId=17900 Protocol=ICQProtocol
                          Server=10.99.0.2 Port=5190
                          RequireAuth=false RespectRequireAuth=false
                          RememberPassword=true Password=<obscured>
                          AutoConnect=true
~visitor/.kde/share/config/kwalletrc [Wallet] Enabled=false / First Use=false
```

**pf is ON by default in PC-BSD 1.5.1** — this is the one guest-side thing that
is easy to miss, because the outbound half works without any rule and only the
inbound half of an unusual flow would fail. The pair above is scoped to `em1`
and to the retronet subnet, so it cannot widen anything else.

## Kopete — nothing to build, nothing to download

KDE 3.5.8's own IM client ships in PC-BSD 1.5.1's base install
(`kdenetwork-3.5.8` → `kdenetwork-kopete-0.12.7`). It is SSI-aware, so the
server-side roster written by `seed_contacts.py ssi --apply` arrives on login
with the display names in it — no manual adds, no client-UI seeding, no golden
recapture when the fleet grows.

### The account was configured through the wizard, not by hand

Contrary to the freebsd411 experience on the same KDE 3 Kopete, **the Add Account
wizard is perfectly drivable on an x11warp rig**: `x11ptr.py` to a widget, QMP
`input-send-event` btn press/release to click it, `qmp-type.py` for text. The
wizard writes the account block itself, so none of libpurple-style schema
guessing applies here. Server/port live behind **Account Preferences → "Override
default server information"**; "Require authorization" is already OFF by default
in Kopete (unlike Pidgin, where it is the classic silent greeter-killer).

### The real trap is KWallet, and `kwalletrc` does not close it

Kopete 0.12's `WalletManager` opens the wallet **regardless of
`kwalletrc [Wallet] Enabled=false`** — writing that key before starting Kopete
does *not* stop the KDE Wallet Wizard from appearing, and **cancelling the wizard
loses the password**, so the station would prompt on every restore. What works:

1. Let the wizard appear and click **Next** to the *Password Selection* page.
2. Leave **"Yes, I wish to use the KDE wallet…" UNCHECKED** and click **Finish**.
   That is what actually disables the wallet (it is what wrote `Enabled=false`
   *and* `First Use=false` in a form kwalletd honours).
3. Kopete then asks for the password once in its own dialog. Tick **Remember
   password** → it stores it in `kopeterc` (`Password=` obscured,
   `RememberPassword=true`) and never asks again.

Proven by a **full power cycle**: `shutdown -p now`, cold boot, KDM autologin,
`~/.kde/Autostart/kopete.sh` → Kopete came up, signed in silently with **no
wallet wizard and no password prompt**, and the roster was populated.

### Two Behavior settings the exhibit depends on

- **Behavior → General → "Connect automatically at startup"** (`AutoConnect=true`).
  Without it Kopete starts offline and a visitor sees an empty, grey roster.
- **Behavior → Away Settings → "Use auto away" OFF.** The default flips the
  station to *Away* after 10 idle minutes — the museum station would advertise
  itself as absent, and the golden would bake that in. (Same lesson as solaris.)
- Message Handling was set to **"Open messages instantly"** so HiveBot's greeting
  opens a real chat window while the visitor watches, instead of sitting silently
  in the tray queue.

## Contacts

Roster row added to `scripts/retronet/icq/roster.json`
(`pcbsd` / `17900` / nick `pcbsd` / client `unix-oscar` / `onboarded: true`) and
`seed_contacts.py ssi --apply` re-run: every live account now carries **13**
buddies, pcbsd included, and `17900`'s own roster is the other twelve + HiveBot.
Kopete shows them by name in group `contacts-icq8-17900`.

Sign-in + greeting proof: `/data/vms/sandbox/pcbsd/abs/icq-greeting.png` —
HiveBot online in the list and a live chat window from it.

## Containment — measured from inside the guest

`restrict=on` on the slirp netdev is the change that makes this station
offline-by-construction rather than merely inconvenient to route out of: before
it, `em0` handed the guest a working default route via `10.0.2.2` and QEMU
user-net would have NATted it to the real world. With it, the guest has **no
default route at all** (`netstat -rn -f inet | grep -c default` → `0`).

| From the guest | Result |
|---|---|
| `ping 10.99.0.2` (gateway CT) | **1/1, 0% loss** |
| `fetch http://search.retronet/` | **WEB-OK** (Konqueror renders it too) |
| `nc -z 10.99.0.2 5190` (OSCAR) | **"Connection to 10.99.0.2 5190 port [tcp/aol] succeeded!"** |
| `nc -z -w3 10.99.0.1 8443` (labhost gallery) | **BLOCKED** (`PCBSDRN-IN` DROP) |
| `nc -z -w3 10.99.0.1 22` (labhost sshd) | **BLOCKED** |
| `ping 1.1.1.1` | **no route to host**, 100% loss |
| `fetch http://1.1.1.1/` | **"Network is unreachable"** |
| default routes in the table | **0** |
| `ping 10.0.2.2` | replies (slirp's own internal responder inside QEMU, not labhost — it answers even under `restrict=on` and reaches nothing) |

## The golden

Baked 2026-09-03 on the sandbox clone with the **final** device set (both NICs,
`restrict=on`): `savevm golden` on `disk.qcow2` — VM_SIZE **305 MiB**, VM_CLOCK
**0:11:39.919**. One `loadvm golden` restore proven **pixel-identical** to the
pre-save frame; after the restore the Kopete roster is still populated with
HiveBot online, and `x11ptr.py … 470,690 q` reads back `(470, 690, 16)` exactly.

**Scene:** Kopete's contact list top-left showing the roster with HiveBot online;
**Konsole is the focused keyboard surface** (empty `%` csh prompt, window
176..846 × 108..608); no chat window baked (the greeting then arrives live, while
the visitor watches); pointer parked at **(470, 690)** on clear desktop.
KWin here is **`FocusPolicy=ClickToFocus`**, so the parked pointer does not steal
focus from Konsole — but it also means *the last click decides where typed keys
go*, which is worth knowing before driving this guest.

Staged (not promoted) at `/data/vms/streamhost/stations/pcbsd/disk.qcow2.rn`,
2927 MB sparse copy, `golden` present.

## What is unproven

- **The resolv.conf race.** em1's lease currently wins because dhclient rewrites
  `/etc/resolv.conf` per lease and em1 is configured later. Under `restrict=on`
  em0 no longer even took a lease on the last boot, which makes the outcome
  stable in practice — but it was *observed*, not forced. If a future change
  brings em0's lease back and it lands last, pin it with a
  `dhclient.conf` `interface "em0" { supersede domain-name-servers 10.99.0.2; }`.
- **The Konqueror panel icon** was not added: PC-BSD's Kicker already carries a
  Konqueror launcher (4th icon), so the browser is one click away as shipped.
  The panel's *first* icon is **Firefox**, which is what a visitor is likelier to
  press; Firefox on this plane is untested.
- **No reconnect-after-network-loss test.** Kopete's OSCAR plugin reconnects on
  its own, but that was not exercised here.
- The station has **no exec channel**, so everything above was driven through the
  framebuffer and x11warp; there is no scripted regression for it.

## Reconnect after a golden restore — proven on the live station

`loadvm golden` hands Kopete a TCP socket the gateway no longer knows. Measured
2026-09-03 on the live station under a `guest_wake` lease (180 s asserted
running): the gateway journal logs `RelayToScreenName: session not found …
screenName=17900` for the stale socket and then `user signed on … screenName=17900
ip=10.99.0.29` **59 s after the reset** (a second run: 58 s). Kopete 0.12's own
reconnect handles it; no watchdog is needed. The frame at +3 min shows the contact
list online with HiveBot. Trap: a reset proof "waited" with no viewer and no lease
is invalid — the station idle-pauses and the wait never elapses in the guest.
