# winxp on the retronet web — the bridge as-built

**Status: LIVE.** `winxp` reaches the retronet web over a **real bridged NIC** on
`vmbr-rn`, on **DHCP** with a **unique MAC**, and browses the period corpus in
**Internet Explorer 8** with **no proxy configured**. Open the station and the
golden scene is already IE, maximised, rendering
`http://home.microsoft.com/` — "Microsoft Internet Start", the canonical era
start page — served from the museum's corpus. An **Internet Explorer** shortcut
sits on the desktop behind it, so a visitor who closes the browser can get it
back with one obvious double-click.

This station follows the win98se pathfinder ([`ICQ-STATION.md`](ICQ-STATION.md))
and its NT-family sibling ([`ICQ-STATION-win2000.md`](ICQ-STATION-win2000.md));
read those for the shared design. This doc records what is **specific to winxp**.

**Messaging arrived on 2026-08-23** and is documented separately in
[`ICQ-STATION-winxp.md`](ICQ-STATION-winxp.md): ICQ 2001b signs UIN `51000` in to
the OSCAR gateway over this same link. That wave changed **nothing** described
here — no NIC, MAC, DHCP reservation, guard chain or proxy setting — so this doc
remains the authority on the bridge itself.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device rtl8139,netdev=n0,mac="$RN_WINXP_MAC"` (**unchanged device**; a UNIQUE mac — see below), backend `-netdev tap,id=n0,ifname=winxprn0,script=no,downscript=no` |
| **MAC** | **unique, fleet scheme `52:54:00:52:4e:<last-IP-octet>`** (`52:4e`=RN, `.18`→`…12`). Real value in gitignored `registry/local.env` `RN_WINXP_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:12` and reads that one line at boot. **The MAC lives in the golden vmstate, so it was baked by a COLD boot** |
| Tap | `winxprn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/winxp/rn-tapnet.sh up` from the launcher on EVERY start (chain `WINXPRN-IN`, scoped to the guest IP) |
| Guest IP | **DHCP** — `retronet-dhcp` reserves `RN_WINXP_MAC → 10.99.0.18/24`, DNS `10.99.0.2`, **and NO default gateway** (containment stays Lock 1: no default route) |
| Seamless web | DNS = `10.99.0.2` (via DHCP) + **no IE proxy** → type any URL: the name resolves to the gateway and its `:80` origin serves the corpus. `ProxyEnable=0`, no `ProxyServer` |
| Browser | **Internet Explorer 8** (`8.0.6001.18702`). Home page `http://home.microsoft.com/`; first-run wizard permanently suppressed |
| Desktop icon | `%USERPROFILE%\Desktop\Internet Explorer.lnk`, a copy of the stock Start-menu shortcut |
| Exec | **none.** `labctl sh winxp` is blind; drive the GUI with the framebuffer + `labctl key`/`type` + the station's own `drive.py` (absolute pointer) |
| Launcher | `streamhost/stations/winxp/qemu-streamhost.sh` (KVM, `-cpu host`, `-machine pc-i440fx-11.0`, std-VGA 1920×1200, AC97 audio, usb-tablet → absolute pointer) |

## The browser was IE8, not IE6

The registry claimed `periodBrowser: "Internet Explorer 6"`. It is **not**: the
image carries **IE 8.0.6001.18702**, read straight out of the guest
(`reg query "HKLM\SOFTWARE\Microsoft\Internet Explorer" /v Version`). The
registry and [`docs/guests/winxp.md`](../../guests/winxp.md) now say IE8.

`museum.eraSoftware` still lists "IE6" — that list describes **Windows XP as it
shipped in 2001**, which is the era claim and is correct. `periodBrowser`
describes **what a visitor actually drives on this station**, which is IE8.

### What IE needed

Three registry values, all under the autologon `Administrator` hive, plus one
machine-wide:

```
HKCU\...\Internet Settings          ProxyEnable = 0        (seamless web; no proxy)
HKCU\...\Internet Explorer\Main     Start Page  = http://home.microsoft.com/
HKCU\...\Internet Explorer\Main     RunOnceComplete = 1    (kill the first-run wizard)
HKCU\...\Internet Explorer\Main     RunOnceHasShown = 1
HKLM\...\Internet Explorer\Main     DisableFirstRunCustomize = 1
```

The stock home page was `http://go.microsoft.com/fwlink/?LinkId=69157`, which
resolves to the gateway like everything else and lands on the period *"Not in
the Museum's Internet"* 404 — authentic, but a poor first impression.
`home.microsoft.com` is **in the corpus** (a 30 KB real capture) and is the era's
own IE start page, so it is the right first thing a visitor sees.

**The first-run wizard must be suppressed, not dismissed.** Its "Ask me later"
button opens a second tab and the wizard returns on the next launch — which,
on a `loadvm` station, means it returns forever. The three RunOnce values above
retire it; proven by closing IE completely and relaunching from the desktop icon
with no wizard.

## Windows Firewall — left ON, one hole

XP's firewall is **inbound-only and stateful**, so the guest's own outbound ICMP,
DNS and HTTP were never blocked; `ping 10.99.0.2` worked before any firewall
change. The only thing it blocked was **inbound** echo, so nothing on the
retronet could ping the station.

The firewall is therefore **left enabled on every profile** and exactly one
setting was changed:

```
netsh firewall set icmpsetting 8 enable     # allow inbound echo request
```

**Why not just turn it off.** The guest shares L2 with real sibling guests on
`vmbr-rn`. XP's firewall is the layer that keeps an unsolicited SMB/RPC/DCOM
connection from a sibling out of this guest; it is not the layer that provides
containment toward labhost or the internet (that is topology + no default route
+ the `WINXPRN-IN` chain). Disabling it would trade a real protection for
nothing — inbound echo is all the retronet actually wanted. Opening **no TCP
port** keeps the guest's listeners unreachable from the bridge.

That rule survived the ICQ wave intact: ICQ's first-run *Windows Security Alert*
was answered **Keep Blocking**, so the client still has no firewall exception and
no inbound hole — its OSCAR link is outbound-only. See
[`ICQ-STATION-winxp.md`](ICQ-STATION-winxp.md).

## Containment — the guest reaches the retronet and nothing else

Layered locks (no default route / `retronet-fw` / the per-station `WINXPRN-IN`
guard chain, scoped to the guest's source IP and inserted above `RETRONET-IN`).
On DHCP the reservation withholds option 3 (router), so *the addressing itself*
keeps the no-WAN posture. Proven from inside the guest on the new-MAC lease:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (the `:80` corpus origin) | **Reply**, TTL 64, 0 % loss | intra-bridge L2 (the point) |
| `cnn.com`, `home.microsoft.com` → `10.99.0.2` | **Resolves + renders** | DNS hijack (retronet-dns), no proxy |
| labhost bridge `10.99.0.1` | **Request timed out** | the `WINXPRN-IN` guard chain |
| internet `1.1.1.1` (by IP) | **Destination host unreachable** | no default route (Lock 1) |

The reverse direction is deliberately asymmetric: labhost and the CT **can**
reach the guest (both ping `10.99.0.18`, TTL 128), because the guard chain
filters only what the guest *initiates* toward labhost. That is what a future
labhost-initiated exec channel would ride.

`retronet-fw` runs with `bridge-nf-call-iptables=0`, so guest↔CT traffic is pure
L2 and never touches these chains — the retronet reaching the retronet.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (ID 1, ~234 MiB, 2026-08-23
  12:48) in `/data/vms/streamhost/stations/winxp/winxp-golden.qcow2`.
  **Tap-native + DHCP + the unique MAC**, captured with **IE8 maximised on
  `home.microsoft.com`** and the desktop shortcut in place. `labctl reset winxp`
  = `loadvm golden`.
- **Full-disk byte-copy backup of the pre-retronet golden** (QEMU stopped,
  SHA256-verified):
  `/data/vms/streamhost/stations/winxp/golden-backup-prern-20260823/`
  (`winxp-golden.qcow2` `110fad0d…50a5`, `SHA256SUMS` in the dir). This holds the
  slirp + default-MAC + **Notepad** golden and is the rollback for the whole
  swap.

**Full rollback, one command block:**

```bash
ssh lab 'systemctl stop streamhost@winxp
  D=/data/vms/streamhost/stations/winxp
  cp -a $D/golden-backup-prern-20260823/winxp-golden.qcow2 $D/winxp-golden.qcow2
  git -C /data/kernel-hive checkout <pre-swap-rev> -- streamhost/stations/winxp/qemu-streamhost.sh
  bash $D/rn-tapnet.sh down
  systemctl start streamhost@winxp'
```

(The DHCP reservation may be left in place — an unused reservation leases
nothing. `rn-tapnet.sh down` removes the tap and the guard chain.)

## Gotchas that are winxp-specific

- **The MAC is baked by a COLD boot, not `loadvm`.** To change it: back the
  golden up (byte copy), ensure the DHCP reservation for the NEW mac is applied,
  revert the disk to golden (`qemu-img snapshot -a golden`), **delete** the
  `golden` snapshot so the launcher cold-boots (`qemu-img snapshot -d golden`),
  boot with the new `mac=`, do the in-guest work, recapture. Verify **in the
  bridge FDB** (`bridge fdb show dev winxprn0`) **and** the DHCP lease
  (`journalctl -u retronet-dhcp` in CT 951 → `…4e:12 → ACK 10.99.0.18`).
- **A new MAC makes XP enumerate a NEW adapter.** The guest now shows
  *Local Area Connection 2* / "Realtek RTL8139 Family PCI Fast Ethernet NIC #2".
  This is expected and harmless — the old instance is a ghost with no config,
  and the new one takes DHCP defaults, which is exactly what is wanted.
- **There is no exec channel.** Everything in-guest was driven through the
  framebuffer: `labctl key winxp <qcode> [qcode…]` (space-separated qcodes make
  ONE chord — `meta_l r` for Win+R; a hyphenated `meta_l-r` is silently accepted
  and does nothing), `labctl type`, and the station's own
  `drive.py qmp.sock mouse|click|kc|savevm` for the absolute pointer.
  `mode con cols=100 lines=45` makes the console readable in a screenshot.
- **`drive.py shot` writes PPM, not PNG.** Use `labctl shot` when you want an
  image you can actually open.
- **Restarting Explorer steals keyboard focus** and every subsequent
  `labctl type` silently goes nowhere — the frame simply stops changing. If two
  consecutive shots are byte-identical after you typed something, you have lost
  focus, not hung the guest: click into the window with `drive.py click` and
  carry on.
- **Absolute-pointer clicks: warm up after a resume.** The usb-tablet drops the
  first absolute position right after a `cont`/`loadvm`, landing a click at
  (0,0). Send a throwaway `mouse` before the real `click`; the second one lands.
  The same wake also leaves the keyboard unfocused until something is clicked.
- **XP SP2+ has no "show Internet Explorer on the desktop" option**, and the
  `Desktop\NameSpace\{871C5380-…}` key does not bring the icon back on this
  build. A plain **copy of the stock `Internet Explorer.lnk` onto the Desktop**
  is what works, and it is also more honest for an exhibit: it is a real
  shortcut a visitor can move, rename or delete.

## Operating it

```bash
ssh lab 'bash /data/vms/streamhost/stations/winxp/rn-tapnet.sh show'   # tap + guard chain
ssh lab 'bridge fdb show dev winxprn0'                                 # the guest's MAC on the bridge
ssh lab 'pct exec 951 -- ping -c2 10.99.0.18'                          # is the guest up on the retronet?
ssh lab 'pct exec 951 -- journalctl -u retronet-dhcp | tail'           # the lease
ssh lab 'labctl reset winxp'                                           # loadvm golden -> IE on the corpus
ssh lab 'labctl shot winxp /tmp/x.png'                                 # the only proof that counts
```

Acceptance shots for the swap live on the box at
`/data/vms/streamhost/stations/winxp/rn-acceptance-20260823/`.
