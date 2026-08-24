# hpuxvue on the retronet web plane — the bridge as-built (HP-UX 10.20 / HP VUE)

**Station:** `hpuxvue` (slot 144) — HP-UX 10.20 with HP VUE 3.0 on an emulated
HP 9000/778 B160L (PA-RISC, `qemu-system-hppa` from the kernel-hive fork at
`/opt/qemu-hppa`, **TCG only**). This is the first **PA-RISC** station on the
retronet and the first one with **no exec channel** at the time the work
started.

Read [`ICQ-STATION.md`](ICQ-STATION.md) (the win98se pathfinder) for the shared
design — bridge swap, unique-MAC cold bake, containment, seamless web. This doc
records only what is **specific to hpuxvue**, and there is a lot of it: three of
the pathfinder's assumptions do not hold here.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device tulip,netdev=n0,mac="$RN_HPUXVUE_MAC"` (**unchanged device**), backend `-netdev tap,id=n0,ifname=hpuxrn0,script=no,downscript=no` |
| **MAC** | unique, fleet scheme **`52:54:00:52:4e:14`** (`52:4e`=RN, `.20`→`…14`). Real value in gitignored `registry/local.env` `RN_HPUXVUE_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:14` and reads the one line at boot |
| HP-UX driver | **`btlan3`** — HP's PCI 100Base-TX driver, which claims the emulated DEC 21140 as **`lan0`** at hardware path `8/0/1/0`. `lanscan` shows station address `0x525400524E14`, `HP DLPI Support: Yes` |
| Tap | `hpuxrn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/hpuxvue/rn-tapnet.sh up` from the launcher on every start (chain `HPUXRN-IN`, scoped to the guest IP) |
| Guest IP | **static `10.99.0.20/24`**, DNS `10.99.0.2`, **no default gateway** — see "Why not DHCP" below. The address is exactly the one `retronet-dhcp` reserves for this MAC, so the reservation stays correct and unused |
| Seamless web | `/etc/resolv.conf` → `10.99.0.2` + **no proxy configured anywhere** → every name resolves to the gateway and its `:80` origin serves the corpus |
| Browser | **NCSA X Mosaic 2.7b5** (PA-RISC 1.1, an HP-UX 9.01 build) in `/opt/mosaic`, wrapper `/usr/bin/mosaic`, desktop launcher `/Mosaic` |
| Exec | none over the network. A **serial console** was added instead (see below) |
| Launcher | `streamhost/stations/hpuxvue/qemu-streamhost.sh` |

## Three things the win98se recipe does NOT predict

**1. `loadvm` refuses across the slirp→tap swap.** On the x86 stations the
netdev backend is invisible to `savevm`/`loadvm`, so the golden survives the
bridge swap and only the MAC needs a cold bake. Not here: the hppa golden's
vmstate carried a **`slirp` section**, and starting on the tap failed with

```
qemu-system-hppa: Unknown section or instance 'slirp' 0. Make sure that your
current VM setup matches your saved VM setup, including any hotplugged devices
```

So the golden had to be cold re-baked **regardless of the MAC**. Budget for it:
a cold boot of this guest is long (see "Everything is slow" below).

**2. Reverting the golden leaves the filesystems dirty.** `qemu-img snapshot -a
golden` restores the disk to the state of a *running* system, so the first cold
boot stops in `bcheckrc` with `COULD NOT FIX FILE SYSTEM WITH fsck -p, RUN fsck
INTERACTIVELY!`. Fix from that prompt: `fsck -y /dev/vg00/rlvol4` … `rlvol8`,
then `exit` (**`^D` does not work through the ITE console — send `exit`**).
Every later boot is clean because the guest is shut down properly with
`/sbin/shutdown -r -y 0`.

**3. `autoLogin` does not fire on a cold boot.** `docs/guests/hpuxvue.md` marked
`Vuelogin*autoLogin: root` as unverified; it is now verified **false** — a cold
boot lands on the `vuelogin` greeter and needs `root` + Return + Return. This
only matters when re-baking; the exhibit golden restores an already-logged-in
session.

## Why not DHCP — and what was tried

The brief asked for DHCP. HP-UX 10.20 **does** ship a DHCP client
(`/sbin/auto_parms` + `/usr/lbin/dhcpclient`, both present), and
`DHCP_ENABLE[0]=1` in `/etc/rc.config.d/netconf` is the right switch. It does
not work on this hardware, and the failure is specific and reproducible:

```
# /usr/lbin/dhcpclient -b lan0 -l 5 -f /tmp/dhcp.trace
get_ppa_info: Failed to locate lan0 in ppa info
Boot: open of interface failed
dhcpclient exiting with status of 8
```

`dhcpclient` talks **DLPI** directly and enumerates interfaces by PPA. It cannot
find `lan0`, and it dies **before sending a single frame** — confirmed from
outside the guest: nothing from `52:54:00:52:4e:14` ever reached
`retronet-dhcp`, and the MAC was absent from `bridge fdb show dev hpuxrn0` until
the interface was configured by hand. At boot the same thing happens quietly:
`auto_parms` logs one line to `/etc/auto_parms.log` —
`DHCP is disabled for: lan0` — and turns `DHCP_ENABLE[0]` back to `0`.

The cause is a vintage mismatch. `/usr/lbin/dhcpclient` is dated **Jun 7 1996**
(the base 10.20 press); `btlan3`, the PCI 100BT driver that claims this card,
arrived with the **July 1997 Networking ACE**. The 1996 client does not know
how to find a 1997 driver's PPA. `insf -d btlan3 -e` creates no device file
(btlan3 is DLPI-only), so there is nothing to point it at.

The normal remedy — a `PHNE_*` networking patch carrying a newer `dhcpclient` —
**is not available on this guest**: SD-UX is broken here. `swagentd`'s loopback
RPC fails (`Connection request rejected (dce / rpc)`), which is the same defect
that hung the original install's finale (`docs/guests/hpuxvue.md`); `swlist`
and `swinstall` hang. Patching is therefore off the table until SD-UX is
repaired, which is a separate piece of work.

**The fallback loses nothing that matters.** The station is configured static on
**the address the DHCP server reserves for its MAC**, with the same DNS and —
the part that carries the containment posture — **no default gateway at all**.
On a DHCP station the no-WAN posture comes from the server withholding option 3;
here it comes from `ROUTE_GATEWAY[0]=""`. The routing table is the proof:

```
Destination     Gateway         Flags   Refs     Use  Interface
127.0.0.1       127.0.0.1       UH         0     298  lo0
10.99           10.99.0.20      U          0      55  lan0
```

Two entries. There is no default route to withhold.

The reservation is deliberately **left in place** in `RETRONET_DHCP_RESERVATIONS`:
it costs nothing, it keeps `10.99.0.20` from being handed to anyone else out of
the dynamic pool, and it is what the station will use unchanged the day a newer
`dhcpclient` can be installed.

## Containment — the guest reaches the retronet and nothing else

Same layered locks as every other station (no default route / `retronet-fw` /
the per-station `HPUXRN-IN` guard chain, scoped to the guest's source IP and
inserted above `RETRONET-IN`). Re-proven from inside the guest:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (the `:80` corpus origin) | **Reply**, 1–2 ms | intra-bridge L2 (the point) |
| `spacejam.com` → `10.99.0.2` | **Resolves + reply** | wildcard DNS (`retronet-dns`), no proxy |
| labhost bridge `10.99.0.1` | **100 % packet loss** | the `HPUXRN-IN` guard chain |
| internet `1.1.1.1` (by IP) | **`sendto: Network is unreachable`** | no default route (Lock 1) |

`retronet-fw` runs with `bridge-nf-call-iptables=0`, so guest↔CT traffic is pure
L2 and never touches these chains — the retronet reaching the retronet.

## The browser — Mosaic, because Netscape 4 will not run here

**Shipped: NCSA X Mosaic 2.7b5**, the HP build (`Mosaic-hp-2.7b5`), installed at
`/opt/mosaic/Mosaic-27b5`. 2.6 and 2.4 are installed beside it as fallbacks.
Provenance + SHA256 in [`ASSETS-MANIFEST.md`](../ASSETS-MANIFEST.md).

### Netscape 4.79 was sourced, installed, and does not work — do not retry it

Netscape Navigator **4.79** for HP-UX 10.20 (PA-RISC 1.1) exists, was found, and
installs cleanly by its own `README.install`. It even reports itself:

```
$ DISPLAY= /opt/netscape/netscape -version
Netscape Lite 4.79/U.S., 17-Oct-01; (c) 1995-2000 Netscape Communications Corp.
```

But it **never opens a window**. Started with a valid `DISPLAY`/`XAUTHORITY`
(proven good — `xset q` works from the same shell) it burns **9+ minutes of
CPU**, creates no `~/.netscape`, and the X server's CPU time stays *completely
flat*, so it never even talks to the display. `ps -el` shows it in state **`R`
with no wait channel**: a genuine busy loop, not TCG slowness.

The cause is almost certainly the patch level. This guest is a **pristine
June-1996 press + the July-1997 Networking ACE, with no `PHSS_`/`PHNE_`
patches at all**; Netscape's own release notes list linker/loader and Motif
patches (e.g. `PHSS_14449`) as prerequisites for a 2001 build on 10.20. Those
patches **cannot be installed** because SD-UX is broken here (see below), so
this is not a fixable gap today.

**Netscape is therefore removed from the guest** (`/opt/netscape` and
`/usr/bin/netscape` deleted). Leaving it installed but unwired would be a trap:
a visitor who found it would peg the station's host core forever.

### Why Mosaic runs where Netscape does not

Mosaic 2.7b5 is a **1995 HP-UX 9.01** binary, and its entire dependency set is

```
/lib/dld.sl  /lib/libc.sl
/usr/lib/X11R5/libX11.sl  /usr/lib/X11R5/libXt.sl
/usr/lib/X11R4/libXmu.sl  /usr/lib/Motif1.2/libXm.sl
```

— libc, X11, Xt, Xmu, Motif 1.2 and nothing else. That is exactly what an
unpatched 1996 10.20 press ships. HP-UX 10.20 keeps the 9.x compatibility
directories but names the libraries by **version** (`libX11.1`) rather than the
`.sl` the 9.01 loader recorded, so the only work needed was three symlinks:

```
ln -s libX11.1 /usr/lib/X11R5/libX11.sl
ln -s libXt.1  /usr/lib/X11R5/libXt.sl
ln -s libXm.1  /usr/lib/Motif1.2/libXm.sl
```

(`/usr/lib/X11R4/libXmu.sl` and `/lib/libc.sl` are already present.) No patches,
no swinstall. Mosaic then starts in **seconds** and sits idle at ~0 % CPU —
the exact opposite of Netscape's spin.

`Mosaic.ad`, NCSA's own `app-defaults`, is installed as
`/usr/lib/X11/app-defaults/Mosaic`; without it Mosaic can come up unusable.

### Two Mosaic quirks worth knowing

- **2.6 has no JPEG** (NCSA's own README says so), so it offers to *save* Space
  Jam's `.jpg` instead of showing it. **2.7b5 has JPEG, PNG and tables** — that
  is why 2.7b5 is the one wired up.
- **Mosaic does not parse `Content-Type: text/html; charset=iso-8859-1`.** The
  corpus is served as a bare `text/html` and renders fine; the **search /
  directory service adds a `charset` parameter**, and Mosaic treats the whole
  type as unknown and offers a *"Save Binary File To Local Disk"* dialog
  instead. So `http://search.retronet/dir` does **not** render in Mosaic, and
  the browser's home page is deliberately set to a corpus site
  (`http://spacejam.com/`), not the portal. Making the portal reachable from
  this station means dropping the `charset` parameter for era clients — a
  gateway-side change, out of scope here.
- **Do not use `-install`.** A private colormap does fix the false colours you
  get on an 8-bit Artist framebuffer with HP VUE holding most of the palette,
  but it makes the *whole capture* come out wrong (the framebuffer grab sees
  the default map). Shipped without it: images are slightly blue-shifted but
  the desktop and the page are correct.

### Getting it onto the guest

The guest can reach only the gateway CT, and at delivery time it had no
configured address at all, so the blob went in **offline, through the CD drive
the station already has**: a small ISO built with `genisoimage`, swapped into
the existing `scsi0-cd2` with a QMP `change`. That matters — the **device set is
never altered**, which is what `loadvm` requires. The original `disc1.iso` is
put back and the CD unmounted before the golden is captured.

Two traps: HP-UX 10.20's `cdfs` **ignores Rock Ridge**, so the CD presents
ISO 9660 8.3 names with a `;1` version suffix (`NAV479.TGZ;1`) — scripts must
glob, not hard-code; and QMP `change` must name **`scsi0-cd2`** explicitly,
because the B160L also exposes an empty `floppy0` and matching on "removable"
alone lands the swap on the floppy.

### Making it reachable from the VUE desktop

**What ships: a `Mosaic` icon in the File Manager window that is already open on
`/` in the golden.** Double-click it, confirm VUE's *Action: Execute* dialog with
**OK**, and the browser opens on a corpus page. `/Mosaic` is a two-line
executable —

```
nohup /usr/bin/mosaic >/dev/null 2>&1 &
```

— and the `nohup … &` matters: VUE's Execute action runs the file **inside a
terminal window it owns**, so a script that `exec`s the browser makes the
browser *be* that terminal's process and closing the terminal kills it.
Backgrounding lets the Execute terminal exit immediately and leaves Mosaic
running on its own. The same file is also dropped in the **Communication
toolbox** (`/etc/vue/config/types/tools/Communication/Mosaic`), so it shows up
under front panel ▸ Toolboxes as well.

**The front panel itself is deliberately left pristine, and here is why.**
HP VUE 3.0 builds the front panel's **top row inside `vuewm`** — there is no
config file for it. The supported extension point is the `fp.*` drop-ins under
`/etc/vue/config/panels/`, each defining the **subpanel** that hangs off one
built-in control. Two attempts were made and both are recorded here so nobody
repeats them:

1. A `CONTROL` added to **`fp.tool`** (`BOX ToolsSubpanel`) parses fine and the
   desktop comes up normally — but on this configuration **`ToolsSubpanel` is
   attached to nothing**. Only three top-row controls have subpanel arrows
   (Help, Printer, **Toolboxes**), so the entry is unreachable.
2. The same `CONTROL` added to **`fp.toolbox`** (`BOX ToolboxesSubpanel`), which
   *is* reachable, **wedges the session**: after login the backdrop and cursor
   appear and nothing else ever does, with QEMU pegged at ~96 % — `vuewm`
   spinning. It does not recover. Recovery is a QMP `system_reset`, an `fsck`
   pass, and restoring `fp.toolbox` from `fp.toolbox.prern` **at the bcheckrc
   single-user prompt** (`/etc/vue` is on the root filesystem, so it is
   reachable there; note `/sbin/cp` does **not** exist in single-user — use
   `cat a > b`). The spin only starts when someone logs in, so a machine left
   at the greeter stays usable over the serial console.

Both `fp.tool` and `fp.toolbox` are back to HP's originals (their pristine
copies are kept beside them as `*.prern`). A VUE **action** is defined in
`/etc/vue/config/types/mosaic.vf`, but note that VUE is **not** matching it:
the icon renders as the generic "executable" bolt and invoking it goes through
VUE's built-in **Execute** action, which is where the extra OK click comes from.
Getting VUE to bind the action properly — and with it a one-click,
no-dialog launch — is the one piece of desktop polish left open.

## The serial console — how this station is driven at all

`labctl ls` says *"No exec channel yet"*, and it is still true over the network.
But the bring-up needed a real shell, and driving a Motif desktop by
screenshot-and-sendkey is too slow to do this much work. QEMU already exposes
the guest's second built-in RS-232C port on `serial.sock` in the station dir, so
a getty was added:

```
s1:234:respawn:/usr/sbin/getty -h tty1p0 9600
```

**`tty1p0`, not `tty0p0`** — `ioscan -fnC tty` shows two `asio0` ports
(`8/0/63` → `tty0p0`, `8/16/4` → `tty1p0`) and QEMU's `-serial` is the second.
Root has no password and `/etc/profile` asks for `TERM` (answer `dumb`).

Two things to know if you script against it:

- **the line editor mangles long command lines** (bells and backspaces once past
  roughly 70 characters), so keep commands short or put them in a file;
- the QEMU serial socket **serves one client at a time** — a stale client makes
  the line look dead. Connect momentarily, never hold it. Kill leftovers by
  resolving `/proc/<pid>/exe`, never with `pkill -f` (which matches your own
  `ssh lab` command line).

This getty is a bring-up tool that happens to be a real exec channel in waiting:
wiring `labctl exec` to it is a small, separate piece of work.

## Everything is slow — do not mistake it for a hang

PA-RISC has no acceleration path, so the station is **TCG only** and burns one
host core whenever the guest runs. A cold boot to the VUE greeter is on the
order of **20–30 minutes**; `fsck` of five logical volumes, the `rc` sequence
and the X/VUE startup each take minutes. Netscape's own startup is minutes of
100 % CPU before it maps its first window.

Two failure modes look identical to a hang and are not:

- **idle auto-pause.** `SH_IDLE_PAUSE_SECS=60`: with no streamhost visitor the
  vCPU freezes and unattended work stops dead. Hold the guest awake for the
  duration with `scripts/lib/guest_wake.py`'s `hold_lease()`, which the daemon
  honours like a live visitor; `labctl` and `scripts/dev/qmp-type.py` take that
  lease on their own. See [`../INPUT-DEBUGGING.md`](../INPUT-DEBUGGING.md).
- **`auto_parms` only runs from `/sbin/rc`.** Run by hand it refuses with
  *"may only execute from /sbin/rc during the initial transition from run level
  'S'"* — network changes need a real reboot to be exercised the way the golden
  will.

## Operating it

```bash
ssh lab 'bash /data/vms/streamhost/stations/hpuxvue/rn-tapnet.sh show'  # tap + guard chain
ssh lab 'bridge fdb show dev hpuxrn0'                                   # guest MAC on the bridge
ssh lab 'labctl reset hpuxvue'                                          # loadvm golden
ssh lab 'labctl shot hpuxvue /tmp/x.png'                                # the only proof that counts
```
