# suse64 on the retronet — phase 3, PARTIAL (web plane proven, ICQ not)

> **STATUS (2026-09-03, session `suse64-rn`, 70-minute budget): the WEB plane is
> framebuffer-proven on the NEW device set; the ICQ plane is NOT, and no new
> golden was baked.** Netscape 4.72 renders `http://search.retronet/` from a
> cold-booted suse64 whose second NIC is a bridged tap on `vmbr-rn` at
> `10.99.0.37`. GtkICQ 0.60 is installed and autostarts, its account `18000`
> exists and is login-proven on the gateway, and its v5/UDP protocol is proven
> against this gateway — but GtkICQ's server address can only be set through a
> mouse-driven dialog, and a rig has no absolute pointer. See §ICQ plane.

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

## ICQ plane — NOT proven; GtkICQ 0.60 cannot be configured without a pointer

Server side is done and checked:

```
created 18000
nick    18000 -> 'suse64' (ICQ directory; a client receives it on add-by-UIN)
PASS  18000 authenticated at 10.99.0.2:5190
      BOS address advertised to this client: 10.99.0.2:5190
```

`gtkicq` autostarts: `~/.xinitrc` is now
`konsole -geometry 100x30+40+40 &` / `gtkicq &` / `exec startkde`, and a cold
boot brings it up on the desktop — the autostart mechanism itself is proven.

**The protocol is not the problem.** Open OSCAR Server 0.24.0 serves the
pre-OSCAR **v5 UDP** protocol natively, and on this very gateway a sibling
station signed in over it while this session was running:

```
msg="V5 login successful"        svc=ICQLegacy uin=18200 session_id=905676299
msg="created legacy session"     svc=ICQLegacy uin=18200 addr=10.99.0.36:1025 version=5
msg="V5 contact list"            svc=ICQLegacy uin=18200 count=1 contacts=[4664755]
```

`4664755` is *Jeremy Wise*, the sample contact GtkICQ writes into every fresh
config — so **GtkICQ 0.60 does interoperate with this gateway over v5/UDP**, and
slirp's TCP-only limit does not apply on the bridged `eth1`. Nothing about the
transport, the tap, the UDP port or the account blocks this station.

### The config file — fully decoded, and it is not enough

The wizard writes `~/.icq/gtkicqrc`, an XF86Config-style file. The complete
grammar, recovered from `strings /usr/X11R6/bin/gtkicq` (the format strings the
writer uses, so this is exact):

```
Section "Personal"
	UIN		"%ld"
	Password	"%s"
	Status		"0"
	Nickname	"%s"
EndSection "Personal"
Section "Server"
	Server		"icq.mirabilis.com"
	Port		"4000"
EndSection "Server"
Section "Sound"       … UserOnline / UserOnlineSound / UserOffline /
                        UserOfflineSound / RecvMessage / RecvMessageSound /
                        RecvChat / RecvChatSound
Section "Status"      … AWAY / WindowSize "%dx%d" / WindowTitle / Sound /
                        PacketDump / ChatFont
Section "Contacts"
	"4664755"	"Jeremy Wise"      <- one tab-separated "uin" "nick" pair per contact
EndSection "Contacts"
```

Separators are **hard tabs**. The default server really is `icq.mirabilis.com`
in the binary, but it is a plain string in a normal `Section "Server"` — the
value **is** meant to be configurable, so no DNS hijack of `icq.mirabilis.com`
is needed and none was used.

A complete, correctly tab-separated file was seeded from the setup ISO — UIN
`18000`, the real password, `Server "10.99.0.2"`, `Port "4000"`, and
`"10000" "HiveBot"` in `Section "Contacts"` (`evidence/t1-05-seeded.png` shows
it back through `cat -A`, tabs as `^I`). Two variants were tried: the three
sections that carry meaning, and then **all five sections in the exact order the
writer emits them**, in case the parser is a sequential state machine.

**Both fail identically, at startup, before any packet is sent:**

```
Couldn't determine hostname:
Couldn't establish connection, 0
```

The `%s` in `Couldn't determine hostname: %s` is the name being looked up, and
it prints **empty** — the connect path is calling `gethostbyname("")`. The
seeded file is intact and unmodified on disk afterwards (gtkicq dies before it
would rewrite it), so the file is present and well-formed at the moment the
lookup happens and its `Server` value still does not reach the resolver.

That matches what the symbol table says: `icqserver:G` and `portnumber:G` are
**GtkWidget globals** — `GtkEntry`s owned by the wizard/Preferences dialog. The
connect path reads the *widget*, not the parsed file, so a value that only ever
existed in `gtkicqrc` is never applied. **The server can only be set through the
GUI.**

### Why that is a wall on a rig, specifically

Both GUI routes need a pointer, and a rig has none:

- `qmp-type.py --mouse X Y` sends **relative** PS/2 motion, so absolute clicks
  at dialog coordinates do nothing — two frames apart and identical.
- This station's absolute pointer is **x11warp over the slirp forward**, which
  the streamhost daemon provides and a bare rig does not.
- Keyboard navigation gets close but not there: `alt-tab` focuses the wizard,
  `down` picks *Existing ICQ #*, `tab`+`ret` advances, and `tab`-then-type fills
  **Password** and **Nickname** — but the **UIN** entry is not reachable in the
  focus chain from where the dialog opens, and `shift-tab` does not walk back to
  it (`evidence/15-wizform.png`).

### What the next agent should do — this is now a one-shot, not a search

Do **not** re-derive any of the above. The whole remaining problem is "get a
pointer onto the rig once". Two routes, cheapest first:

1. **Stand the rig up with x11warp** (the station's own absolute-pointer path
   over the slirp `hostfwd` to `10.0.2.15:6000`, which the golden already
   permits with its `xhost +10.0.2.2`), then click through the wizard **once**:
   *Existing ICQ #* → UIN `18000`, the password from
   `RETRONET_ICQ_SUSE64_PASS`, nickname `suse64` → Preferences → Server
   `10.99.0.2`, Port `4000` → add contact `10000`.
2. Then **capture the resulting `~/.icq/gtkicqrc`** and compare it against the
   seeded file in `race/t1/cdsrc/gtkicqrc`. If they differ only in whitespace,
   the parser is fine and the widget hypothesis above is confirmed — in which
   case the durable fix for every future bake is not the file at all: it is that
   **the golden must be captured with gtkicq already signed in**, because the
   configuration lives in the running process's widgets, and the vmstate is what
   carries it. That is a natural fit for this station, whose golden already
   carries a running konsole.

`ssi-seed` is **not** applicable here: gtkicq is a v5 client with a
**client-side** contact list (the gateway logs it as `V5 contact list … count=1`
sent *by* the client), so `HiveBot` has to be in `Section "Contacts"` or added in
the GUI, and its display name comes from that file or from the account's ICQ
directory nickname (`rn-tool.py nick 10000 HiveBot`, already set).

Gaim 0.59.9 (the tru64 client) was held as the second theory and **not started**:
it needs a source tarball, GTK/glib devel packages that are not in the obvious
`suse/gra1/` series on either CD, and a `configure`+`make` on a 256 MB
guest — none of which fits beside a one-shot GUI click that is now fully
specified. Reach for it only if route 1 above fails.

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

## One more trap: never clone a rig disk from a KILLED QEMU

The T1 clone was copied from a rig whose QEMU had been stopped with
`clone-guard kill-pidfile` rather than a guest `halt`, so its ext2 was dirty and
the clone cold-booted straight into single-user maintenance:

```
/dev/hda3 was not cleanly unmounted, check forced
Deleted inode 3280 has zero dtime.  FIXED.
/dev/hda3: UNEXPECTED INCONSISTENCY; RUN fsck MANUALLY.
Give root password to login:
```

Recovery costs two boots: log in with the root password, `fsck.ext2 -y /dev/hda3`,
then **CONTROL-D** (the maintenance shell says plainly that `reboot` and
`shutdown` will not work there). **`sync; halt` inside the guest before cloning
its disk** — on this station that is not optional hygiene, because the very same
"disk is only consistent with its vmstate" property that breaks the golden's
cold boot breaks a clone taken from a killed rig.
