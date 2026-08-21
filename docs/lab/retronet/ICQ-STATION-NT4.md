# nt4 ICQ station — the bridge as-built

**Status: LIVE.** `nt4` (Windows NT 4.0 Workstation SP6a) runs ICQ 2000b against
the retronet OSCAR gateway over a **real bridged NIC** on `vmbr-rn`. Open the
station and the persona (UIN `40000`) reconnects and the greeter bot (UIN
`10000` = **HiveBot**) messages it within ~30 s. This is the second ICQ station,
built to the win98se recipe ([`ICQ-STATION.md`](ICQ-STATION.md)); read that
first. This doc is only the **NT4-specific deviations** — and there were several,
because nt4 was NOT the "clean copy" the plan assumed.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device pcnet,netdev=n0,mac="$RN_NT4_MAC"` (**unchanged device**; a UNIQUE mac — see below), backend `-netdev tap,id=n0,ifname=nt4rn0,script=no,downscript=no` |
| Tap | `nt4rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/nt4/rn-tapnet.sh up` from the launcher on every start (chain `NT4RN-IN`) |
| Guest IP | **static `10.99.0.12/24`, NO default route, DNS none** (a stale `192.168.0.1` NameServer lingers in the registry but is unreachable) |
| OSCAR server | gateway CT `10.99.0.2:5190` |
| Persona / bot | UIN `40000` (nt4) / UIN `10000` (HiveBot); passwords in `registry/local.env` `RETRONET_ICQ_NT4_PASS` / `_BOT_PASS` |
| ICQ client | ICQ 2000b (`C:\Program Files\ICQ\Icq.exe`), `DefaultPrefs` **`Default Server Host`**=`10.99.0.2` (REG_SZ) **`Default Server Port`**=`dword:00001446` (=5190) |
| Exec | `labctl exec nt4 "<cmd>"` → `C:\WARPNET.EXE` (warpnet7788.exe) at **`10.99.0.12:7788` over the bridge** (`exec_kind warpd_e`, `exec_host`→`GEXEC_HOST`); no hostfwd |
| RAM | **256 MB** (128 MB thrashed with NT4 + ICQ + a spawned exec `cmd.exe` — exec failed and ICQ could not complete its sign-on) |

## nt4 was not a clean copy — five NT4-specific fixes

1. **The NIC driver was disabled, not absent, and mis-parameterised.** The gallery
   golden already had TCP/IP + NetBT installed and bound to `\Device\AMDPCN1`, and
   `amdpcn.sys` present — but `HKLM\SYSTEM\CCS\Services\AMDPCN\Start` was `4`
   (DISABLED) from the "clean desktop" pass, so the adapter never loaded ("service
   or driver failed during startup"; Event 6005). Re-enabling it (`Start=2`) then
   surfaced Event 5011 **"AMDPCN1: A required parameter is missing from the
   Registry"**: `Services\AMDPCN1\Parameters` was empty. NT4's own adapter setup
   (Control Panel → Network → Adapters → Properties → OK) rewrote the parameter
   block, but its PCI auto-detect wrote **`BusNumber=2, SlotNumber=0`** — backwards
   for QEMU's pcnet, which `info pci` shows at **Bus 0, Device 2**. The driver then
   initialised (got the static IP) but transmitted **zero frames**. The fix is
   `BusNumber=0, SlotNumber=2` (+ `BusType=5`, `TP=1` = force 10Base-T). All four
   are set in the golden. Reproduce offline (image mounted via qemu-nbd + ntfs-3g
   inside `chroot-guard run-private`):
   `[\ControlSet001\Services\AMDPCN\] "Start"=dword:2` and
   `[\ControlSet001\Services\AMDPCN1\Parameters] "BusNumber"=dword:0
   "SlotNumber"=dword:2 "BusType"=dword:5`.

2. **MAC collision.** QEMU's default pcnet mac is `52:54:00:12:34:56`, and every
   retronet Windows guest (`win98se`, `win2000`, `nt4`) was taking it — the bridge
   `fdb` learned one MAC on one port and blackholed the others. nt4 pins a unique
   mac on the **fleet scheme `52:54:00:52:4e:<last-IP-octet>`** (`52:4e`=RN, `.12`
   → `...0c`). Per the never-commit-a-MAC rule the real value lives in gitignored
   `registry/local.env` as `RN_NT4_MAC` (the committed launcher carries a
   placeholder and reads that one line at boot); the golden's vmstate carries the
   MAC, so a MAC change is a **cold re-bake**. **Any further bridged station MUST
   pin its own mac.**

3. **256 MB, not 128.** With ICQ 2000b resident, 128 MB thrashed: the warpnet exec
   `cmd.exe` returned `rc=1`/empty and ICQ's sign-on could not allocate. 256 MB is
   comfortable; the golden is re-baked at that size (so `-m` and the golden agree).

4. **ICQ's server value name is `Default Server Host`, not `Host`.** win98se's
   as-built shorthand ("`Host`") is wrong for the raw registry: ICQ 2000b creates
   `Default Server Host`=`login.icq.com` / `Default Server Port`=`0x1446` in
   `DefaultPrefs` **on first launch**. So set the override **after** ICQ has run
   once (not before — it overwrites pre-seeded values), while the wizard is closed,
   then relaunch → *Existing User* → sign in `40000`.

5. **No display wedge.** NT4's Cirrus is a kernel-mode driver, not a Win9x VBE
   miniport, so the "garbled 1600×176" DOS-box wedge does not occur; a `cmd.exe`
   exec leaves the 1024×768 frame clean. The warpnet `V` verb
   (`ChangeDisplaySettings(NULL, CDS_RESET)`) is still fired before `savevm` as a
   belt, and it is harmless (re-asserts the current mode).

## Containment — proven identical to win98se

From inside the guest (`labctl exec nt4 "ping -n 2 <ip>"`):

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (OSCAR) | **Reply** | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` | **timed out** | `NT4RN-IN` guard chain (Lock 3) |
| internet `1.1.1.1` (by IP) | **Destination host unreachable** | no default route (Lock 1) |

`route print` shows no `0.0.0.0` default route. UDP works (NetBIOS broadcasts on
the tap); ICMP works (ping reply). `rn-tapnet.sh` is a byte-for-byte copy of
win98se's, renamed (`nt4rn0`, `10.99.0.12`, `NT4RN-IN`), fail-closed.

## The reconnect mechanism — how "open the station" greets you

Same as win98se, and it is **not** a bare `loadvm`. `loadvm golden` alone does not
reconnect (the restored guest and gateway agree on sequence numbers). The trigger
is the station's **idle-pause**: paused → the gateway times out `40000` after
~130 s and drops it → on the visitor's resume (`cont`) the guest reconnects on a
fresh port, and the bot greets ~30 s later. `nt4-icq-nudge` (per-station labhost
`systemd` timer, every 10 s) is the healer: when the guest is running AND the
gateway shows `40000` offline it spoofs a gateway→guest ACK on the stale BOS port
to elicit the RST that ICQ 2000b will not produce on its own.

- **`GOLDEN_ICQ_PORT=1035`** — the source port the persona is restored onto from
  the golden. **The launcher `rm -f /run/nt4-icq-port` on every start**, so a
  portfile that drifted to a reconnect's ephemeral port cannot make the first
  post-`loadvm` nudge miss (it falls back to `GOLDEN_ICQ_PORT`). Recapture the
  golden ⇒ update `GOLDEN_ICQ_PORT` to the persona's port at capture time.
- **Idle-pause stays ON** (registry default) — it is the machinery, not just a CPU
  saver. `Auto Save Password` is ticked so the reconnect is silent.

**Proven twice (2026-08-21), greeting "hi! that's the NT box isn't it?" popped as
an ICQ message window on the framebuffer:** (A) idle-pause a live guest → drop →
resume → greet at +30 s; (B) fresh golden (paused) → visitor opens → nudge →
reconnect ~5 s → greet at +30 s.

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (~80 MiB, 2026-08-21 03:04, a
  cold-boot re-bake carrying MAC `52:54:00:52:4e:0c`) in the tile-local
  `/data/vms/streamhost/stations/nt4/nt4-golden.qcow2`. Tap-native, 256 MB,
  captured with ICQ **connected** (UIN `40000`, port 1035) + HiveBot in contacts +
  a clean 1024×768 frame. `labctl reset nt4` = `loadvm golden`.
- **Pre-change full-disk backup** (QEMU stopped, SHA256-verified):
  `/data/gallery-guests/Nt4/golden-backup-retronet-nt4-20260820/nt4-golden.qcow2`
  (`767c7afa…c83a`, `SHA256SUMS` in the dir) — the pre-retronet slirp golden.
  The pristine gallery image `/data/gallery-guests/Nt4/nt4-golden.qcow2` (128 MB,
  slirp) is untouched.

Full rollback = `systemctl stop streamhost@nt4`, copy the backup qcow2 over the
tile-local one, revert the launcher/registry, `systemctl start`.

## Gotchas that cost real time

- **The installed launcher is `/usr/local/lib/streamhost/stations/nt4/current`
  (the streamhost daemon), which reads the QEMU line from
  `/data/vms/streamhost/stations/nt4/qemu-streamhost.sh`.** A parallel
  `box-deploy` from `main` reverts that file to the committed version — during
  bring-up it silently reverted the tap launcher to the old **slirp** one twice,
  so the guest booted on slirp (`info network` = `type=user`) with an unroutable
  static IP and 0 tap traffic. Land the launcher to `main` early. After a re-bake
  the mismatched `-m` also fails `loadvm` ("Size mismatch: pc.ram").
- **`loadvm` does NOT cross netdev backends** — the old slirp golden could not be
  `loadvm`'d on the tap. nt4 was cold-booted on the tap (`qemu-img snapshot -a
  golden` to a clean base, then delvm) and a fresh tap-native golden baked.
- **File delivery.** The warpnet agent is stdout-only and appends its own
  `>C:\WNEXEC.OUT`, so `>`-redirects are swallowed. To write a file in-guest,
  terminate the write command with `&` so the agent's redirect attaches to a
  trailing no-op (`echo LINE>>C:\f& …& regedit /s C:\f`). Or inject offline.

## Operating it

```bash
ssh lab 'labctl exec nt4 "ver"'                       # exec over the bridge
ssh lab 'python3 /root/qmp_hmp.py /data/vms/streamhost/stations/nt4/qmp.sock "info network"'  # tap + mac
ssh lab 'bash /data/vms/streamhost/stations/nt4/rn-tapnet.sh show'   # tap + guard chain
ssh lab 'systemctl status nt4-icq-nudge.timer --no-pager; cat /run/nt4-icq-port'
# is the persona online?
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
```
