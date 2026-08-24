# win95 ICQ — ICQ 2000b, live, signed in, reconnecting nudge-free

**Status: LIVE on ICQ 2000b (build 3281), onboarded.** `win95` signs **UIN
`95000`** into the retronet OSCAR gateway, draws its roster by name, is greeted
by HiveBot, and — with *Keep connection alive* ON — **reconnects on its own
across a reset, with no nudge.** The client swap from 2002a landed 2026-08-24
after a root-cause pass on a contained clone of the then-live golden; every
claim on this page was measured with `tcpdump` on the host side of the guest's
tap, the gateway's own session API, the greeter-bot journal, and the
framebuffer, with timestamps and ports quoted so the captures can be re-read.

This overturns the two findings this doc used to carry — that 2000b *"never
reaches `connect()`, emits zero packets"* and that the only workable client
(2002a) *"ignores even a gateway RST and never reconnects."* Both were true of
the states they were measured in; **neither is true of a clean 2000b install on
this guest's current software stack.** The measurements below were made on the
clone (source IP `10.99.0.100`); the same behaviour was then re-proven on the
live station (source IP `10.99.0.13`) before the golden was recaptured.

## What was measured, and how far each claim is proven

### 2000b dials out and signs in — the "zero packets" claim is false

A fresh ICQ 2000b install (into a clean `C:\Program Files\ICQ`, with the
guest's existing Winsock 2, DCOM95 1.3 and Common Controls 5.80 all present),
driven *Existing User → `95000` → Next*, produced this on the wire within one
millisecond of the click — `tcpdump -i w95icq0`:

```
16:06:44.715  10.99.0.100.1029 > 10.99.0.2.53:   A? login.icq.com.      (DNS query)
16:06:44.715  10.99.0.2.53     > 10.99.0.100.1029: A 10.99.0.2          (hijack answer)
16:06:44.716  10.99.0.100.1030 > 10.99.0.2.5190:  Flags [S]            (SYN to OSCAR)
16:06:44.716  10.99.0.2.5190   > 10.99.0.100.1030: Flags [S.]          (gateway SYN-ACK)
```

DNS resolves, the SYN leaves the guest, the gateway answers, the full OSCAR
BUCP handshake runs, the auth server hands back the BOS cookie, and a second
connection (`1031 → 5190`) carries the BOS login. The wizard shows *"Registration
Completed Successfully — Your ICQ number: 95000"*; the gateway session list goes
`['10000', …]` → `+ '95000'`; **HiveBot greets** (`retronet.bot INFO GREETED
95000 (win95)`).

Note the host the client actually dialled: it resolved **`login.icq.com`**, not
a literal — the factory `Default Server Host` carried the connection through the
retronet DNS hijack (`login.icq.com` → `10.99.0.2`). The `DefaultPrefs`
server-literal override the fleet contract describes is **not required** for
sign-in; the hijack is sufficient. (Setting the literal `10.99.0.2` afterwards
is still worth doing — it is deterministic — see below.)

The started client then holds a stable session: `persist.pcap` shows fresh BOS
connections (`1035/1036 → 5190`) and the datafile fetches (`web.icq.com`,
`cb.icq.com` → gateway `:80`) an online 2000b makes, with **zero `RST`** for the
life of the session.

**Why the earlier passes saw "zero packets" (inference, not measured).** The
historical failure was not reproducible here, so its cause cannot be stated with
the same certainty as the facts above. The behaviour — the client sitting at
*"Registering User"* with no socket ever opened — is what ICQ's OSCAR module does
when it cannot initialise Winsock/its transport DLLs. The load-bearing difference
in this pass is a **clean install onto a now-complete stack**: Winsock 2, DCOM95
and Common Controls were already present *when ICQ was installed*, and ICQ was
installed into an empty ICQ directory (the 2002a tree moved aside first), so its
own OSCAR components registered against a complete system. Installing those
prerequisites *after* an ICQ that was laid down without them — which is what the
earlier "unchanged by [installing] Winsock 2 / DCOM95" note describes — does not
re-register ICQ's transport DLLs; a fresh reinstall does. Treat this paragraph as
the best-supported explanation, not a measurement.

### 2000b reconnects across a reset — no nudge — and WHY, precisely

The reconnect is **event-driven**: ICQ 2000b silently re-dials the moment its
dead socket produces an error. What produces that error is the part the first
draft of this page got wrong, and the live acceptance run is what corrected it:

- **With *Keep connection alive* OFF, a reset leaves a zombie.** Measured on the
  live station: after `labctl reset` onto a keep-alive-OFF golden the client sat
  wire-silent for **10+ minutes** — zero packets toward `:5190` — with the panel
  showing *Online* while the gateway had no session. 2000b does not set
  `SO_KEEPALIVE` (no MSTCP probes were seen, unlike 2002a, which probed and then
  ignored the answer), and with the checkbox off it sends no application pings
  either. Nothing ever errors, so nothing ever reconnects. This is exactly the
  zombie the fleet's 2000b-era nudges were built to break.
- **With *Keep connection alive* ON, 2000b sends a 6-byte FLAP keepalive every
  ~58 s** (measured on the wire: pings at 17:31:44 and 17:32:42 on an idle
  session). After a reset the first ping hits the gateway's dead socket, the
  gateway answers **RST**, the client tears the socket down and re-dials —
  **silently, with the saved password, within about a minute**. The same
  self-heal 2001b is credited with; 2000b has it too, it just ships OFF.
- A delivered RST heals instantly regardless of the checkbox (proven repeatedly
  on the clone: gateway-side socket kills — live or queued in the tap while the
  guest was paused — were followed by fresh SYNs within seconds of delivery).
  That is also why a `*-icq-nudge` (a manufactured RST) works on 2000b, where
  it provably does nothing for 2002a. **No nudge is needed here** — the ping
  timer is the healer — but the option is real if it is ever wanted.

Measured acceptance on the clone (`reset2.pcap`, reproduced twice):

```
16:23:21  10.99.0.2.5190   > guest.1048: Flags [R.]   (gateway RSTs the stale socket)
16:23:33  guest.1048       > 10.99.0.2.5190: [R]      (guest tears its dead socket down)
16:23:42  guest.1047/.1048 > 10.99.0.2.5190: [S][S]   (fresh reconnect — auth + BOS)
```

then `presence: 95000 ONLINE`, a fresh source port, low `online_seconds`, no
password prompt, roster by name, HiveBot greeting. The same was then proven
through the production `labctl reset win95` on the live golden (below).

### The trap that almost shipped a broken golden: 2000b's prefs revert on a cold boot

**ICQ 2000b flushes its Server-tab preferences and the saved password to the
per-UIN DB only on a graceful ICQ exit.** Set *Keep connection alive*, set the
literal server host, watch them work — and a cold boot after an ungraceful stop
silently reverts Host to `login.icq.com`, unticks keep-alive, and forgets the
password (the saved-password re-prompt appears once; re-enter it and it holds
for that run). This pass shipped a keep-alive-OFF golden exactly this way, and
only the failed first acceptance run caught it.

The `loadvm`-restored exhibit never cold-boots, so a golden captured with the
settings live in the running client is safe. But **every future re-bake must
re-verify the Server tab** (Preferences → Connections → Server: Host
`10.99.0.2`, Port `5190`, *Keep connection alive* ticked) as the last thing
before `checkpoint-guard recapture`, and the durable way to persist them is:
set → let ICQ exit gracefully (Windows shutdown) → cold boot → verify they
held → then capture.

## The swap, as landed (2026-08-24)

The clone disk proven above was promoted to the station following the
`checkpoint-guard` discipline (never hand-rolled `savevm`/`delvm`):

1. **Hygiene boot on the clone rig**: cold boot, ScanDisk, ICQ auto-launch,
   password re-entered once more with *Save password* (2000b's saved-password
   bug re-prompts on the first cold boot after a save — the same
   "enter it twice" behaviour win98se documented), silent Disconnect→Reconnect
   proven, live gateway-side socket kill self-healed onto a fresh port, then a
   clean Windows shutdown.
2. **Offline cleanup** (`qemu-nbd`): tooling (`C:\TOOLS`), root installers,
   the stashed 2002a tree (`ICQ2002A.SAV`) and scratch files removed; the
   `95000tmp.*` compaction pair deleted (main DB pair kept); internal snapshots
   dropped; qcow2 leak-checked clean.
3. **Swap**: `streamhost@win95` stopped; the retained 2002a backup re-verified
   against its `SHA256SUMS` (OK); the outgoing live disk stashed; the 2000b
   disk copied in as `win95-golden.qcow2` (no snapshots → the launcher
   cold-boots with the real `RN_WIN95_MAC`).
4. **Cold bake on the live station**: DHCP ACK for the station MAC →
   `10.99.0.13`; ICQ auto-launched; the saved-password re-prompt appeared once
   (expected, above) and the password was re-entered with *Save password*;
   after that, Disconnect→Reconnect is **silent** (verified: `95000` dropped
   from and returned to the session list with no prompt, fresh
   `online_seconds`), and HiveBot greeted each fresh arrival.
5. **First capture shipped the prefs-revert trap** (previous section): the cold
   boot had silently reverted keep-alive to OFF, the first `labctl reset`
   acceptance run left the documented zombie, and the wire showed why (zero
   packets in 10+ minutes). The Server tab was re-set on the live station
   (Host `10.99.0.2`, keep-alive ON), the ~58 s ping cadence was confirmed on
   the wire, and the golden was **recaptured** with the ping timer armed.
6. **`checkpoint-guard recapture win95`** (both captures): byte-copy backup
   hashed with the guest stopped, capture under `cpg-staging`, restore proven
   on the framebuffer with the guest RUNNING, then promoted to `golden`. One
   station-specific wrinkle: the guard's dirty-probe (typed text) does not
   move this guest's framebuffer with desktop focus — focus the ICQ panel's
   *Enter Search Keyword* box first so typed characters land visibly (the
   fleet-wide no-blink caret keeps the reference idle-deterministic).
7. **Acceptance** (the production path, measured): idle-paused until the
   gateway dropped `95000` (confirmed by two samples 30 s apart), then
   `labctl reset win95` at 14:41:46Z. On the wire: the client's keepalive ping
   fired on the stale socket at **t+42 s** (`17:42:28.088` 6-byte push on port
   1042), the gateway answered **RST**, and **395 ms later** the client opened
   fresh connections (port 1043 SYN, 136-byte OSCAR auth). Gateway:
   `presence: 95000 ONLINE` at 17:42:28, fresh session. Bot: `GREETED 95000`
   at 17:42:58, and the greeting auto-popped on the framebuffer with **no
   password prompt** — silent, nudge-free, through the exact path a visitor
   wake takes.
8. `registry/stations/win95.json` `retronet.planes = ["web","icq"]` and the
   `roster.json` row (`client: icq2000b`, `onboarded: true`) flipped in the
   same push.

## Gotchas this station charges you for

- **A fresh 2000b install must go into an empty `C:\Program Files\ICQ`.** Move
  any prior ICQ tree aside first so 2000b's OSCAR DLLs register against a clean
  slate — this is the likely difference between "signs in" and the historical
  "zero packets."
- **The dirty-database trap still applies.** An ungraceful ICQ exit can leave a
  `95000tmp.dat`/`.idx` pair beside `95000.dat`; ICQ then hangs on its splash.
  Shut ICQ down from its own menu / let Windows close it gracefully, and if a DB
  goes dirty clear `95000*.*` (keeping only a clean `95000.dat`/`.idx`) offline
  via `qemu-nbd`.
- **The station idle-pauses within seconds; a paused vCPU reacts to nothing.**
  `labctl` / `scripts/dev/qmp-type.py` wake it and hold a lease; `checkpoint-guard`
  holds the wake lease across a recapture. `systemctl stop streamhost@win95` is a
  power cut (re-poisons the DB); shut Windows down first.
- **The S3/VBE display wedges into a striped band after a `COMMAND.COM` VDM /
  the ICQ splash sequence.** It is cosmetic; recover over the wire with the
  warpnet `V` verb (`printf 'V\n' | nc 10.99.0.13 7788`) and always `labctl shot`
  a clean frame before any capture.
- **`labctl key` chords do not reach this guest;** send chords through QMP
  `send-key`. Single keys work.
- **Never launch a long-lived program through the exec channel** (`labctl exec`
  runs `cmd /c … >C:\WNEXEC.OUT`; a child that outlives the call wedges every
  later exec). Launch ICQ from the framebuffer / startup.

## Disposition — golden lineage & rollback (FULL paths)

- **LIVE golden:** internal snapshot `golden` (2026-08-24, second capture — the
  keep-alive-armed one) in
  `/data/vms/streamhost/stations/win95/win95-golden.qcow2` — clean 1280×1024
  desktop, **ICQ 2000b build 3281 signed in as `95000`** (Simple Mode, roster
  by name, *Keep connection alive* ON, Server Host `10.99.0.2:5190`, saved
  password), IE 4.01 with the corpus home page. Captured and restore-proven by
  `checkpoint-guard`; `labctl reset win95` = `loadvm golden`.
- **checkpoint-guard backups of that disk** (hashed with the guest stopped):
  `/data/vms/streamhost/stations/win95/win95-golden.qcow2.cpg-bak-20260824T140841Z`
  (pre-first-capture) and `….cpg-bak-20260824T143557Z` (pre-recapture);
  `checkpoint-guard prune win95` removes them once the operator is content.
- **2002a rollback — RETAINED deliberately** (QEMU stopped, SHA256-verified):
  `/data/gallery-guests/Win95/golden-backup-ie401-icq2002a-keepalive-20260824/win95-golden.qcow2`
  (`bc4490d831d833d2e6e96ca4d752ca4320c64d831f1cd02d7ff984c3104b98db`).
  Restoring it (with `streamhost@win95` stopped) undoes the whole 2000b swap in
  one copy. Do not prune this one.
- Older rollbacks: `golden-backup-ie401-icq2002a-20260824/` (2002a, keep-alive
  OFF), `golden-backup-preicq2001b-20260823/` (IE 3.01, no ICQ).

## Media

`icq2000b.exe` — ICQ 2000b build **3281**, sha256
`9d5574cea30a8a0353d815555c59d589189b0fb98d9de63e74d908c16de3e11f`, the same
blob win98se uses (recorded in [`../ASSETS-MANIFEST.md`](../ASSETS-MANIFEST.md)
§`icq2000b.exe`); found in the media archive at
`blobs/9d/9d5574cea30a8a03…`. The period SysInternals **Filemon** (2000-12) and
**Regmon** (2000-11) builds were sourced from the Wayback capture of
`sysinternals.com/files/` and staged into the guest's `C:\TOOLS` for the planned
in-guest API trace, but the packet capture answered the question outright (the
client's own DNS + SYN + full OSCAR handshake settled "does it dial out"), so the
in-guest trace was **not run**. Both tools remain available for any follow-up.
Facts only, **never committed**.

## Operating it

```bash
ssh lab 'labctl exec win95 "ver"'                                   # Windows 95. [Version 4.00.1111]
ssh lab 'labctl exec win95 "route print"'                           # no default route == contained
# server-side: is the persona online, and did the bot greet?
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
ssh lab 'journalctl -u retronet-bot -n 40 --no-pager | grep 95000'
ssh lab 'labctl reset win95'                                        # loadvm golden
```
