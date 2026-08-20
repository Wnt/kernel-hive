# win98se ICQ station — wave 2 as-built (HANDED OFF: slirp → bridged NIC)

**Status: BLOCKED on slirp, redirected.** Wave 2 installed ICQ 2000b on the live
win98se and got the client to the login step, but the persona never signed in
because **QEMU slirp `guestfwd` cannot carry the OSCAR protocol** (finding below).
The operator's decision (2026-08-20): move win98se **off slirp onto a real
bridged NIC** (a tap on `vmbr-rn`) so the guest gets working UDP + ICMP and
reliable multi-connection TCP straight to the gateway. A fresh agent does the
network swap and re-does the ICQ connection wiring. This doc is the hand-off
baseline. Parent: [`POC-PLAN.md`](POC-PLAN.md), [`GATEWAY.md`](GATEWAY.md).

## The load-bearing finding: slirp `guestfwd` is single-connection

`guestfwd=tcp:10.0.2.100:5190-tcp:10.99.0.2:5191` (added this wave) forwards the
**first** guest connection to the gateway and then stops: subsequent connections
are accepted guest-side (`info usernet` shows them `ESTABLISHED` with **`FD=-1`**,
i.e. no host-side socket) but never reach the gateway, and the first connection
lingers so the single slot never frees. Proven on a **fresh** QEMU process:
telnet #1 → gateway sees 1 conn; concurrent telnet #2 → gateway still 1 conn.

OSCAR needs at least two connections (auth, then the BOS redirect) plus a fresh
reconnect on every wake, so one-connection `guestfwd` is a dead end. By contrast
slirp's **host-access path** (`guest → 10.0.2.2 → labhost`) makes real host
sockets (`FD=26`) and is what the 5.3 MB installer download rode — but using it
would need a labhost relay + advertising `10.0.2.2`. The bridged-NIC swap is the
cleaner fix and removes the two-doors complexity entirely: on a real L2 the guest
reaches the gateway CT at **`10.99.0.2:5190`** directly, the same address the bot
uses, so only **one** OSCAR door is needed and the BOS advertisement is routable.

Nobody had exercised the pinhole from inside a guest before — wave-1 only tested
labhost→gateway ([GATEWAY.md](GATEWAY.md), [BOT.md](BOT.md) both say the guest
side is wave-2/unproven), so this is a wave-1 contract gap, not a regression.

## What persists on the guest disk (in snapshot `icqinstalled`)

Recaptured as internal snapshot **`icqinstalled`** (see lineage). The **live**
station currently sits on the untouched `golden` (exec-only); `loadvm icqinstalled`
brings the ICQ work back.

- **ICQ 2000b installed** — `C:\Program Files\ICQ\`, main exe `Icq.exe`
  (build 2000b/3281). Installer also left at `C:\icq2000b.exe`. The exec agent
  `WARPNET.EXE` is still the only item in the StartUp folder (installer was moved
  out of StartUp so it can't auto-run at logon).
- **`DefaultPrefs` registry set** (verified by export) under
  `HKEY_CURRENT_USER\Software\Mirabilis\ICQ\DefaultPrefs`:
  - `"Default Server Host"="10.0.2.100"` (REG_SZ) — **change for the bridge**
    (point at the gateway's bridge IP, `10.99.0.2`).
  - `"Default Server Port"=dword:00001446` (REG_DWORD, **decimal 5190** —
    0x1446; my first attempt used 0x143e = 5182 and the client dialled the wrong
    port, caught via QEMU's outbound socket). Retro AIM Server's `CLIENT_ICQ.md`
    is authoritative: Host is REG_SZ, Port is REG_DWORD decimal.
  - Set these **after install, before the registration wizard enters a hostname**
    (a wizard-entered hostname breaks saved passwords). Delivered as a `.reg`
    merged via IE5 (the exec channel can't create files — stdout-only, no `>`).
- **Persona sign-in: NEVER succeeded.** Failure was the guestfwd defect above,
  not credentials: the server authenticates UIN `98980` fine
  (`rn-tool.py login 10.99.0.2 5190 98980 <pass>` → PASS). "Auto Save Password"
  was ticked in the wizard (needed for silent reconnect-on-wake). Contact list:
  bot UIN `10000` was **not** added yet.

## Golden lineage & rollback (FULL paths)

- **LIVE now:** internal snapshot `golden` (ID 1, 89.3 MiB, 2026-08-20 20:03:55)
  — Stream A's exec-agent golden, no ICQ. Restore anytime: `labctl reset win98se`.
- **My ICQ work:** internal snapshot `icqinstalled` (ID 2, 108 MiB,
  2026-08-20 21:22:04) in `/data/gallery-guests/Win98SE/win98se-kvm.qcow2`
  (+ games qcow2). ICQ installed + DefaultPrefs set, **not signed in**. Taken on
  the slirp device set; the pcnet *device* is unchanged by a user→tap backend
  swap, so `loadvm icqinstalled` should still load after the bridge swap, but the
  guest's IP config (slirp DHCP `10.0.2.15`) will need reconfiguring for the
  bridge.
- **Full-disk byte-copy backups** (QEMU stopped, verified SHA256SUMS):
  - `/data/gallery-guests/Win98SE/golden-backup-retronet-wave2-20260820/`
    — **mine**, the exec-agent golden (== live golden). kvm sha256
    `9d291738da88461e02787f441604f0eef64be6d7822723ec5813ce1058d51935`,
    games `b44eca0f52d424d53af2b8a3de64ab67032acc71268bfc41b871d96b8c087648`.
    This is the "exec works, no ICQ" rollback.
  - `/data/gallery-guests/Win98SE/golden-backup-retronet-20260820/`
    — Stream A's, the pre-exec golden (older).
  Full rollback = `systemctl stop streamhost@win98se`, copy both qcow2 back,
  `systemctl start`.

## For the fresh agent (bridge swap)

- **Registry/launcher left in place (durable):** `registry/stations/win98se.json`
  + `streamhost/stations/win98se/qemu-streamhost.sh` still carry the now-moot
  `guestfwd` on netdev `n0` (commit `ba658fe`, on `main`, deployed). Replace the
  whole netdev when you swap to the tap; the exec `hostfwd=…57792-:7788` must be
  preserved (or re-homed) or `labctl exec win98se` breaks.
- With a bridged NIC, point ICQ `DefaultPrefs` Host at `10.99.0.2` (gateway CT),
  Port `dword:00001446`. The gateway can then serve the guest from its `RN` door
  (`10.99.0.2:5190`) directly — no `guestfwd`, no relay, no `RN_GUEST_ADDR`
  slirp door. `retronet-fw` currently drops retronet-initiated traffic toward
  labhost's LAN but allows the bridge address; check the guest↔CT path is open.
- Credentials remain `registry/local.env` `RETRONET_ICQ_PERSONA_UIN=98980` /
  `_PERSONA_PASS`. Bot (UIN 10000) is live and watching 98980.
- Idle-pause: my temp `SH_IDLE_PAUSE_SECS=0` override was removed from the live
  `station.env`; the running daemon still has it off until its next restart.
