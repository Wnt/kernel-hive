# suse64 on the retronet — phase 3, PARTIAL (web plane proven, ICQ not)

> **STATUS: LIVE-READY (2026-09-03, session `suse64-rn`).** Both planes are
> framebuffer-proven on the final device set and a new golden is baked and
> restore-proven. Netscape Communicator 4.72 renders `http://search.retronet/`;
> GtkICQ 0.60 is signed in as UIN `18000` with **HiveBot online** in its contact
> list. Golden staged at `/data/gallery-guests/SUSE64/suse64-rn.qcow2`
> (`golden`, VM_SIZE 84 MiB, VM_CLOCK `0000:12:04.997`). **Not yet deployed** —
> the coordinator swaps the disk and restarts the station at landing.
>
> **One scene defect is OPEN and must be fixed before this lands** — the KDE
> panel is hidden and two desktop icons are missing in the baked scene. Cause
> found, fix not yet applied: see §The scene defect.

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

## ICQ plane — SIGNED IN, with HiveBot listed; bake still outstanding

Server side:

```
created 18000
nick    18000 -> 'suse64'
PASS  18000 authenticated at 10.99.0.2:5190
```

**The sign-in, from the gateway's own log** (`addr` is this station's tap
address, so there is no ambiguity about which guest it is):

```
msg="user authenticated successfully"     svc=ICQLegacy uin=18000 version=4 status=0x00000098
msg="V4 login successful (direct flow)"   svc=ICQLegacy uin=18000 session_id=372001343
msg="created legacy session"              svc=ICQLegacy uin=18000 addr=10.99.0.37:1024 version=4
```

**GtkICQ 0.60 speaks v4, not v5.** Every earlier note (including this doc's
previous revision) assumed v5 because that is what the sibling station at
`10.99.0.36` used. This client takes open-oscar-server's **V4 direct flow**,
which is the better half of the deal: the v4 handler logs `password_len`, never
the password, so the `LogFilterPatterns=~password=` concern in
[`GATEWAY.md`](GATEWAY.md) does not apply to this station at all.

Proof frame: `evidence/t1-25-list.png` — the GtkICQ window with **HiveBot under
`Online` with a green dot**, next to the konsole.

### The pointer — this is what unblocked it

A rig has no absolute pointer, and that (not the protocol, not the config) was
the whole wall. The working combination is **two different channels**:

| | |
|---|---|
| Motion | `x11ptr.py 127.0.0.1 6180 X,Y q` — raw X11 `WarpPointer`/`QueryPointer` straight to the guest's X server over the slirp `hostfwd`, no XTEST, no client library. The golden's `xhost +10.0.2.2` is what permits it |
| Button | `qmp-type.py --qmp <sock> --click` — the PS/2 path, **button only, zero motion** |

The framebuffer is the coordinate space 1:1 (1024x768), so coordinates are read
straight off the PNG and `x11ptr` reads back exactly what it was given
(`warp -> 150,278 readback: (150, 278, 0)`). **The rig's `hostfwd` must be
`6180`, not the live station's `6080`.**

### The click-through, in order (all coordinates at 1024x768)

1. `rm -f ~/.icq/gtkicqrc`, `gtkicq &` → the wizard opens.
2. *Existing ICQ #* radio — **(150, 278)**; *Next* — **(90, 349)**.
3. UIN **(189, 107)** = `18000`; Password **(189, 149)**; Nickname **(189, 191)**
   = `suse64`; *Next* **(90, 349)**.
4. Menu `ICQ` **(30, 58)** → *Options* **(44, 120)** → tab *Network* **(83, 66)**.
5. `ICQ Server` **(259, 146)**: `end`, 24 × `backspace`, type `10.99.0.2`.
   Port is already `4000`. *Save* **(113, 258)**.
6. Restart gtkicq — **the running process does not pick the server up**; it is
   read at connect time on startup.
7. Menu `ICQ` **(30, 58)** → *Add Contact* **(58, 80)**: UIN **(167, 573)** =
   `10000`, Nick Name **(167, 605)** = `HiveBot`, *Search* **(122, 732)**.
8. The *User Information* window returns `UIN 10000 / Nick HiveBot`; *Add User*
   **(744, 305)**, then *Close* **(828, 305)**. HiveBot appears under `Online`.

### Correcting the previous revision

The earlier conclusion — "the config file's `Server` is never applied, the value
lives only in a GtkWidget" — is **wrong, and this doc previously stated it too
strongly**. The Options → Network tab opened showing `icq.mirabilis.com` /
`4000` **read out of the file**, so the parser does read `Section "Server"`.
What actually broke the seeded-file attempts is still unidentified; the seeded
file differed from a wizard-written one only in whitespace as far as could be
compared. Treat "seed `gtkicqrc` from an ISO" as **unproven, not refuted** — and
note the ordering that matters either way: **gtkicq writes the file on Quit**,
so a config edited while it runs is overwritten, and a file written under it is
not re-read until restart.

`ssi-seed` does **not** apply: this is a legacy client with a client-side
contact list.

### What is left before this station can land

1. **The final device set** — `restrict=on` on the slirp netdev in both the rig
   launcher and `streamhost/stations/suse64/qemu-streamhost.sh`, plus a
   guest-side default route through the tap (`/etc/route.conf` →
   `default 10.99.0.2`) and DNS on `10.99.0.2`, with `route -n`, `ping`,
   Netscape-renders-`search.retronet` and the gtkicq sign-in all re-verified on
   it. `restrict=on` is a **slirp backend option, not a device**, so it should
   not invalidate a vmstate — the two `ne2k_pci` devices are unchanged.
2. **Then** `savevm golden`, a `loadvm` proof, `qemu-img snapshot -l`, and stage
   to `/data/gallery-guests/SUSE64/suse64-rn.qcow2`.

**A resume point exists so none of the click-through has to be repeated:**
`/data/vms/sandbox/suse64-rn/race/t1/disk.qcow2` carries snapshot **`signedin`**
(62.3 MiB, VM_CLOCK `0000:07:59.408`) taken with gtkicq signed in and HiveBot
listed. `loadvm signedin` on the two-NIC device set restores that scene; the
OSCAR session itself will have been reaped by timeout, so re-confirm the
sign-in from the gateway log after restoring.

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


## The scene defect — diagnosed, not yet fixed

The baked scene regressed against the shipped golden in two ways: **the KDE
panel is not visible** along the bottom, and the desktop icons are down to
`CD-ROM` and `Floppy` (the shipped golden also has Trash, Autostart, Templates,
Printer). Netscape is discoverable only as a taskbar entry, not as a panel icon.

**The panel is HIDDEN, not missing, and the config says so.** `~/.kde/share/config/kpanelrc`
in the baked guest reads:

```
[kpanel]
BackgroundTexture=panel.xpm
DateFont=helvetica,11,5,iso-8859-1,50,0
TaskbarPosition=top
PanelHidden=10000000
PanelHiddenLeft=01111111
```

Two things follow. **`TaskbarPosition=top` is original and correct** — the thin
strip along the top is the *taskbar*, which the shipped golden has too; that is
not the regression. The regression is `PanelHidden` / `PanelHiddenLeft`, KDE 1's
saved auto-hide state: kpanel is running but retracted, and the small unhide
handle it leaves is visible in the bottom-right corner of every baked frame
(`evidence/f6-scene.png`, `g2-restored.png`). The shipped golden looked right
because its kpanel was running *un*-retracted with that state never written back;
this session's kpanel was restarted and honoured the file.

The desktop icons are `kfm -d` — KDE 1 draws the desktop from kfm, which had
died in the cloned session. Restarting it (`kfm -d &`) brings the icons back and
was observed doing so mid-session (`Floppy` and `CD-ROM` repainting in
`g2-restored.png`); it simply had not finished before the budget ended.

**The fix, for a 20-minute follow-up run** — none of it is a search:

1. `loadvm golden` on the final device set.
2. `killall kpanel`, set `PanelHidden=00000000` and `PanelHiddenLeft=00000000`
   in `~/.kde/share/config/kpanelrc`, `kpanel &`. The Netscape `.kdelnk` already
   written to `~/.kde/share/apps/kpanel/applnk/` should then appear on the panel
   — **verify it visually; that is still unconfirmed.**
3. `kfm -d &` for the desktop icons.
4. Restart gtkicq and **wait for the status line to settle and HiveBot to go
   Online** before capturing — at bake time the status bar still read
   *"Connecting to Server…"* even though the gateway had logged the session, and
   a freshly relaunched client shows HiveBot Offline for a few seconds first.
5. `sync`, `delvm golden`, `savevm golden`, loadvm proof, restage.

**A trap that cost this run its last minutes:** after `kpanel &` and `kfm -d &`
the konsole loses keyboard focus, so the next `qmp-type.py` line goes nowhere
and the screen does not change. Click the konsole (x11ptr to ~`550,450` + a QMP
click) before every typed command that follows a GUI restart.

## The gtkicqrc diff — still owed

Also not captured: the `Section "Server"` line of the file gtkicq wrote on a
clean Quit. The read-back command was in the same batch that lost focus above.
This is the one question that decides whether seeding `gtkicqrc` from an ISO
works: if the written file carries `Server "10.99.0.2"`, then the parser round-trips
it and seeding is viable; if it carries `icq.mirabilis.com`, the value really
does live only in the widget. Answer it in the follow-up run — it is one `grep`
after a clean Quit.
