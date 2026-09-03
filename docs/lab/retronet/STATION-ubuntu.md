# ubuntu on the retronet — web + ICQ, in one bake

> **STATUS: PROVEN on a bake clone, 2026-09-03 (branch `ubuntu-rn`).** Ubuntu
> 4.10 Warty Warthog joins both retronet planes at once: **Firefox 0.9** renders
> the corpus seamlessly and **Gaim 1.0.0** signs in to the OSCAR gateway as UIN
> **18300** with the server-side SSI roster showing **HiveBot by name**. The
> station was air-gapped by design until now (`-nodefaults`, zero NICs); this
> adds **exactly one** NIC and re-bakes the golden, because the device set and
> the vmstate are one combination.
>
> It went in on the first attempt with **no client-UI driving at all**: Gaim
> 1.0's config is XML, so the whole account — protocol, UIN, password, server,
> port, auto-login — was written as `~/.gaim/accounts.xml` and Gaim came up
> already signed in with its roster downloaded. That is the cheapest ICQ
> onboarding any station has had, and it is the recipe for every other
> Gaim 1.x/GTK-era Linux station in the fleet.

## Allocation

| Thing | Value |
|---|---|
| Address | **10.99.0.30/24**, **DHCP** — `retronet-dhcp` reservation, proven (`DHCPACK from 10.99.0.2 … bound to 10.99.0.30`) |
| MAC | retronet scheme `52:4e:<last octet>` → `…4e:1e`. Real value in gitignored `registry/local.env` `RN_UBUNTU_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:1e` and reads the one line at boot |
| Link | persistent tap **`ubunturn0`** enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/ubuntu/rn-tapnet.sh up`, called from the launcher on every start |
| Guard chain | **`UBUNTURN-IN`**, scoped to both the guest IP and the guest MAC |
| DNS / router | DNS `10.99.0.2` from the lease; **no router option**, so the guest has no default route (containment Lock 1) — confirmed in-guest: `route -n` shows only `10.99.0.0/24 dev eth0` |
| ICQ | UIN **18300**, password in `registry/local.env` `RETRONET_ICQ_UBUNTU_PASS`; server `10.99.0.2:5190` |
| Joined | 2026-09-03 |

## The NIC — the only device-set change

```
-netdev tap,id=n0,ifname=ubunturn0,script=no,downscript=no \
  -device rtl8139,netdev=n0,mac="$RN_UBUNTU_MAC"
```

**`rtl8139`**, the fleet's proven QEMU-era model (beos runs the same). Warty's
2.6.8 kernel loads `8139too` from the live CD with no prompting and `dhclient`
is already running on `eth0` by the time the desktop paints — the first boot
with the NIC attached came up on a lease without a single keystroke. Everything
else in the launcher is byte-identical to the pre-retronet device set:
`acpi=off`, **no audio device** (AC97 with ACPI on hangs the 2.6.8 live boot at
the usplash bar), `-vga std`, `-usb -device usb-tablet`, `-display dbus,p2p=on`.

`rn-tapnet.sh` is the beos/win98se pattern: a persistent tap plus a fail-closed
`UBUNTURN-IN` chain hooked into `INPUT` twice — once on the guest's source IP,
once on its source MAC, because an IP-scoped chain stops containing a guest the
moment it lands on a pool address instead of its reservation (beos demonstrated
exactly that on 2026-08-23). The launcher runs it `up` before QEMU under
`set -e`, so if containment cannot be *read back out of the kernel*, QEMU never
starts.

**The reservation was in `registry/local.env` but not yet rendered into the CT.**
The first boot leased a pool address (`10.99.0.100`). `install-dhcp.sh --apply`
re-renders `/etc/retronet/dhcp.env` from the ledger and restarts
`retronet-dhcp`; `dhclient -r eth0 && dhclient eth0` in the guest then bound
`10.99.0.30`. Reserving in the ledger is not the same as installing the ledger —
check `pct exec 951 -- grep <mac> /etc/retronet/dhcp.env` before blaming the
guest.

## The web plane — seamless, no proxy

Firefox 0.9 speaks HTTP/1.1 and sends `Host:`, so it uses the **`:80` origin
door**, not the `:3128` proxy: DHCP hands it DNS `10.99.0.2`, every name
resolves to the gateway, and the gateway serves the corpus by `Host`. **Nothing
is configured in the browser** — no proxy, no hosts file, no bookmarks.

Proven: `http://search.retronet/` renders the AltaVista-styled search page
(status bar *Done*), and `http://freshmeat.net/` renders a real mirrored corpus
site. Both were typed as plain URLs.

Firefox is reachable from the **globe icon on the top GNOME panel**, which is
where a visitor will find it — that icon is the discoverability, and it is why
the golden scene leaves the browser closed rather than covering the desktop with
it at 640x480.

## The ICQ plane — Gaim 1.0.0, configured by file

Warty ships **Gaim 1.0.0** with `/usr/lib/gaim/liboscar.so`, whose protocol id
is **`prpl-oscar`** — one plugin for AIM *and* ICQ, which picks ICQ mode from an
all-numeric screen name. So the account is just:

```xml
<?xml version='1.0' encoding='UTF-8' ?>

<account version='1.0'>
	<account>
		<protocol>prpl-oscar</protocol>
		<name>18300</name>
		<password>…RETRONET_ICQ_UBUNTU_PASS…</password>
		<alias>ubuntu</alias>
		<settings>
			<setting name='server' type='string'>10.99.0.2</setting>
			<setting name='port' type='int'>5190</setting>
		</settings>
		<settings ui='gtk-gaim'>
			<setting name='auto-login' type='bool'>1</setting>
		</settings>
	</account>
</account>
```

written to `~/.gaim/accounts.xml` **before Gaim's first run** (the live session
has no `~/.gaim` at all until then, so there is nothing to merge with). `gaim`
then starts, auto-logs-in, and paints its **Buddy List** — never a Login window.

**The roster needs no client-side work.** Gaim 1.0's oscar prpl requests the
server-side SSI/feedbag list on login (gaim 0.64 already did; only 0.59.9 needed
tru64's `gaim-0.59.9-icq-ssi.patch`), so the seeder's server-side write is the
whole contact story: `roster.json` gained one row
(`ubuntu / 18300 / nick "ubuntu" / client "gaim1.0" / onboarded true`),
`seed_contacts.py ssi --apply` cross-listed the fleet, and the buddy list came
down as **`Orphans (5/13)`** with **HiveBot**, beos, nt4, win2000 and win98se
online, each by name. No golden recapture was needed *for the roster* — the
recapture here is for the NIC.

### Delivering the config into an exec-less guest

`ubuntu` has **no exec channel** (`exec_kind: none`) and the guard chain blocks
every NEW flow toward labhost, so there is no way to push a file in from the
host. But the guest *can* reach the gateway CT, so the config script was served
from there and fetched with one short typed line:

```bash
# on labhost
pct push 951 setup.sh /tmp/rn/setup.sh
pct exec 951 -- systemd-run --unit=ubuntu-rn-dl python3 -m http.server 8099 --directory /tmp/rn
# in the guest (Alt+F2 -> gnome-terminal)
wget -qO- http://10.99.0.2:8099/setup.sh | sh
```

Forty characters of QMP typing instead of eight hundred. Tear the unit and
`/tmp/rn` down afterwards. This is the general answer for any exec-less station
on the plane, and it is faster than driving a GUI even when a GUI exists.

## The golden

Baked on `/data/vms/sandbox/ubuntu-rn/bake/` from a **cold** boot (a copy of
`ubuntu.qcow2` with the previous `golden` snapshot deleted, so the launcher boots
the live CD fresh and the new MAC lands in the device vmstate — `loadvm` would
have restored the old, NIC-less machine).

- Cold boot to the GNOME 2.8 desktop **with the NIC attached: 58.9 s**
  (`fb-wait.py --settle 15`), faster than the 89.5 s the air-gapped golden took.
- Idle prep, in the same script as the account: `xset s off`, **`xset m 1 1`**
  (load-bearing — `SH_CURSOR_SCALE=0.625` only cancels the mousedev 1024x768
  rescale if X acceleration is off), `gnome-screensaver-command -d`.
- Scene: Gaim Buddy List open on the left with HiveBot listed, Firefox closed
  (globe on the panel), terminal closed (`disown -a; exit`, so Gaim survives the
  shell that started it), no dialogs.
- `savevm golden` via the HMP socket: **VM_SIZE = 307 MiB,
  VM_CLOCK = 00:11:25.966**.

### Restore proof, and the network across it

Killed by pidfile (`/proc/<pid>/exe` checked first), relaunched with
`-loadvm golden -S`, QMP `cont`: `fb-wait.py --settle 4` landed in **4.1 s** on
the identical scene.

- **ICQ survived.** Ctrl+M → `10000` → a message, and **HiveBot replied in the
  frame** — *"Hey there! Still running Ubuntu 4.10? That's like finding a dial-up
  modem in a fiber-optic cafe—old school, but somehow still works :)"*. No nudge,
  no re-login prompt, no reconnect ceremony: the restored session simply worked.
- **The web survived.** `http://freshmeat.net/` — a *different* corpus host from
  the one in the pre-bake proof — rendered after the restore.

Frames (kept):

| What | Path |
|---|---|
| Gaim buddy list, HiveBot by name | `/data/vms/sandbox/ubuntu-rn/shots/gaim-buddylist-hivebot.png` |
| Firefox on `search.retronet` | `/data/vms/sandbox/ubuntu-rn/shots/firefox-search-retronet.png` |
| The golden scene as baked | `/data/vms/sandbox/ubuntu-rn/shots/scene-pre-savevm.png` |
| Post-`loadvm` restore | `/data/vms/sandbox/ubuntu-rn/shots/restore.png` |
| Post-restore HiveBot reply | `/data/vms/sandbox/ubuntu-rn/shots/im.png` |
| Post-restore second page | `/data/vms/sandbox/ubuntu-rn/shots/ff2-postrestore.png` |
| Cold boot to desktop | `/data/vms/sandbox/ubuntu-rn/bake/desktop.png` |

## Rollback

The pre-retronet golden is kept **byte-for-byte** at
`/data/gallery-guests/Ubuntu/ubuntu.qcow2.bak-pre-rn` (it is the air-gapped
`golden`, VM_SIZE 255 MiB / VM_CLOCK 0000:05:55.667). Full rollback:

```bash
ssh lab 'systemctl stop streamhost@ubuntu'
ssh lab 'cp /data/gallery-guests/Ubuntu/ubuntu.qcow2.bak-pre-rn /data/gallery-guests/Ubuntu/ubuntu.qcow2'
git revert <this commit>          # launcher (drops the NIC + tap guard), registry, fixture
ssh lab 'bash /data/vms/streamhost/stations/ubuntu/rn-tapnet.sh down'   # tap + UBUNTURN-IN
ssh lab 'systemctl start streamhost@ubuntu'
```

Launcher, ISO and `ubuntu.qcow2` are **one combination** — reverting the disk
without reverting the launcher leaves a golden whose vmstate has an rtl8139 the
device set no longer provides.

## Operating it

```bash
ssh lab 'bash /data/vms/streamhost/stations/ubuntu/rn-tapnet.sh show'   # tap + guard chain
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 18300'     # server-side SSI roster
ssh lab 'pct exec 951 -- grep -o "52:54:00:52:4e:1e=[0-9.]*" /etc/retronet/dhcp.env'
ssh lab 'bridge fdb show dev ubunturn0'                                  # the guest MAC on the bridge
```

## Unproven / next

- The station has **not** been restarted onto this golden; the coordinator lands
  the branch and restarts. Everything above is proven on the bake clone with the
  production device set, not through `streamhost@ubuntu`.
- The `:3128` proxy door was not exercised — this station does not need it
  (Firefox 0.9 sends `Host:`), and the seamless route is the one that ships.
- `museum.periodBrowser` stays **Firefox 0.9.3**, which is what Warty ships; the
  frame proves *Mozilla Firefox 0.9* rendering, the point release was not read
  off the About box.
- Pointer is unchanged: still the daemon-side `SH_CURSOR_SCALE=0.625`
  correction, and `xset m 1 1` is preserved inside the new golden.
