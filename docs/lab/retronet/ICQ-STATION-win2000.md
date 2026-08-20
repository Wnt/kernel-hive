# win2000 ICQ station — the bridge as-built

**Status: LIVE.** `win2000` runs ICQ 2000b against the retronet OSCAR gateway over
a **real bridged NIC** on `vmbr-rn`. Open the station and the persona (UIN
`20000`) reconnects and the greeter bot (UIN `10000` = HiveBot) messages it within
~30 s — the "kernel hive feels alive" moment. This is the win98se pathfinder
([`ICQ-STATION.md`](ICQ-STATION.md)) replicated on Windows 2000; read that first
for the shared design. This doc records only what is **different** on win2000.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device rtl8139,netdev=n0` (**unchanged** — the `-device` is what `savevm`/`loadvm` bind to), backend `-netdev tap,id=n0,ifname=win2krn0,script=no,downscript=no` |
| Tap | `win2krn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/win2000/rn-tapnet.sh up` from the launcher on every start |
| Guest IP | **static `10.99.0.11/24`, NO default route, DNS none** — offline by design (containment Lock 1), set via `netsh interface ip set address name="Local Area Connection 2" source=static addr=10.99.0.11 mask=255.255.255.0` |
| OSCAR server | gateway CT `10.99.0.2:5190` (the one `RN` door; no `guestfwd`, no `:5191`) |
| Persona / bot | UIN `20000` (win2000) / UIN `10000` (HiveBot); passwords in `registry/local.env` `RETRONET_ICQ_WIN2000_PASS` / `_BOT_PASS` |
| ICQ client | ICQ 2000b (`C:\Program Files\ICQ\Icq.exe`), `DefaultPrefs` `Default Server Host` = `10.99.0.2` (REG_SZ), `Default Server Port` = `dword:00001446` (=5190) |
| Exec | `labctl exec win2000 "<cmd>"` → guest agent `C:\WARPNET.EXE` at **`10.99.0.11:7788` directly over the bridge** (`exec_kind warpd_e`, `exec_host` → `GEXEC_HOST`); no hostfwd. NT `cmd.exe` captures **stdout** (agent redirects `>C:\WNEXEC.OUT`) |
| Launcher | **verbatim** `streamhost/stations/win2000/qemu-streamhost.sh` (was emit-`generic`); registry `runtime.qemu.mode = verbatim` |

## Containment — identical to win98se, proven the same way

Layered locks (topology / no-default-route / per-station `WIN2KRN-IN` guard chain);
see [`ICQ-STATION.md` §Containment](ICQ-STATION.md). Proven from inside the guest:

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (OSCAR) | **Reply** | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` (+ gallery `:8443`) | **timed out** | the `WIN2KRN-IN` guard chain (DROP counter climbs) |
| internet `1.1.1.1` (by IP) | **unreachable** | no default route (Lock 1) |

The guard chain has **no per-port exception**, so the ICMP-drop to `10.99.0.1`
also proves the gallery `:8443` TCP SYN is dropped — same rule, same source.

## The reconnect mechanism — the icq-nudge is the make-or-break

Identical to win98se: ICQ 2000b does not poll; after `loadvm golden` the guest is
restored onto a stale BOS socket the gateway already dropped, and neither side
speaks. The per-station healer forces the reconnect:

- `scripts/retronet/win2000-icq-nudge.{py,service,timer}` — a labhost systemd timer
  (5 s cadence) that, while the guest is **running**, spoofs a bad-seq TCP ACK from
  `10.99.0.2:5190` to the guest's **golden ICQ port `1032`**, eliciting the
  gateway's RST → ICQ reconnects on a fresh port → the bot greets ~30 s later.
- **`GOLDEN_ICQ_PORT=1032`** is the guest's TCP source port to `10.99.0.2:5190`
  captured in the golden (`pct exec 951 -- ss -tn | grep 10.99.0.11` at capture
  time). **If the golden is re-captured, update this** in `win2000-icq-nudge.py`.
- The nudge is inert once the persona is on a live (higher) ephemeral port, so it
  can never reset a healthy connection.

**Measured acceptance (twice):** frozen station → gateway drops the golden session
→ `labctl reset win2000` → nudge → reconnect (`1032`→new) within ~5 s → bot
**GREETED 20000** at +30 s: *"hi! nice, the 2000 machine."* The greeting is
delivered to the client and, with the guest running (a visitor present), auto-pops
an ICQ message window.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (ID 1, 208 MiB, 2026-08-21) in
  `/data/gallery-guests/Win2000/win2k-pro.qcow2`. **Tap-native**, captured with ICQ
  connected (src port 1032) + HiveBot in the contact list + a clean 1600×1200
  frame (warpnet `V`/CDS_RESET immediately before `savevm`). `labctl reset win2000`
  = `loadvm golden`.
- **Full-disk byte-copy backup** (QEMU stopped, SHA256-verified) of the **pre-swap
  slirp golden**:
  `/data/gallery-guests/Win2000/golden-backup-preswap-20260820/win2k-pro.qcow2`
  (`15aa5893…2975e3`, `SHA256SUMS` in the dir). The slirp `golden` snapshot it
  holds is **not** `loadvm`-able on the tap (see the win98se gotcha) — it is a
  disk-recovery fallback only.

Full rollback = `systemctl stop streamhost@win2000`, copy the backup qcow2 back,
revert the launcher/registry, `labctl gen`, `systemctl start`.

## Gotchas that are win2000-specific

- **No exec channel existed; bootstrapped over slirp first.** win2000 shipped with
  `exec_kind: null`. The warpnet agent (same `warpnet.c`, `-DWARP_PORT=7788`) was
  delivered while still on the ORIGINAL slirp NIC via IE5.5 (`iexplore
  http://10.0.2.2:<port>/WARPNET.EXE`, host `python3 -m http.server --bind
  127.0.0.1` + a temp hostfwd), run once, then `copy`d into the **All Users
  Startup** folder for cold-boot autostart. Only then was the NIC swapped to the
  tap and a fresh golden captured. The slirp golden can **not** `loadvm` on the tap
  (netdev-backend vmstate mismatch), so a cold boot + recapture was mandatory
  regardless.
- **NT `cmd.exe`, not `COMMAND.COM`.** Exec runs `cmd.exe /c <cmd> >C:\WNEXEC.OUT`.
  `cmd.exe` does not wedge the std-VGA display the way a Win9x DOS VDM does, so the
  `V`/CDS_RESET after each exec is belt-and-suspenders here, not load-bearing. The
  same stdout-only / no-own-`>` limits apply; to write a file, chain
  `(echo LINE)>>C:\x & rem` so the agent's trailing `>WNEXEC.OUT` binds to the
  `rem`, and wrap `echo` in parens so a trailing digit isn't read as a redirect
  handle.
- **IE "URL Location" Save-As quirk.** Saving a download straight into the shell
  `Start Menu\...\Startup` path fails with *"You cannot save in the URL Location
  you specified"*; save to a plain `C:\` path and `copy` it into Startup over exec.
- **`DefaultPrefs` server host was `login.icq.com`.** Set `Default Server Host` =
  `10.99.0.2` (port already `00001446`) via `regedit /s` **after install, before**
  the registration wizard, exactly as the [gateway wizard-bug note](GATEWAY.md)
  warns; then start ICQ → *Existing User* → UIN `20000`.
- **Idle-pause is the reconnect machinery, keep it ON** (registry default 60 s).
  A frozen guest lets the gateway time out the golden session; the visitor's wake
  (or `labctl reset`, which auto-resumes) then lets the nudge fire.

## Operating it

```bash
ssh lab 'labctl exec win2000 "ver"'                       # exec over the bridge
ssh lab 'printf "V\n" | nc 10.99.0.11 7788'               # un-wedge the display
ssh lab 'bash /data/vms/streamhost/stations/win2000/rn-tapnet.sh show'
ssh lab 'systemctl status win2000-icq-nudge.timer'        # the presence healer
ssh lab 'labctl reset win2000'                            # loadvm golden → greets ~30 s later
```
