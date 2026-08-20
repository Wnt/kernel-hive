# win98se ICQ station — the bridge as-built

**Status: LIVE.** `win98se` runs ICQ 2000b against the retronet OSCAR gateway
over a **real bridged NIC** on `vmbr-rn`. Open the station and the persona
(UIN `98980`) reconnects and the greeter bot (UIN `10000`) messages it within
~30 s — the "kernel hive feels alive" moment. Parent:
[`POC-PLAN.md`](POC-PLAN.md), [`GATEWAY.md`](GATEWAY.md).

This supersedes the wave-2 slirp design. **slirp is gone**: QEMU's `guestfwd`
forwards only one connection per process, and OSCAR needs at least two (auth,
then the BOS redirect) plus a fresh reconnect on every wake. `n0` is now a
`tap` on `vmbr-rn`, so the guest shares L2 with the gateway CT and gets working
UDP + ICMP + real multi-connection TCP. The two-door (`:5190`/`:5191`) hack the
slirp design needed is gone: on the bridge the guest dials the **same** door the
bot does, `10.99.0.2:5190`, and the BOS address it hands back is routable.

## The wiring, at a glance

| | |
|---|---|
| NIC | `-device pcnet,netdev=n0` (**unchanged** — the `-device` is what `savevm`/`loadvm` bind to), backend `-netdev tap,id=n0,ifname=win98rn0,script=no,downscript=no` |
| Tap | `win98rn0`, persistent, enslaved to `vmbr-rn`, created + guarded by `streamhost/stations/win98se/rn-tapnet.sh up` from the launcher on every start |
| Guest IP | **static `10.99.0.10/24`, NO default route, DNS none** — offline by design (containment Lock 1) |
| OSCAR server | gateway CT `10.99.0.2:5190` (the one `RN` door; no `guestfwd`, no `:5191`) |
| Persona / bot | UIN `98980` (win98se) / UIN `10000` (greeter); passwords in `registry/local.env` `RETRONET_ICQ_*` |
| ICQ client | ICQ 2000b (`C:\Program Files\ICQ\Icq.exe`), `DefaultPrefs` Host `10.99.0.2` (REG_SZ) Port `dword:00001446` (=5190) |
| Exec | `labctl exec win98se "<cmd>"` → guest agent `C:\WARPNET.EXE` at **`10.99.0.10:7788` directly over the bridge** (`exec_kind warpd_e`, `exec_host` → `GEXEC_HOST`); no hostfwd |

## Containment — the guest reaches the retronet and nothing else

A bridged, unpatched Win98 is real exposure. Containment is layered so no single
failure opens the guest to the LAN, the gallery, or the internet. Proven from
inside the guest (`labctl exec win98se "ping -n 2 <ip>"`):

| From the guest to… | Result | Lock |
|---|---|---|
| CT `10.99.0.2` (OSCAR) | **Reply** | intra-bridge L2 (the point) |
| labhost bridge `10.99.0.1` | **timed out** | the per-station guard chain |
| gallery via `10.99.0.1:8443` | **blocked** | the per-station guard chain |
| internet `1.1.1.1` (by IP) | **unreachable** | no default route (Lock 1) |
| labhost LAN (by IP) | **unreachable** | no default route (Lock 1) |

Three layers:

1. **Lock 1 — no default route.** The guest is static with no gateway, so its
   own stack refuses any off-subnet packet: "Destination host unreachable".
2. **Lock 2 — `retronet-fw` (Stream B).** The FORWARD chain drops any vmbr-rn
   traffic that tries to route *through* labhost, for the day someone hands the
   guest a route.
3. **Lock 3 — this station's own guard chain (`WIN98RN-IN`, in `rn-tapnet.sh`).**
   `retronet-fw` deliberately leaves labhost's bridge address `10.99.0.1`
   reachable from the retronet — and the gallery listens on `0.0.0.0:8443`, so
   `10.99.0.1:8443` would be reachable, and no-default-route does **not** close
   it (it is on the guest's own subnet). The guard chain, scoped to the guest's
   source IP and inserted into INPUT **above** `RETRONET-IN`, drops every NEW
   flow the guest starts toward labhost while letting ESTABLISHED,RELATED
   replies through — so the exec channel's return traffic passes, but the guest
   can open nothing on labhost. Fail-closed: the launcher aborts (QEMU never
   starts) if the chain does not verify.

`retronet-fw` runs with `bridge-nf-call-iptables=0`, so guest↔CT traffic is pure
L2 and never touches these chains — the retronet reaching the retronet, which is
the whole point.

## The reconnect mechanism — how "open the station" greets you

This is the load-bearing behaviour and it is **not** a bare `loadvm`. `loadvm`
alone does not drop an idle TCP connection: the restored guest and the gateway
still agree on the sequence numbers, so both sides think the session is live and
nothing reconnects. The reliable trigger is the station's **idle-pause**:

1. The golden holds ICQ **connected** (a live BOS session to `10.99.0.2:5190`).
2. No visitor → the daemon QMP-**pauses** the guest (frozen). It stops answering
   OSCAR keepalives.
3. After ~135 s the gateway times the session out and **drops `98980`**, sending
   a FIN that queues at the frozen guest's NIC.
4. A visitor opens the station → the daemon QMP-**resumes** (`cont`) → the guest
   processes the queued FIN, the ICQ socket dies, and the client **reconnects
   within ~8 s** with a fresh sign-on (a new source port).
5. The bot sees the fresh presence-ONLINE and greets ~30 s later; ICQ auto-pops
   the message as a desktop window.

Measured end to end from resume: reconnect ~8 s, **greeting at ~32 s**. Proven
twice, greetings LLM-varied ("oh hey! Windows 98, nice. what are you up to?").

**Therefore idle-pause must stay ON (the registry default).** It is not just a
CPU saver here — it is the machinery that makes the exhibit greet you. `Auto
Save Password` is ticked in the client so the reconnect is silent.

## The display wedge (VBE/CRTC) — never bake it into the golden

Any `COMMAND.COM` VDM in the guest (every `labctl exec`, the re-IP, `regedit /s`)
can leave the S3/VBE miniport reprogrammed to a wrong short mode — the
"**garbled 1600x176**" signature, a live band over a stale desktop. It is
guest-side (CRTC), not a capture artifact. Recover it **in place** (never
`loadvm` the old slirp golden — it will not even load, see below):

- **Over the bridge** (exec-on-bridge up): the warpnet **`V` verb** —
  `printf 'V\n' | nc 10.99.0.10 7788` — calls `ChangeDisplaySettingsA(NULL,
  CDS_RESET)`. The agent also auto-resets after every `E` exec.
- **Framebuffer-only** (no network — e.g. mid-re-IP): `Start > Run > command`
  then **Alt+Enter twice** reprograms the mode. Drive it with `labctl` keyboard.

Trigger is guest-side VDM, **not** `loadvm`-wake: the golden was captured with a
clean 1600×1200 frame (a `V` reset immediately before `savevm`) and wakes clean,
because a resume/loadvm runs no VDM. **Always `labctl shot` and confirm a clean,
full-resolution frame before any `savevm`.**

## Golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot **`golden`** (ID 3, ~106 MiB,
  2026-08-20 23:46) in `/data/gallery-guests/Win98SE/win98se-kvm.qcow2`
  (+ games qcow2). **Tap-native**, captured with ICQ connected + the bot in the
  contact list + a clean 1600×1200 frame. `labctl reset win98se` = `loadvm golden`.
- **`icqinstalled`** (ID 2, slirp-era) is kept as a disk-only fallback. It is
  **not** `loadvm`-able on the tap (see below).
- **Full-disk byte-copy backup** (QEMU stopped, SHA256-verified) with **both**
  the pre-swap snapshots:
  `/data/gallery-guests/Win98SE/golden-backup-netswap-20260820/`
  (kvm `f751edd4…e353d`, games `f0c485d2…f4be`, `SHA256SUMS` in the dir).
- Older backups from the slirp waves:
  `golden-backup-retronet-wave2-20260820/` (exec-only golden) and
  `golden-backup-retronet-20260820/` (pre-exec).

Full rollback = `systemctl stop streamhost@win98se`, copy both qcow2 back,
`systemctl start`.

## Gotchas that cost real time

- **`loadvm` does NOT cross netdev backends.** The slirp `golden`/`icqinstalled`
  snapshots were saved with a `user` netdev, which writes a `slirp` vmstate
  section. On the `tap` backend `loadvm` fails: `Unknown section or instance
  'slirp' 0`. The `-device` being unchanged is necessary but **not** sufficient —
  the backend's saved state matters. Recovery: recover the ICQ-installed **disk**
  (`qemu-img snapshot -a icqinstalled`), cold-boot on the tap, and capture a
  fresh tap-native golden. Do not try to `loadvm` a pre-bridge snapshot.
- **Two PCNET adapters / two `TCP/IP -> AMD PCNET` bindings.** Win98 shows a
  phantom instance from an old PCI enumeration. The **live** adapter is the one
  `winipcfg` shows with an APIPA `169.254.x` address; the static IP must go on
  **its** binding (by elimination: the one that is still DHCP after you set the
  other). Both were set to `10.99.0.10`; the phantom has no hardware, so no
  duplicate-IP conflict.
- **Win98 ACPI restart hangs** at the black "safe to turn off" screen under this
  QEMU. TCP/IP config is written to the registry on **OK** (before the reboot),
  so force the reboot with QMP `system_reset` — the config still applies. The
  exhibit golden is `loadvm`-restored and never shuts down, so this only affects
  hand-driven config passes. (The `system_reset` is dirty → a ScanDisk on the
  way up; harmless.)
- **systemd `EnvironmentFile` keeps inline `#` comments as part of the value.**
  `SH_IDLE_PAUSE_SECS=0   # note` parses as the literal string `0   # note`,
  fails the `u64` parse, and silently falls back to idle-pause ON. Comments go on
  their own line. (This is why the guest kept pausing mid-bring-up.)
- **File delivery into the guest.** The exec channel is stdout-only and forbids
  `>`, so it cannot create files. Deliver a `.reg` either by writing it to the
  FAT32 volume from the host (`qemu-nbd` + mount — but **only** inside
  `chroot-guard run-private`; a raw host-namespace mount trips the mount-guard),
  then `labctl exec win98se "regedit /s c:\\file.reg"`; or fetch it in-guest over
  the bridge from a file served on the CT. `reged`/`chntpw` cannot edit the
  guest's Win9x CREG hives (they are not NT `regf`).

## Operating it

```bash
# is the persona online? (both should show after a wake)
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;d=json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read());print([s[\"screen_name\"] for s in d[\"sessions\"]])"'
# exec over the bridge
ssh lab 'labctl exec win98se "ver"'
# recover the display wedge over the wire
ssh lab 'printf "V\n" | nc 10.99.0.10 7788'
# the tap + guard chain
ssh lab 'bash /data/vms/streamhost/stations/win98se/rn-tapnet.sh show'
# re-capture the golden (from a CLEAN, connected frame only)
ssh lab '… savevm golden via HMP …'   # delvm golden first if present
```
