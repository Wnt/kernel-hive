# win2000 ICQ station — the bridge as-built (ICQ 2001b / SSI)

**Status: LIVE.** `win2000` runs **ICQ 2001b (build 3659)** against the retronet
OSCAR gateway over a **real bridged NIC** on `vmbr-rn`, on **DHCP** with a
**unique MAC**. Open the station and the persona (UIN `20000`) **self-reconnects**
and the greeter bot (UIN `10000` = HiveBot) messages it within ~30 s — the "kernel
hive feels alive" moment. This is the win98se pathfinder ([`ICQ-STATION.md`](ICQ-STATION.md))
replicated on Windows 2000; read that first for the shared design. This doc records
what is **different** on win2000 — and win2000 is the **pathfinder for the Windows
fleet's ICQ 2000b → 2001b (SSI) upgrade** (fan-out playbook at the end).

## Why 2001b — the SSI contact list, synced server-side

ICQ 2000b keeps its contact list **client-local**: a golden rebuild or `labctl
reset` shows an empty list until a contact seeder re-drives the client's Add-Contact
UI. **ICQ 2001b is the first ICQ generation with a server-stored (SSI/feedbag)
contact list** — the client signs in and **downloads its whole roster from the
server, with no client-UI seeding and no golden recapture**. The seeder that
populates the server side is the SSI fabric (`scripts/retronet/icq/seed_contacts.py
ssi`, roster `scripts/retronet/icq/roster.json`); win2000's server-side roster is
the bot + every other **onboarded** station.

**Proven on win2000:** signing UIN `20000` into the gateway pulled the full roster
down and rendered it **by name** with no manual adds — **HiveBot, solaris, tru64,
nt4, win98se** (the 4 other onboarded stations + HiveBot). The client's own
2000b→2001b migration *uploaded* its local list too, but that **merges** with the
fabric-seeded server roster (HiveBot was already present) — it does not wipe it, so
the full roster survives (`rn-tool.py buddies 20000` = the 5 above, before and after).

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device rtl8139,netdev=n0,mac="$RN_WIN2000_MAC"` (**unchanged device**; a UNIQUE mac — see below), backend `-netdev tap,id=n0,ifname=win2krn0,script=no,downscript=no` |
| **MAC** | **unique, fleet scheme `52:54:00:52:4e:0b`** (`52:4e`=RN, `.11`→`…0b`). Real value in gitignored `registry/local.env` `RN_WIN2000_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:0b` and reads the one line at boot. **The MAC lives in the golden vmstate, so it was baked by a COLD boot** (loadvm uses the baked MAC regardless, but the launcher `mac=` must match it) |
| Tap | `win2krn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/win2000/rn-tapnet.sh up` from the launcher on every start (chain `WIN2KRN-IN`) |
| Guest IP | **DHCP** — TCP/IP set to obtain IP *and* DNS automatically. `retronet-dhcp` reserves `RN_WIN2000_MAC → 10.99.0.11/24`, DNS `10.99.0.2`, **and NO default gateway** (containment stays Lock 1: no default route) |
| Seamless web | DNS = `10.99.0.2` (via DHCP) + **no IE proxy** → type any URL: the name resolves to the gateway and its `:80` origin serves the corpus. Proven: IE renders corpus pages by URL with no proxy |
| OSCAR server | gateway CT `10.99.0.2:5190` (the one `RN` door). ICQ's **Server → Host** is set to the literal `10.99.0.2` port `5190` (deterministic; the DNS hijack of `login.icq.com` also reaches it, but the literal removes the moving part) |
| Persona / bot | UIN `20000` (win2000) / UIN `10000` (HiveBot); passwords in `registry/local.env` `RETRONET_ICQ_WIN2000_PASS` / `_BOT_PASS` |
| ICQ client | **ICQ 2001b build 3659** (`C:\Program Files\ICQ\Icq.exe`). Server **Host=`10.99.0.2` Port=`5190`**, **Keep connection alive = ON**, Save password = ON, Launch ICQ on startup = ON |
| Exec | `labctl exec win2000 "<cmd>"` → guest agent `C:\WARPNET.EXE` at **`10.99.0.11:7788` directly over the bridge** (`exec_kind warpd_e`); no hostfwd |
| Launcher | **verbatim** `streamhost/stations/win2000/qemu-streamhost.sh` (registry `runtime.qemu.mode = verbatim`) |

## The reconnect mechanism — 2001b SELF-HEALS (no nudge)

**This is the big difference from the ICQ 2000b stations (win98se, nt4), and it
retires the per-station nudge for win2000.**

ICQ 2000b does not poll; after a wake it sits on a half-open zombie socket and never
reconnects, so those stations need `*-icq-nudge` (a labhost timer that spoofs the
gateway's RST). **ICQ 2001b with `Keep connection alive` ON does not need it:** on a
`loadvm golden` wake the restored BOS socket is stale (the gateway timed it out while
the guest was frozen), the client's keepalive probe hits the dead 4-tuple, the
socket aborts, and **2001b reconnects on a fresh port on its own — silently, using
the saved password — within ~1–4 s**, then HiveBot greets ~30 s later. This is the
same self-healing climm gives the Unix stations.

- **`Keep connection alive` is load-bearing.** It ships **OFF** by default; with it
  off, the wake leaves 2001b passive and its reconnect attempt re-prompts *Password
  incorrect* and blocks. Set it ON (Preferences → Connections → **Server** tab).
- **Save password must persist.** The 2000b→2001b migration carries the *wrong*
  password (2000b's saved-password bug), so first login shows *Password incorrect*
  — re-enter `RETRONET_ICQ_WIN2000_PASS` with **Save password** ticked, then confirm
  a **silent** in-client Disconnect→Connect before capturing the golden.
- **The `win2000-icq-nudge.{py,service,timer}` files remain in the repo but the
  timer is DISABLED on the box** (superseded by self-heal). It is kept only as the
  fleet's shared 2000b healer until win98se/nt4 also move to 2001b.

**Measured acceptance (via the production `labctl reset` path):** `labctl reset
win2000` restores the golden; on the visitor-after-idle wake (gateway drops the
golden session, guest resumes) **20000 reconnected in ~1 s, silent, nudge OFF**, the
SSI roster stayed intact, and HiveBot greeted (*"hi! nice, the 2000 machine."* /
*"hey, Windows 2000 just came online, that you?"*).

## Containment — identical to win98se, proven the same way

Layered locks (no default route / `retronet-fw` / the per-station `WIN2KRN-IN` guard
chain). On DHCP the reservation withholds option 3 (router), so *the addressing
itself* keeps the no-WAN posture. Proven from inside the guest:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (OSCAR + `:80` origin) | **Reply / serves** | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` (+ gallery `:8443`) | **timed out** | the `WIN2KRN-IN` guard chain |
| internet `1.1.1.1` (by IP) | **Destination host unreachable** | no default route (Lock 1) |

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (~210 MiB, 2026-08-21) in
  `/data/gallery-guests/Win2000/win2k-pro.qcow2`. **Tap-native + DHCP + MAC
  `52:54:00:52:4e:0b`**, captured with **ICQ 2001b connected** (UIN `20000`, Server
  `10.99.0.2:5190`, Keep-alive ON) + the full SSI roster + a clean 1600×1200 frame.
  `labctl reset win2000` = `loadvm golden`.
- **Full-disk byte-copy backup of the pre-swap ICQ-2000b golden** (QEMU stopped,
  SHA256-verified): `/data/gallery-guests/Win2000/golden-backup-predhcp-20260821/win2k-pro.qcow2`
  (`SHA256SUMS` in the dir). This is the rollback for the whole 2001b/DHCP/MAC swap:
  it holds the ICQ 2000b + static-IP + default-MAC golden.
- Older backup: `golden-backup-preswap-20260820/` (pre-bridge slirp golden, disk
  recovery only — not `loadvm`-able on the tap).

Full rollback = `systemctl stop streamhost@win2000`, copy the `predhcp` backup qcow2
back, revert the launcher/registry/`local.env` reservation, `labctl gen`,
`systemctl start`.

## Gotchas that are win2000-specific (and the 2000b→2001b upgrade)

- **The MAC is baked by a COLD boot, not `loadvm`.** A `loadvm golden` restores
  whatever MAC the vmstate carries. To change it: revert the disk to golden
  (`qemu-img snapshot -a golden`), delete the snapshot so the launcher cold-boots,
  boot with the new `mac=`, do the in-guest work, recapture. Verify **in-guest**
  (`ipconfig /all`) **and** the bridge **FDB** (`bridge fdb show dev win2krn0`).
- **DHCP conversion is one `netsh`, no reboot** (unlike Win98's registry `.reg`):
  `netsh interface ip set address name="Local Area Connection 2" source=dhcp` then
  `… set dns … source=dhcp`. The first command briefly drops the guest's IP, so the
  exec that issued it returns an error — the command still applied; re-probe. Apply
  the DHCP reservation on the gateway (`install-dhcp.sh --apply`) **before** the
  in-guest switch so the guest gets `10.99.0.11`, not a pool address (exec targets
  `<ip>:7788`).
- **Shut ICQ 2000b down before installing 2001b.** The 2001b installer aborts with
  *"You must Close the ICQ Application to Install ICQ"* while 2000b is running; there
  is no `taskkill` on Win2000 base, so close it from its **tray icon → Shut Down**,
  then **Retry**. It installs into the same `C:\Program Files\ICQ` (an in-place
  upgrade).
- **Never launch the installer or ICQ via the exec channel — the WNEXEC trap.** The
  agent runs `cmd /c <cmd> >C:\WNEXEC.OUT`; a long-lived child launched that way
  keeps the `WNEXEC.OUT` handle open and every *later* exec fails empty/rc 1. Launch
  from the **framebuffer** (Start ▸ Run, or the desktop icon). Delivery of the
  installer here was in-guest over the bridge (IE ▸ a temp CT `python3 -m
  http.server` on `10.99.0.2:<port>` ▸ **Open**), removed afterward.
- **`login.icq.com` still resolves to the gateway (DNS hijack), so first login
  reaches OSCAR without touching Connection Settings** — but set **Server → Host =
  `10.99.0.2`** explicitly anyway; it is deterministic and matches the gateway's
  `CLIENT_ICQ.md` ICQ-2001/2002 guide. Changing it needs a Disconnect→Reconnect to
  take effect (the client says so).
- **No display wedge.** Win2000's std-VGA under `cmd.exe` exec does not wedge like a
  Win9x VBE VDM; the warpnet `V`/CDS_RESET before `savevm` is belt, not load-bearing.

## Operating it

```bash
ssh lab 'labctl exec win2000 "ver"'                       # exec over the bridge
ssh lab 'labctl exec win2000 "ipconfig /all"'             # DHCP lease 10.99.0.11, DNS 10.99.0.2, no gw
ssh lab 'bash /data/vms/streamhost/stations/win2000/rn-tapnet.sh show'   # tap + guard chain + FDB
ssh lab 'labctl reset win2000'                            # loadvm golden → 2001b self-reconnects, greets ~30 s
# is the persona online? (server-side)
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
# the server-side SSI roster 2001b syncs on login
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 20000'
```

## Fan-out playbook — upgrading win98se / nt4 (ICQ 2000b → 2001b)

The coordinator fans this to the other Windows ICQ 2000b stations. Per station:

1. **Back the golden up** (byte copy, SHA256) — the rollback.
2. If a unique MAC / DHCP is still owed (win98se, nt4 were on the default MAC or
   static), do that **cold-bake** first (this doc's MAC + DHCP gotchas).
3. Deliver `ICQ2001b.exe` in-guest (IE over the bridge from a temp CT server, or the
   corpus), **Shut Down** the running ICQ 2000b, **Open** the installer, Next/Next.
4. First run: **Existing User** already detected (in-place upgrade) → *Password
   incorrect* → re-enter `RETRONET_ICQ_<STATION>_PASS`, **Save password** ON.
5. Preferences → Connections → **Server**: Host `10.99.0.2`, Port `5190`, **Keep
   connection alive ON**. Disconnect→Reconnect; confirm it is **silent**.
6. Confirm the **SSI roster** syncs by name (`rn-tool.py buddies <uin>`), a clean
   frame, then **recapture the golden**. **Disable** the station's `*-icq-nudge.timer`
   (self-heal supersedes it). Update the roster's `client` to `icq2001b`.
