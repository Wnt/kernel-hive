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
| Guest IP | **DHCP** — TCP/IP set to "obtain automatically" for IP *and* DNS. `retronet-dhcp` hands out reserved `10.99.0.10/24`, DNS `10.99.0.2`, **and NO default gateway** (containment stays Lock 1: no default route). Reservation keys on the guest MAC `52:54:00:12:34:56` |
| Seamless web | DNS = `10.99.0.2` (via DHCP) + **no IE5 proxy** → type any URL: the name resolves to the gateway and its `:80` origin serves the corpus. Proven: IE5 renders `http://spacejam.com/` and `http://search.retronet/` (see §Seamless web below) |
| OSCAR server | gateway CT `10.99.0.2:5190` (the one `RN` door; no `guestfwd`, no `:5191`). ICQ uses the literal IP, so DNS is irrelevant to it |
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

## Seamless web — DHCP + no proxy, and the onboarding recipe

The station browses the museum's corpus with **nothing configured but DHCP**. The
guest's TCP/IP is set to **"Obtain an IP address automatically"** and **"Obtain
DNS server address automatically"** (Win98 defaults), and IE5 has **no proxy**. On
boot it gets, from `retronet-dhcp`: `10.99.0.10`, mask, **DNS `10.99.0.2`**, and
**no default gateway**. Then every URL works: the name resolves to the gateway
(`retronet-dns`), IE5 connects to `10.99.0.2:80`, and the `:80` origin serves the
corpus by `Host`. **Proven** — `winipcfg` shows the reserved lease with an empty
gateway, and IE5 renders `http://spacejam.com/` and `http://search.retronet/`.
Full addressing plane: [`WEB-PROXY.md`](WEB-PROXY.md).

**Onboarding recipe (every future station):** two steps, no per-guest static
config.

1. **In the guest:** set the network adapter's TCP/IP to obtain the IP *and* DNS
   automatically (the Win98 default; select "Disable DNS" in the DNS tab — that is
   how Win9x means "use the DHCP-supplied DNS"), and clear any IE proxy. Reboot.
2. **On the gateway (once):** add the station's MAC→IP to
   `registry/local.env` `RETRONET_DHCP_RESERVATIONS` and re-run
   `install-dhcp.sh --apply`. Keeps the station on a **stable** IP so
   exec-over-bridge stays at `<ip>:7788`. **Each station needs a UNIQUE guest MAC**
   — see WEB-PROXY.md "The fleet-shared-MAC caveat".

**Converting win98se's static config to DHCP (what was done here), since the exec
channel can't create a file:** serve a tiny `.reg` from the CT corpus by IP and
import it in-guest. It sets both TCP/IP bindings to DHCP and clears the IE proxy:

```
REGEDIT4
[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\Class\NetTrans\0000]
"IPAddress"="0.0.0.0"
"IPMask"="0.0.0.0"
[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\Class\NetTrans\0001]
"IPAddress"="0.0.0.0"
"IPMask"="0.0.0.0"
[HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings]
"ProxyEnable"=dword:00000000
"ProxyServer"=""
```

`pct push` it to `corpus/<gateway-ip>/dhcp.reg`, then in the guest **Start > Run >
`iexplore http://10.99.0.2/dhcp.reg`** (Run resolves `iexplore` via App Paths;
`COMMAND.COM`/exec does not), **Open** on the download → **Yes** on the import,
then reboot (QMP `system_reset` — Win98 ACPI restart hangs). Remove the `.reg`
from the corpus afterward; it is a delivery artifact, not museum content. A **cold
boot re-runs ICQ's first-run flow** (EULA → "Password incorrect", the saved-
password bug) — dismiss with the mouse (QMP `input-send-event`; the framebuffer
never sees the bridge, so it works despite the MAC collision) and re-enter the
persona password from `local.env`. Recapture the golden once ICQ is back online.

## The reconnect mechanism — how "open the station" greets you

This is the make-or-break, and it needed a purpose-built healer:
`win98se-icq-nudge` (a labhost systemd timer,
[`scripts/retronet/win98se-icq-nudge.py`](../../../scripts/retronet/win98se-icq-nudge.py)).

**Why ICQ 2000b will not do it alone.** ICQ 2000b does not poll the server; it
waits to be pinged. On any wake the guest is left on a **half-open zombie**
socket — it believes it is connected while the gateway shows the persona offline
— and, silent on both sides, it never notices and never reconnects. Two ways in:

- `loadvm golden` (a `labctl reset`, or the launcher's boot) restores the
  golden's BOS socket, which the gateway timed out and dropped long ago; and
- the daemon resumes an idle-paused guest with **`cont`, not `loadvm`**, so after
  a reconnect the guest **drifts** to a new ephemeral port, and the next idle-drop
  strands *that* socket.

There is one self-healing case — if the guest is paused while its connection is
still **live**, the gateway's ~135 s timeout FIN queues at the frozen NIC and the
guest processes it on resume (~8 s reconnect). But a reset never leaves a live
one, so this cannot be relied on.

**The nudge.** The timer elicits the gateway's *own* RST for the stale socket: it
sends the guest a spoofed TCP ACK as if from the gateway
(`10.99.0.2:5190 → 10.99.0.10:<port>`) with a bad seq; the guest challenge-ACKs
the *real* gateway, which has no socket for that 4-tuple and RSTs it; ICQ sees
the drop and reconnects on a fresh port with a clean sign-on. It is **port-robust
and safe**: it records the persona's live remote port whenever the gateway shows
it ONLINE and fires only when it is OFFLINE, at that last-known port — so it
always hits the real zombie whatever it drifted to, and can never reset a healthy
connection (there is none to reset while offline). It seeds with the golden's
port `1032`; **if the golden is re-captured, set `RN_ICQ_GOLDEN_PORT` / clear
`/run/win98se-icq-port`** so the seed matches the new golden's ICQ port.

End to end from a `labctl reset`: reconnect within ~8 s, **greeting at ~32 s**.
Proven repeatedly (the greeter's LLM-varied lines: "oh hey! Windows 98, nice.
what are you up to?", "hey, is that the Windows 98 machine?").

**idle-pause must stay ON (the registry default)** — the bot only greets on a
fresh presence-ONLINE, so the persona must go offline (gateway timeout while
paused) and come back for each visitor. `Auto Save Password` is ticked so the
reconnect is silent. Known rough edge: right after a boot/reset the guest runs
its idle-pause grace with no visitor, so the healer fires and a greeting window
can be left open in the first paused frame; a real (long-idle) visitor still gets
a fresh greeting on open. Making each open pristine would need loadvm-on-resume
in the daemon, which is out of scope here.

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

- **LIVE golden:** internal snapshot **`golden`** (ID 3, ~136 MiB,
  2026-08-21 02:33) in `/data/gallery-guests/Win98SE/win98se-kvm.qcow2`
  (+ games qcow2). **Tap-native + DHCP** — captured with TCP/IP on "obtain
  automatically" (leased `10.99.0.10`, DNS `10.99.0.2`, no gateway), IE5 no-proxy,
  ICQ connected + the bot in the contact list, a clean 1600×1200 frame.
  `labctl reset win98se` = `loadvm golden`. Verified: loadvm restores clean, exec
  works, `ping spacejam.com` resolves to `10.99.0.2`, ICQ (`98980`) reconnects.
- **`icqinstalled`** (ID 2, slirp-era) is kept as a disk-only fallback. It is
  **not** `loadvm`-able on the tap (see below).
- **Full-disk byte-copy backup of the pre-DHCP golden** (QEMU stopped, SHA256):
  `/data/gallery-guests/Win98SE/golden-backup-predns-20260820/`
  (kvm `9520d469…c807`, games `3a298bd9…2366`, `SHA256SUMS` in the dir) — the
  static-IP golden, the rollback for the DHCP conversion.
- Older backups: `golden-backup-netswap-20260820/` (pre-swap snapshots),
  `golden-backup-retronet-wave2-20260820/` (exec-only), `golden-backup-retronet-20260820/` (pre-exec).

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
