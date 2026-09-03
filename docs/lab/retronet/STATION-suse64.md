# suse64 on the retronet — phase 3, PARTIAL (web plane proven, ICQ not)

> **STATUS (2026-09-03, session `suse64-rn`, 70-minute budget): the WEB plane is
> framebuffer-proven on the NEW device set; the ICQ plane is NOT, and no new
> golden was baked.** Netscape 4.72 renders `http://search.retronet/` from a
> cold-booted suse64 whose second NIC is a bridged tap on `vmbr-rn` at
> `10.99.0.37`. GtkICQ 0.60 is installed and autostarts, its account `18000`
> exists and is login-proven on the gateway, but its first-run wizard could not
> be completed in the time left — see §The wall.

## Allocation (written by the wave coordinator; do not edit here)

| | |
|---|---|
| retronet address | `10.99.0.37` |
| MAC | `52:54:00:52:4e:25` |
| tap / bridge | `suse64rn0` on `vmbr-rn` |
| guard chain | `SUSE64RN-IN` |
| ICQ UIN | `18000`, nickname `suse64`, password in `registry/local.env` as `RETRONET_ICQ_SUSE64_PASS` |

## The trap that shaped this whole session: the golden's disk is NOT cold-bootable

The shipped golden `/data/gallery-guests/SUSE64/suse64.qcow2` was captured with
`savevm` while `/` was mounted **dirty**, so the ext2 metadata for `/etc`,
`/usr`, `/opt`, `/root` and `/floppy` exists **only in the vmstate's page cache**.
Read the raw partition (`qemu-nbd -r` + `debugfs -R 'ls -l /'`, no mount) and
those directory entries carry **inode mode `0`**. A cold boot of that disk
therefore ends at:

```
VFS: Mounted root (ext2 filesystem) readonly.
INIT: version 2.78 booting
INIT: No inittab file found
INIT: can't open(/etc/ioctl.save, O_WRONLY): Not a directory
Enter runlevel:
```

`Not a directory` for a path under `/etc` is the tell: the component itself is
gone, so this is **not** a wrong `root=`. Passing `linux root=/dev/hda3`
explicitly at the LILO prompt reproduces it exactly — a dead end that costs a
boot to rule out, so rule it out by reading the filesystem, not by guessing
kernel arguments. The partition layout is as `docs/guests/suse64.md` says
(`hda1` `/boot` 17.7 M, `hda2` swap 128 M, `hda3` `/` 1.4 G) and `root=/dev/hda3`
is correct.

**Consequence, and the recipe for any future device-set change on this station:**
a new device set forbids `loadvm`, and a cold boot is impossible, so the only
route in is a two-phase run.

1. **Phase `orig`** — the ORIGINAL device set (one slirp `ne2k_pci`) plus
   `-loadvm golden -S`, then `cont`. Do every filesystem change here.
   `-loadvm` **without `-S`** fails outright:
   `Could not load snapshot 'golden' on 'ide0-hd0': Failed to load snapshot: Invalid argument`.
   That message names the block layer and reads like disk corruption; it is only
   the missing `-S`.
2. End phase `orig` with `sync; halt` and wait for `/dev/hda3 umounted` on the
   framebuffer. **That halt is what makes the disk consistent** — it is the whole
   point of the phase, not tidiness.
3. **Phase `rn`** — the NEW device set, cold boot. Now it works.

`ide1-cd0` **already exists and is empty in the original device set**, so an ISO
can be inserted with HMP `change ide1-cd0 <path>` mid-session **without changing
the device set** and without breaking `loadvm`. That is how software got in.

## Getting work into the guest — a scripted CD, not a keyboard

`qmp-type.py` types at ~8 keys/s, so multi-hundred-line configuration is not
typeable inside a budget. Everything here was done by putting **shell scripts on
the ISO** next to the RPMs and typing one short line
(`mount -t iso9660 /dev/hdc /cdrom; sh /cdrom/b.sh`). Rebuild the ISO with
`genisoimage -R -J` and re-`change ide1-cd0` for each stage.

## Packages — both came off the shipped SuSE 6.4 CDs, nothing sourced externally

| | package | from |
|---|---|---|
| Browser | **netscape-4.72-6** (Communicator; `/usr/X11R6/bin/netscape` → `communicator`) | CD2 `suse/xap1/netscape.rpm`, 17.1 MB |
| IM | **gtkicq-0.60-115** (`/usr/X11R6/bin/gtkicq`) | CD2 `suse/xap1/gtkicq.rpm`, 209 KB |

`gtkicq` is the **only** IM client on either CD — there is no kicq, licq, gaim,
everybuddy or micq RPM in the SuSE 6.4 set (`kicq.fil` on CD1 is a YaST
description file, not a package). glib/gtk/imlib were staged onto the same ISO
from CD1 `suse/gra1/` but were **not needed**: the KDE "Default" install already
carries GTK 1.2, and `rpm -Uvh gtkicq.rpm` resolved with no `--nodeps`.

## The network — NIC order is command-line order, and eth0 stays eth0

The slirp NIC is declared **first** so it keeps `eth0` and the golden's existing
`10.0.2.15` / x11warp configuration is untouched; the retronet tap is second and
becomes `eth1`. Measured in the guest:

```
eth0: RealTek RTL-8029 found at 0xc000, IRQ 11, 52:54:00:12:34:56.
eth1: RealTek RTL-8029 found at 0xc100, IRQ 11, 52:54:00:52:4E:25.
eth1  Link encap:Ethernet  HWaddr 52:54:00:52:4E:25
      inet addr:10.99.0.37  Bcast:10.99.0.255  Mask:255.255.255.0
      UP BROADCAST RUNNING MULTICAST  MTU:1500
2 packets transmitted, 2 packets received, 0% packet loss   (ping 10.99.0.2)
```

Configured by **appending** to `/etc/rc.config` (later assignments win, so an
append is a safe edit on a guest whose `sed` has no `-i`):

```sh
NETCONFIG="_0 _1"
IPADDR_1="10.99.0.37"
NETDEV_1="eth1"
IFCONFIG_1="10.99.0.37 broadcast 10.99.0.255 netmask 255.255.255.0 up"
```

No default route is added: the gateway, the corpus origin and OSCAR all live on
`10.99.0.2`, which is on the guest's own subnet. `/etc/resolv.conf` becomes
`search retronet` / `nameserver 10.99.0.2`.

**`nslookup` on this guest is a false negative.** It prints
`*** Can't find server name for address 10.99.0.2: No information` /
`*** Default servers are not available` and exits — that is BIND 8 `nslookup`
refusing to start because the resolver has **no PTR record**, not a failure to
resolve `search.retronet`. Do not read it as "DNS is broken"; the browser
resolves fine, and with the `:3128` proxy door the guest does not need DNS at
all.

## Web plane — PROVEN

`~/.netscape/preferences.js`, seeded before Netscape's first run:

```js
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "10.99.0.2");
user_pref("network.proxy.http_port", 3128);
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage", "http://search.retronet/");
user_pref("browser.startup.homepage_override", false);
user_pref("browser.cache.disk_cache_size", 8192);
user_pref("security.warn_entering_secure", false);   // + leaving / submit / mixed
```

`browser.startup.homepage_override false` is the line that matters, exactly as
on irix and tru64: without it Netscape 4 overrides the home page once and opens
its SmartUpdate tour instead.

Netscape 4.72's **own** first run still shows three modal windows that no pref
suppresses — the License Agreement (its `Accept` button has focus, so `ret`
takes it) and two "A directory has been created for use as the disk cache"
notices for `~/.netscape/cache/` and `~/.netscape/archive/`. They are one-time:
accepting the licence and letting the directories be created means a baked
golden never shows them again. Clear them with `alt-tab` + `ret`.

Proof frame: `evidence/19-searchpage.png` — `Netscape: AltaVista: Main Page`,
Location `http://search.retronet/`, the search box and the "browse the directory
by category" link painted, status `Document: Done.`, on the **cold-booted new
device set**.

A KDE 1 panel launcher was written to `~/.kde/share/apps/kpanel/applnk/` and
`~/.kde/share/applnk/Internet/` as `netscape.kdelnk`; **it was not visually
confirmed on the panel** and the correct KDE 1.1.2 panel directory is still
unverified.

## ICQ plane — NOT proven

Server side is done and checked:

```
created 18000
nick    18000 -> 'suse64' (ICQ directory; a client receives it on add-by-UIN)
PASS  18000 authenticated at 10.99.0.2:5190
      BOS address advertised to this client: 10.99.0.2:5190
```

`gtkicq` autostarts: `~/.xinitrc` is now
`konsole -geometry 100x30+40+40 &` / `gtkicq &` / `exec startkde`, and the cold
boot brings its **"Welcome to GtkICQ"** first-run wizard up on the desktop
(`evidence/10-coldboot.png`) — so the autostart mechanism itself is proven.

### The wall

The wizard could not be completed inside the budget.

- **The QMP pointer is relative.** `qmp-type.py --mouse X Y` sends *relative*
  PS/2 motion, so absolute clicks at dialog coordinates do nothing at all — two
  frames apart and identical. This station's absolute pointer is x11warp over
  the slirp forward, which is not wired up on a rig. Any UI driving here is
  keyboard-only until a rig gets x11warp.
- **Keyboard driving got most of the way.** `alt-tab` focuses the wizard
  (kwm honours it), `down` moves the radio to *Existing ICQ #*, `tab`+`ret`
  advances to the account form, and `tab`-then-type filled **Password**
  (`lIPiNTzn`) and **Nickname** (`suse64`) correctly (`evidence/15-wizform.png`).
- **The `UIN` entry never took focus.** Two `tab`s from the *Next* button land on
  *Password*, and `shift-tab` does not walk back to *UIN* — the field appears to
  be outside the reachable focus chain from where the dialog starts. Digits are
  not the problem: `suse64` typed its digits fine.

**Next agent: do not re-drive this wizard blind.** Two cheaper routes, raced:
(a) run the wizard once to completion by any means and then read the generated
`~/.icq/gtkicqrc` so it can be **seeded as a file** from the setup ISO for every
future bake — the wizard says the file is all it needs
(*"You will not need to do this again, unless you somehow remove your
`~/.icq/gtkicqrc` file"*); (b) check whether GtkICQ 0.60 even lets the OSCAR
server host/port be set — **this is unverified and is the real risk**, because
GtkICQ 0.60 is a pre-OSCAR **v5/UDP** client. If it hardcodes
`icq.mirabilis.com`, the file-seeding route dies with it and the station needs a
client that is not on the SuSE CDs.

Note for whoever seeds the roster: gtkicq is **not** SSI-aware, so
`ssi-seed` alone will not display `HiveBot` — the contact has to be added
client-side, and its name comes from the account's ICQ directory nickname
(`rn-tool.py nick 10000 HiveBot`, already set).

## Not done

- No new golden. Nothing was written to `/data/gallery-guests/`; the live
  station's `suse64.qcow2` is untouched.
- `registry/stations/suse64.json` has no `retronet` block yet, and
  `streamhost/stations/suse64/qemu-streamhost.sh` still carries the old,
  one-NIC device set. **`rn-tapnet.sh` is landed and proven** (it brought
  `suse64rn0` up on `vmbr-rn`, installed and verified `SUSE64RN-IN`, and tore
  both down cleanly), so the launcher change is the two lines in §Launcher.
- The roster row for `suse64` is not added, because the client cannot yet sign in.

## Launcher — the exact lines to add when this lands

Before QEMU starts:

```sh
/data/vms/streamhost/stations/suse64/rn-tapnet.sh up
```

and in the QEMU argument list, **after** the existing slirp NIC so it stays
`eth0`:

```
-netdev tap,id=rn0,ifname=suse64rn0,script=no,downscript=no \
-device ne2k_pci,netdev=rn0,mac=52:54:00:52:4e:25
```

The rig that proved all of the above is kept at
`/data/vms/sandbox/suse64-rn/rig/` (`launch.sh`, `RIG_MODE=orig|rn`) with its
frames in `../evidence/`.
