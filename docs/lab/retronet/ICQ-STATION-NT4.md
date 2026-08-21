# nt4 ICQ station — the bridge as-built (ICQ 2001b / SSI)

**Status: LIVE.** `nt4` (Windows NT 4.0 Workstation SP6a) runs **ICQ 2001b
(build 3659)** against the retronet OSCAR gateway over a **real bridged NIC** on
`vmbr-rn`, on **DHCP** with a **unique MAC**. Open the station and the persona
(UIN `40000`) **self-reconnects** and the greeter bot (UIN `10000` = HiveBot)
messages it within ~30 s. This is the [win2000
pathfinder](ICQ-STATION-win2000.md) replicated on Windows NT 4.0 — read that (and
the [win98se original](ICQ-STATION.md)) for the shared design. This doc records
what is **different** on NT4, and there is a lot: NT4 predates every tool the
other two lean on (`netsh`, `taskkill`, a CLI HTTP client), and its DHCP switch
needs a reboot.

## Why 2001b — the SSI contact list, synced server-side

ICQ 2000b keeps its contact list client-local; **ICQ 2001b is the first ICQ with
a server-stored (SSI/feedbag) roster** — the client signs in and downloads its
whole roster from the server, no client-UI seeding, no golden recapture to add a
contact. The server side is seeded by the SSI fabric
(`scripts/retronet/icq/seed_contacts.py ssi`, roster
`scripts/retronet/icq/roster.json`).

**Proven on nt4:** signing UIN `40000` in pulled the full roster down and
rendered it **by name** with no manual adds — **HiveBot, solaris, tru64, win2000,
win98se**. The client's own 2000b→2001b migration *uploaded* its local list
(just HiveBot) too, but that **merges** with the fabric-seeded server roster (it
does not wipe it): `rn-tool.py buddies 40000` = the same 5 before and after.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device pcnet,netdev=n0,mac="$RN_NT4_MAC"` (**unchanged device**; a UNIQUE mac — below), backend `-netdev tap,id=n0,ifname=nt4rn0,script=no,downscript=no` |
| **MAC** | **unique, fleet scheme `52:54:00:52:4e:0c`** (`52:4e`=RN, `.12`→`…0c`). Real value in gitignored `registry/local.env` `RN_NT4_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:0c` and reads the one line at boot. Baked in the golden vmstate (this one was already baked — verified in-guest + FDB, no re-bake needed) |
| Tap | `nt4rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/nt4/rn-tapnet.sh up` from the launcher on every start (chain `NT4RN-IN`) |
| Guest IP | **DHCP** — TCP/IP set to obtain IP *and* DNS automatically. `retronet-dhcp` reserves `RN_NT4_MAC → 10.99.0.12/24`, DNS `10.99.0.2`, **and NO default gateway** (containment stays Lock 1: no default route) |
| Seamless web | DNS = `10.99.0.2` (via DHCP) + **no IE proxy** → type any URL: the name resolves to the gateway and its `:80` origin serves the corpus. Proven: IE renders `http://spacejam.com/` by URL with no proxy |
| OSCAR server | gateway CT `10.99.0.2:5190`. ICQ's **Server → Host** is the literal `10.99.0.2` port `5190` |
| Persona / bot | UIN `40000` (nt4) / UIN `10000` (HiveBot); passwords in `registry/local.env` `RETRONET_ICQ_NT4_PASS` / `_BOT_PASS` |
| ICQ client | **ICQ 2001b build 3659** (`C:\Program Files\ICQ\Icq.exe`). Server **Host=`10.99.0.2` Port=`5190`**, **Keep connection alive = ON**, Save password = ON, Launch ICQ on startup = ON |
| Exec | `labctl exec nt4 "<cmd>"` → guest agent `C:\WARPNET.EXE` at **`10.99.0.12:7788` directly over the bridge** (`exec_kind warpd_e`); no hostfwd |
| RAM | **256 MB** (128 MB thrashed with NT4 + ICQ + a spawned exec `cmd.exe`) |
| Launcher | **verbatim** `streamhost/stations/nt4/qemu-streamhost.sh`; pinned `/opt/qemu-cirrusfix2` (isa-cirrus-vga vmstate patch), `-cpu pentium3 -smp 1 -machine …,hpet=off,vmport=on` |

## The reconnect mechanism — 2001b SELF-HEALS (no nudge)

**This retires the per-station nudge for nt4.** ICQ 2000b sits on a half-open
zombie socket after a wake and never reconnects, so it needed `nt4-icq-nudge` (a
labhost timer spoofing the gateway's RST). **ICQ 2001b with `Keep connection
alive` ON does not:** on a `loadvm golden` wake the restored BOS socket is stale
(the gateway timed it out while the guest was frozen), the keepalive probe aborts
the dead 4-tuple, and **2001b reconnects on a fresh port on its own — silently,
using the saved password — within ~1–2 s**, then HiveBot greets ~30 s later.

- **`Keep connection alive` is load-bearing.** It ships **OFF**
  (Preferences → Connections → **Server** tab); with it off the wake leaves 2001b
  passive and its reconnect re-prompts *Password incorrect*.
- **`nt4-icq-nudge.timer` is DISABLED on the box** (superseded by self-heal). The
  files stay in the repo only as the fleet's shared 2000b healer until win98se
  also moves to 2001b.

**Measured acceptance (production `labctl reset nt4` path, 2026-08-21):** reset →
the guest idle-paused (~45 s) and the gateway dropped `40000` (~180 s) → the
visitor's wake (`cont`) → **`40000` reconnected in ~2 s, silent, nudge OFF**, the
SSI roster stayed intact, and HiveBot greeted (*"hey, did you just sign on with
the NT 4? very serious machine :)"*).

## Containment — identical to win98se, proven the same way

Layered locks (no default route / `retronet-fw` / the per-station `NT4RN-IN`
guard chain). On DHCP the reservation withholds option 3 (router), so *the
addressing itself* keeps the no-WAN posture. Proven from inside the guest:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (OSCAR + `:80` origin) | **Reply / serves** | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` | **timed out** | the `NT4RN-IN` guard chain |
| internet `1.1.1.1` (by IP) | **Destination host unreachable** | no default route (Lock 1) |

`route print` shows no `0.0.0.0` default route on the DHCP lease.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (~90 MiB VM state, 2026-08-21
  11:31) in the tile-local `/data/vms/streamhost/stations/nt4/nt4-golden.qcow2`.
  **Tap-native + DHCP + MAC `52:54:00:52:4e:0c`**, 256 MB, captured with **ICQ
  2001b connected** (UIN `40000`, Server `10.99.0.2:5190`, Keep-alive ON) + the
  full SSI roster + a clean 1024×768 frame. `labctl reset nt4` = `loadvm golden`.
- **Full-disk byte-copy backup of the pre-swap ICQ-2000b golden** (QEMU stopped,
  SHA256 `f5594e4e…5319`): `/data/gallery-guests/Nt4/golden-backup-preswap2001b-20260821/nt4-golden.qcow2`
  (`SHA256SUMS` in the dir). This is the rollback for the whole 2001b/DHCP swap —
  it holds the ICQ 2000b + static-IP golden.
- Older backup: `golden-backup-retronet-nt4-20260820/` (pre-retronet slirp
  golden, disk recovery only — not `loadvm`-able on the tap).

Full rollback = `systemctl stop streamhost@nt4`, copy the `preswap2001b` backup
qcow2 back, revert the launcher/registry/`local.env` reservation, `labctl gen`,
`systemctl start`.

## Gotchas that are NT4-specific (and the 2000b→2001b + DHCP swap)

- **Shut ICQ 2000b down before installing 2001b.** The installer aborts while
  2000b is running and NT4 has no `taskkill`; close it from its **tray icon →
  Shut Down**, then run the installer. It upgrades in place into
  `C:\Program Files\ICQ`. (The Red Bend unpack phase is slow — ~15 min on this
  VM; watch qcow2 growth + QEMU CPU to tell "slow" from "hung".)
- **Installer delivery is TFTP over the exec channel** — NT4 has no CLI HTTP
  client but ships `TFTP.EXE`. A tiny read-only TFTP server on the gateway CT
  (`10.99.0.2:69`) + `labctl exec nt4 "tftp -i 10.99.0.2 GET ICQ2001b.exe
  C:\ICQ2001b.exe"`. TFTP writes to its file *argument* (not a `>` redirect) and
  exits, so it dodges the WNEXEC-trap that a long-lived GUI child would spring.
  **Launch the installer from the FRAMEBUFFER** (Start ▸ Run), never the exec
  channel. Remove `C:\ICQ2001b.exe` afterward.
- **The migration carries the wrong password.** First 2001b login shows
  *Password incorrect* (User `40000`); re-enter `RETRONET_ICQ_NT4_PASS` with
  **Save password** ON. Because 2001b defaults its Server to `login.icq.com` and
  nt4 has no DNS for it yet, the very first attempt fails *"Can't establish
  connection"* until you set **Server → Host = `10.99.0.2`** — set it, then
  Disconnect→Connect.
- **DHCP is a registry `.reg`, not `netsh` and not the Network applet.** NT4 has
  no `netsh`, and the Network applet's adapter setup rewrites the pcnet
  `BusNumber/SlotNumber` **backwards** (the bug §fixed in the golden). So flip it
  by importing a REGEDIT4 `.reg` (delivered by TFTP, applied `regedit /s`):
  `[…\Services\AMDPCN1\Parameters\Tcpip] "EnableDHCP"=dword:1`, zero `IPAddress`
  + `SubnetMask` (REG_MULTI_SZ `"0.0.0.0"`), empty `DefaultGateway` +
  `DhcpDefaultGateway`. The **DHCP Client service Start is already `2`** (auto);
  the static `NameServer` is already empty, so the lease's `DhcpNameServer`
  (10.99.0.2) is used automatically. **NT4 reads adapter config only at boot — a
  reboot is required** (unlike win2000's live `netsh`).
- **The DHCP reboot force-killed ICQ, which lost the freshly-saved password.**
  NT4's clean shutdown couldn't close ICQ (it re-prompts + goes not-responding →
  *End Task*), and the corrected password is only flushed to the DAT on a **clean
  ICQ exit**, so the next boot re-prompted *Password incorrect*. **Fix: after
  re-entering the password, cleanly Shut Down ICQ (tray → Shut Down) to persist
  it, then relaunch and confirm a truly silent connect** before recapturing.
  (`loadvm golden` reconnects from the in-RAM state either way; the disk persist
  is what keeps a *cold* boot silent.)
- **The guest keyboard is a UK/ISO layout.** Over QMP `send-key`, qcode
  `backslash` types `#` and qcode **`less`** types `\` — matters for typing
  `C:\…` paths during the install (the persona password is alphanumeric, so it is
  layout-safe). `:` and `/` type correctly.
- **No display wedge.** NT4's Cirrus is a kernel-mode driver, not a Win9x VBE
  miniport, so a `cmd.exe` exec leaves the 1024×768 frame clean. The warpnet `V`
  verb (`CDS_RESET`) before `savevm` is belt, not load-bearing.

## Operating it

```bash
ssh lab 'labctl exec nt4 "ver"'                       # exec over the bridge
ssh lab 'labctl exec nt4 "ipconfig /all"'             # DHCP lease 10.99.0.12, DNS 10.99.0.2, no gw, MAC …0c
ssh lab 'bash /data/vms/streamhost/stations/nt4/rn-tapnet.sh show'   # tap + guard chain + FDB
ssh lab 'labctl reset nt4'                            # loadvm golden → 2001b self-reconnects, greets ~30 s
# is the persona online? (server-side)
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
# the server-side SSI roster 2001b syncs on login
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 40000'
```
