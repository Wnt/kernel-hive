# win98se ICQ station — the bridge as-built (ICQ 2001b / SSI)

**Status: LIVE.** `win98se` runs **ICQ 2001b (build 3659)** against the retronet
OSCAR gateway over a **real bridged NIC** on `vmbr-rn`, on **DHCP** with a
**unique MAC**. Open the station and the persona (UIN `98980`) **self-reconnects**
silently and the greeter bot (UIN `10000` = HiveBot) messages it within ~30 s —
the "kernel hive feels alive" moment. This station was the retronet ICQ
*pathfinder* (DHCP + bridge + containment) on ICQ 2000b; it has now been upgraded
to ICQ 2001b following the win2000 pathfinder ([`ICQ-STATION-win2000.md`](ICQ-STATION-win2000.md)),
which proved the 2000b→2001b (SSI) recipe for the Windows fleet. Read that for the
shared design; this doc records what is **specific to win98se**.

## Why 2001b — the SSI contact list, synced server-side

ICQ 2000b keeps its contact list **client-local**: a golden rebuild or `labctl
reset` showed an empty list until a seeder re-drove the Add-Contact UI. **ICQ
2001b is the first ICQ generation with a server-stored (SSI/feedbag) contact
list** — the client signs in and **downloads its whole roster from the server,
with no client-UI seeding and no golden recapture**. The server side is populated
by the SSI fabric (`scripts/retronet/icq/seed_contacts.py ssi`, roster
`scripts/retronet/icq/roster.json`); win98se's server-side roster is the bot +
every other **onboarded** station.

**Proven on win98se:** signing UIN `98980` into the gateway pulled the full roster
down and rendered it **by name** with no manual adds — **HiveBot, win2000, nt4,
solaris, tru64** (the 4 other onboarded stations + HiveBot). The client's own
2000b→2001b migration *uploaded* its local list too ("Upload completed
successfully!"), but that **merges** with the fabric-seeded server roster (HiveBot
was already present) — it does not wipe it, so the full roster survives
(`rn-tool.py buddies 98980` = the 5 above, before and after).

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device pcnet,netdev=n0,mac="$RN_WIN98SE_MAC"` (**unchanged device**; a UNIQUE mac — see below), backend `-netdev tap,id=n0,ifname=win98rn0,script=no,downscript=no` |
| **MAC** | **unique, fleet scheme `52:54:00:52:4e:0a`** (`52:4e`=RN, `.10`→`…0a`). Real value in gitignored `registry/local.env` `RN_WIN98SE_MAC`; the committed launcher carries the scrubbed placeholder `02:00:00:00:00:0a` and reads the one line at boot. **The MAC lives in the golden vmstate, so it was baked by a COLD boot** (loadvm uses the baked MAC regardless, but the launcher `mac=` must match it) |
| Tap | `win98rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/win98se/rn-tapnet.sh up` from the launcher on every start (chain `WIN98RN-IN`, scoped to the guest IP) |
| Guest IP | **DHCP** — TCP/IP set to obtain IP *and* DNS automatically (Win98 default; "Disable DNS" = use the DHCP-supplied DNS). `retronet-dhcp` reserves `RN_WIN98SE_MAC → 10.99.0.10/24`, DNS `10.99.0.2`, **and NO default gateway** (containment stays Lock 1: no default route) |
| Seamless web | DNS = `10.99.0.2` (via DHCP) + **no IE5 proxy** → type any URL: the name resolves to the gateway and its `:80` origin serves the corpus. Proven: `ping spacejam.com` resolves to `10.99.0.2` and IE5 fetches from the gateway with no proxy |
| OSCAR server | gateway CT `10.99.0.2:5190` (the one `RN` door). ICQ's **Server → Host** is set to the literal `10.99.0.2` port `5190` (deterministic; the DNS hijack of `login.icq.com` also reaches it, but the literal removes the moving part) |
| Persona / bot | UIN `98980` (win98se) / UIN `10000` (HiveBot); passwords in `registry/local.env` `RETRONET_ICQ_PERSONA_PASS` / `RETRONET_ICQ_BOT_PASS`. **win98se was the pathfinder, so its persona keeps the generic `RETRONET_ICQ_PERSONA_*` keys** (`_PERSONA_UIN` = `98980`), not a `_WIN98SE_*` name |
| ICQ client | **ICQ 2001b build 3659** (`C:\Program Files\ICQ\Icq.exe`). Server **Host=`10.99.0.2` Port=`5190`**, **Keep connection alive = ON**, Save password = ON, Launch ICQ on startup = ON |
| Exec | `labctl exec win98se "<cmd>"` → guest agent `C:\WARPNET.EXE` at **`10.99.0.10:7788` directly over the bridge** (`exec_kind warpd_e`); no hostfwd |
| Launcher | `streamhost/stations/win98se/qemu-streamhost.sh` (KVM, `-cpu pentium3`, `-machine pc-i440fx-11.0,acpi=on`, std-VGA 1600×1200, sb16 audio, usb-tablet → absolute pointer) |

## The reconnect mechanism — 2001b SELF-HEALS (no nudge)

**This is the big win over ICQ 2000b, and it retires the per-station nudge.**

ICQ 2000b does not poll; after a wake it sits on a half-open zombie socket and
never reconnects, so win98se needed `win98se-icq-nudge` (a labhost timer that
spoofed the gateway's RST). **ICQ 2001b with `Keep connection alive` ON does not
need it:** on a `loadvm golden` wake the restored BOS socket is stale (the
gateway's session no longer matches the reverted TCP state), the client's
keepalive aborts it, and **2001b reconnects on a fresh port on its own —
silently, using the saved password — then HiveBot greets ~30 s later**.

- **`Keep connection alive` is load-bearing.** It ships **OFF**; set it ON
  (Preferences → Connections → **Server** tab). With it off, the wake leaves
  2001b passive.
- **Save password must persist — and win98se needs the password re-entered
  *twice*.** The 2000b→2001b migration carries the *wrong* password (2000b's
  saved-password bug), so first login shows *Password incorrect*; re-enter
  `RETRONET_ICQ_PERSONA_PASS` with **Save password** ticked. On win98se the
  **first in-client Disconnect→Reconnect after setting Server Host still
  re-prompts once** (the migrated password was still the saved one); re-enter it
  a second time, then confirm a **silent** Disconnect→Reconnect *before*
  capturing the golden. Every reconnect after that — manual and `loadvm`-wake —
  is silent.
- **The `win98se-icq-nudge.{py,service,timer}` files remain in the repo but the
  timer is DISABLED on the box** (`systemctl disable --now win98se-icq-nudge.timer`;
  the `.service` stays `static`). It is kept only as the fleet's shared 2000b
  healer until nt4/win95 also move to 2001b.

**Measured acceptance (via the production `labctl reset` path):** `labctl reset
win98se` restores the golden; the guest resumes, **98980 reconnected silently
(no password prompt), the SSI roster stayed intact, and HiveBot greeted within
~37 s** with LLM-varied lines (*"hi! you're on the win98 box right? :)"* /
*"hey, is that the Windows 98 machine?"*), reproducibly, **nudge OFF**.

**idle-pause must stay ON (the registry default)** — the bot only greets on a
fresh presence-ONLINE, so the persona goes offline (its golden session no longer
matches) and comes back on each wake. Auto Save Password makes it silent.

## Containment — the guest reaches the retronet and nothing else

Layered locks (no default route / `retronet-fw` / the per-station `WIN98RN-IN`
guard chain, scoped to the guest's source IP and inserted above `RETRONET-IN`).
On DHCP the reservation withholds option 3 (router), so *the addressing itself*
keeps the no-WAN posture. Re-proven from inside the guest on the new-MAC lease
(`labctl exec win98se "ping …"`):

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (OSCAR + `:80` origin) | **Reply** | intra-bridge L2 (the point) |
| `spacejam.com` → `10.99.0.2` | **Resolves + reply** | DNS hijack (retronet-dns), no proxy |
| labhost bridge `10.99.0.1` | **timed out** | the `WIN98RN-IN` guard chain |
| internet `1.1.1.1` (by IP) | **Destination host unreachable** | no default route (Lock 1) |

`retronet-fw` runs with `bridge-nf-call-iptables=0`, so guest↔CT traffic is pure
L2 and never touches these chains — the retronet reaching the retronet.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (ID 3, ~151 MiB, 2026-08-21
  11:28) in `/data/gallery-guests/Win98SE/win98se-kvm.qcow2` (+ the games qcow2,
  disk-only snapshot). **Tap-native + DHCP + MAC `52:54:00:52:4e:0a`**, captured
  with **ICQ 2001b connected** (UIN `98980`, Server `10.99.0.2:5190`, Keep-alive
  ON) + the full SSI roster + a clean 1600×1200 frame. `labctl reset win98se` =
  `loadvm golden`.
- **Full-disk byte-copy backup of the pre-swap ICQ-2000b golden** (QEMU stopped,
  SHA256-verified): `/data/gallery-guests/Win98SE/golden-backup-preicq2001b-20260821/`
  (`win98se-kvm.qcow2` `53e38eec…dd27c`, `win98se-games.qcow2` `027a381c…37c75`,
  `SHA256SUMS` in the dir). This is the rollback for the whole 2001b/MAC swap: it
  holds the ICQ 2000b + default-MAC (`52:54:00:12:34:56`) + DHCP golden.
- Older backups: `golden-backup-predns-20260820/` (static-IP), `…-netswap-…`,
  `…-retronet-…` (pre-bridge; **not** `loadvm`-able on the tap).

Full rollback = `systemctl stop streamhost@win98se`, copy both `preicq2001b`
qcow2 back, revert the launcher `mac=`/registry/`local.env` reservation (restore
the default-MAC reservation `52:54:00:12:34:56=10.99.0.10`), `install-dhcp.sh
--apply`, re-enable `win98se-icq-nudge.timer`, `systemctl start`.

## Gotchas that are win98se-specific (and the 2000b→2001b upgrade)

- **The MAC is baked by a COLD boot, not `loadvm`.** To change it: back the
  golden up (byte copy), apply the DHCP reservation for the NEW mac **first**
  (`install-dhcp.sh --apply`), revert both disks to golden
  (`qemu-img snapshot -a golden`), **delete** the `golden` snapshot from both so
  the launcher cold-boots (`qemu-img snapshot -d golden`), boot with the new
  `mac=`, do the in-guest work, recapture. Verify **in the bridge FDB**
  (`bridge fdb show dev win98rn0` → the new MAC) **and** the DHCP lease
  (`journalctl -u retronet-dhcp` in CT 951 → `…4e:0a → ACK 10.99.0.10`).
- **The 2001b installer is slow, not hung — keep the guest RUNNING.** The station
  idle-pauses when no streamhost visitor is connected (the vCPU freezes), which
  stalls the InstallShield "Unpacking Files (Red Bend)" phase at a file for
  minutes at a time. It is **not** a hang (QEMU sits at ~0 % CPU because the guest
  is HALTed). Hold the guest awake for the duration of any long unattended step
  — `scripts/lib/guest_wake.py`'s `hold_lease()` keeps the daemon from pausing
  it under you, and the tools that drive the guest (`labctl`,
  `scripts/dev/qmp-type.py`) take that lease themselves — and the install
  finishes in a couple of minutes. See
  [`../INPUT-DEBUGGING.md`](../INPUT-DEBUGGING.md).
- **Shut ICQ 2000b down before installing 2001b.** The installer aborts with
  *"You must Close the ICQ Application"* while 2000b is running; there is no
  `taskkill` on Win98, so close it from its startup **Welcome** panel
  (*Quit Session* → *Yes*) or the tray icon → *Shut Down*, then re-run the
  installer. It upgrades in place into `C:\Program Files\ICQ`.
- **Deliver the installer in-guest over the bridge.** The guest reaches only the
  gateway CT (labhost is blocked by the guard chain), so serve `ICQ2001b.exe`
  from CT 951 (`systemd-run --unit=dl-icq python3 -m http.server <port>
  --directory /tmp`, the blob `pct push`ed in) and fetch it with IE:
  **Start ▸ Run ▸ `iexplore http://10.99.0.2:<port>/ICQ2001b.exe`** ▸ **Open**.
  Remove the CT server + `/tmp/ICQ2001b.exe` afterward.
- **Absolute-pointer clicks: warm up after a resume.** The usb-tablet drops the
  first absolute position right after a `cont`, landing a click at (0,0). Send a
  throwaway `move` (or a first `abs`) before the real `click`, or double the
  `abs` event; the second one lands.
- **Win98 ACPI restart hangs** at the black "safe to turn off" screen under this
  QEMU; a re-IP/registry pass ends with QMP `system_reset` (dirty → ScanDisk on
  the way up; harmless). The exhibit golden is `loadvm`-restored and never shuts
  down, so this only affects hand-driven passes.
- **The exec channel can't create files** (stdout-only, no `>`), and any
  `COMMAND.COM` VDM (every `labctl exec`) can leave the S3/VBE miniport in a
  wrong short mode (garbled band). Recover over the wire with the warpnet **`V`**
  verb (`printf 'V\n' | nc 10.99.0.10 7788` → `ChangeDisplaySettings(CDS_RESET)`),
  or `Start ▸ Run ▸ command` + **Alt+Enter** twice. **Always `labctl shot` a
  clean, full-resolution frame before any `savevm`** — a `loadvm` wake runs no
  VDM, so the clean golden stays clean.

## Operating it

```bash
ssh lab 'labctl exec win98se "ver"'                       # exec over the bridge
ssh lab 'labctl exec win98se "ipconfig /all"'             # (winipcfg on 9x) DHCP 10.99.0.10, DNS 10.99.0.2, no gw
ssh lab 'bash /data/vms/streamhost/stations/win98se/rn-tapnet.sh show'   # tap + guard chain + FDB
ssh lab 'labctl reset win98se'                            # loadvm golden → 2001b self-reconnects, greets ~30 s
# the server-side SSI roster 2001b syncs on login
ssh lab 'pct exec 951 -- python3 /opt/ras/rn-tool.py buddies 98980'
# is the persona online? (server-side)
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
```
