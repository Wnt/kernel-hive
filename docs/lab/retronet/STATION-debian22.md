# debian22 retronet station (GnomeICU / Netscape 4.77) — as measured

**Status: golden baked and restore-proven on a sandbox rig; NOT yet live.** The
disk is `/data/vms/sandbox/debian22-rn/rig/disk.qcow2` (snapshot `golden`,
VM_SIZE **47.8 MiB**). Debian GNU/Linux 2.2 "potato" joins the retronet on the
**ICQ plane** (UIN `18200`, signed in) over a second bridged NIC. The **web
plane is wired but not yet rendered** — see §Undone.

## The wiring, at a glance

| | |
|---|---|
| NIC (retronet) | `-device rtl8139,netdev=n1,mac=52:54:00:52:4e:24`, backend `-netdev tap,id=n1,ifname=debian22rn0,script=no,downscript=no` |
| NIC (kept) | the pre-existing `ne2k_pci` on slirp with `hostfwd tcp:127.0.0.1:6082-10.0.2.15:6000` — the **x11warp pointer sink**, which cannot ride a bridge, exactly as OSCAR cannot ride slirp (amix precedent: two NICs) |
| **Why rtl8139 and not a second ne2k_pci** | Linux 2.2.17 numbers interfaces by driver-registration order. Two identical cards make `eth0`/`eth1` a coin toss that a `loadvm` cannot re-litigate; two *different* drivers make it deterministic — `ne2k-pci.o` = `eth0`, `rtl8139.o` = `eth1`. `rtl8139.o` is already in `/lib/modules/2.2.17/net` on CD1. |
| Tap | `debian22rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/debian22/rn-tapnet.sh up` (irix's file, retargeted) from the launcher on every start |
| Guest IP | **static `10.99.0.36/24`**, set from `/etc/init.d/rcS`. Potato's boot tree ships no DHCP client, so this is the `"addressing": "static"` case of [`WEB-PLANE-PLAN.md`](WEB-PLANE-PLAN.md). The address is still reserved in `RETRONET_DHCP_RESERVATIONS` (`52:54:00:52:4e:24=10.99.0.36`) because that file is the plane's uniqueness ledger. **No default route over eth1** (containment Lock 1). |
| DNS | `/etc/resolv.conf` = `nameserver 10.99.0.2`, `search retronet.lab`; `/etc/hosts` also pins `10.99.0.2 gateway search.retronet` so the scene does not depend on the resolver |
| Guard | `DEBIAN22RN-IN`, scoped to `10.99.0.36`, inserted above `RETRONET-IN` |
| OSCAR server | **the legacy v5 UDP door, `10.99.0.2:4000`** — not `:5190`. See below. |
| Persona / bot | UIN `18200` (nick `debian22`, `user-open`) / UIN `10000` (HiveBot); password in gitignored `registry/local.env` `RETRONET_ICQ_DEBIAN22_PASS` |
| ICQ client | **GnomeICU 0.90b** (`main/net/gnomeicu_0.90b-1.deb`, **on CD1**), a GNOME 1.0 panel applet + contact-list toplevel |
| Browser | **Netscape Navigator 4.77 static-Motif** (non-free: `navigator-smotif-477`, `navigator-base-477`, `netscape-base-477`) |

## Why GnomeICU, and why the v5 door

potato's CD1 carries **gnomeicu only** — `licq` and `licq-plugin-qt2` are not on
disc 1, and potato's `gaim` is 0.9/0.10, far older than the Gaim 0.59.9 that
tru64 builds from source. GnomeICU 0.90b speaks the **pre-OSCAR Mirabilis v5
protocol over UDP 4000**, which is exactly the door
[`GATEWAY.md`](GATEWAY.md) §"Which ICQ client" documents as reachable **only from
a bridged station** — which this station now is. os2warp (UIN `23000`) is the
other v5 client on the plane.

**Consequence, and it is structural:** a v5 client is **not SSI-aware**. The
server-side feedbag roster that `seed_contacts.py` writes is invisible to it, so
`ssi-seed` does nothing for this station — the contact list is **client-local**
and HiveBot has to be added in the client UI, which is the
[`CONTACT-SEEDER.md`](CONTACT-SEEDER.md) fallback path, not its primary one.

## Traps, each framebuffer-proven 2026-09-03

- **`/usr/bin/netscape` does not exist after a `dpkg-deb -x` compose.** The
  wrapper is made by `update-alternatives` in a postinst that never runs, and
  **`/usr/lib/netscape/477/netscape` is a DIRECTORY** — running it gives
  `Exit 126 … is a directory`, which reads like a permissions problem and is
  not. The real binary is
  `/usr/lib/netscape/477/navigator/navigator-smotif.real`, normally reached
  through `navigator-smotif` → `../../base-4/wrapper`. The builder now creates
  `/usr/bin/navigator-smotif-477` and `/usr/bin/netscape` itself.
- **GnomeICU 0.90b SEGFAULTS in Add-Contact's UIN search.** Entering `10000` on
  the "Contact Information" page and pressing Next crashes the process
  ("Application gnomeicu (process 267) has crashed … Segmentation fault") after
  the server has already returned the row. Adding HiveBot by that route does not
  work on this build.
- **GnomeICU writes `~/.gnome/GnomeICU` only on a clean exit.** After the crash
  the file held nothing but `[Placement]`, and the next launch showed the New
  User wizard again — the UIN and password were never persisted. For a *golden*
  this does not matter (the vmstate carries the running, signed-in process), but
  it means a cold boot of this disk starts at the wizard.
- **The wizard is the sign-in path.** ICQ → "Existing ICQ #" → Next → UIN → OK →
  password → OK. It signs in immediately; the panel applet turns green and its
  tooltip reads `18200: 0 Users Online`.
- **`printf 'savevm golden\nquit\n' | socat` kills the VM.** HMP executes both;
  the snapshot is written, then QEMU exits. Harmless here (the golden was
  already on disk) but it costs a relaunch — send `savevm` alone.

## Proof

| Claim | Evidence (frames under `/data/vms/sandbox/debian22-rn/rig/`) |
|---|---|
| eth1 on the retronet | `t3v.png`: `eth1 … HWaddr 52:54:00:52:4E:24 / inet addr:10.99.0.36`, `ping 10.99.0.2` 2/2, 0 % loss |
| x11warp still works on the second NIC | `xwarp.py … 400,300 700,500` → both readbacks OK, before and after restore |
| ICQ signed in, in-guest | `r8v.png`: applet tooltip `18200: 0 Users Online`, green |
| ICQ signed in, server-side | gateway `/session` lists `18200` (empty `remote_addr` = the legacy UDP door, same shape as `beos`/`50000`) |
| golden restores | fresh launch, `-boot order=c -loadvm golden -S` + QMP `cont` → `p1v.png` (desktop, applet green, terminal); `p2v.png` a typed `RESTORE-KEY-OK` reaching the terminal; `18200 online after restore: True`; a second HMP `loadvm golden` reverts the typed line (`p3v.png`) |

## Undone

- **HiveBot is not in the contact list** (the Add-Contact segfault above). Next
  route to try: seed `~/.gnome/GnomeICU`'s `[Contacts] Contacts=10000,HiveBot`
  with GnomeICU stopped, then launch — the string `Contacts/Contacts=4664755,GnomeICU Author`
  in the binary is that key's default and shows the format.
- **Netscape has never rendered `search.retronet`.** It was launched three ways;
  only the last (the wrapper symlink) is the correct one and it was not given
  time to paint. DNS to `10.99.0.2` is therefore also unproven from this guest.
- The golden's scene is consequently **desktop + terminal + signed-in applet**,
  not the briefed scene.
