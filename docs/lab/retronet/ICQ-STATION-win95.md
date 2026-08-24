# win95 ICQ — ICQ 2000b signs in AND reconnects nudge-free

**Status: the client question is SOLVED, and the earlier verdict was wrong.**
Driven on a contained clone of the live golden, **ICQ 2000b build 3281** on
`win95` dials out, signs **UIN `95000`** into the retronet OSCAR gateway, draws
its roster by name, is greeted by HiveBot, and — with *Keep connection alive*
ON — **reconnects on its own across a reset, with no nudge.** Every claim on
this page was measured with `tcpdump` on the host side of the guest's tap, the
gateway's own session API, the greeter-bot journal, and the framebuffer;
timestamps and ports are quoted so the capture can be re-read.

This overturns the two findings this doc used to carry — that 2000b *"never
reaches `connect()`, emits zero packets"* and that the only workable client
(2002a) *"ignores even a gateway RST and never reconnects."* Both were true of
the states they were measured in; **neither is true of a clean 2000b install on
this guest's current software stack.**

> **Live-station state (unchanged by this investigation).** The listed `win95`
> station still runs **ICQ 2002a** on `retronet.planes = ["web"]`,
> `roster.json` `onboarded: false`. This pass ran entirely on a **byte-for-byte
> clone** of the live golden (own tap `w95icq0`, own MAC, DHCP-pool lease
> `10.99.0.100`, own `W95ICQ-IN` guard chain) and **did not touch the live
> exhibit**. Switching the station to 2000b — the recommended action — is the
> operator-go step in *§Recommended action* below; the tested recipe and the
> ready-to-promote clone disk are named there.

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

### 2000b reconnects across a reset — NO nudge — the load-bearing result

*Keep connection alive* is reached the normal way in 2000b (unlike 2002a, whose
Preferences were unreachable): **ICQ menu → Preferences → Connections → Server
tab → tick *Keep connection alive***. The same page sets **Host `10.99.0.2`,
Port `5190`** (deterministic; the DNS hijack would carry `login.icq.com` anyway).
A Disconnect→Reconnect applies it and is **silent** (Auto Save Password on).

The reset was reproduced faithfully — `loadvm` of a checkpoint captured with
2000b online, then the gateway's session for `95000` dropped so the restored
guest holds a socket the gateway no longer has (exactly the state `labctl reset`
= `loadvm golden` produces after the fleet's idle-pause has let the gateway time
the frozen session out). **Reproduced twice, identically:**

```
# cycle 2 — reset2.pcap
16:23:21  10.99.0.2.5190   > 10.99.0.100.1048: Flags [R.]   (gateway RSTs the stale socket)
16:23:33  10.99.0.100.1048 > 10.99.0.2.5190:  Flags [R]     (guest tears its dead socket down)
16:23:42  10.99.0.100.1047 > 10.99.0.2.5190:  Flags [S]     (fresh reconnect — auth)
16:23:42  10.99.0.100.1048 > 10.99.0.2.5190:  Flags [S]     (fresh reconnect — BOS)
```

The gateway then reports `presence: 95000 ONLINE`, a **fresh source port** and
`online_seconds` in the tens (session API), and **HiveBot greets the fresh
arrival**. The client panel shows *Online* with HiveBot in the roster and **no
password prompt** — the reconnect is silent. The ~9 s between resume and the new
SYN is the *Keep connection alive* probe interval detecting the dead 4-tuple.

**This is the exact mechanism the fleet attributed only to 2001b, and the exact
event a `*-icq-nudge` manufactures.** The historical need for a `win95-icq-nudge`
(and the win98se/win2000 2000b nudges) is therefore best read as compensating
for *Keep connection alive being OFF* on those 2000b stations, not for an
intrinsic 2000b limitation. **No nudge is built or needed here** — the client's
own keepalive is the healer.

> **UNVERIFIED:** the literal production path `labctl reset win95` on the **live
> station golden** has not been run — this pass proved reconnect on a clone via
> `loadvm` + gateway-session-drop, which is the same operation (`loadvm golden`)
> on the same software, but not the live disk. That one check is the acceptance
> gate for the operator-go switch below.

## Recommended action — switch the live station to 2000b (operator-go)

The evidence supports replacing 2002a with 2000b: 2000b signs in *and* survives
a reset nudge-free, which 2002a does not. Because this overturns prior
conclusions and mutates a live exhibit, the switch is left for operator go.

The re-bake must use the guard, never the hand-typed `savevm golden-new`
(AGENTS.md; `docs/lab/checkpoint-guard.md`):

1. **Promote the staged clone disk.** `/data/vms/sandbox/win95-icq2000b/rig/
   w95clone.qcow2` is a byte-copy of the live golden with 2000b installed,
   *Keep connection alive* ON, Host `10.99.0.2`, Simple Mode, saved password.
   Its internal snapshots (`preicq`, `goldcand`) must be deleted and its tooling
   (`C:\TOOLS`, `ICQ200*.EXE`, `ICQ2002A.SAV`) removed before it becomes the
   station disk, and it must be cold-booted **once** with the live `RN_WIN95_MAC`
   so the MAC bakes correctly (a cold boot, because MAC lives in vmstate).
   *(Alternatively, install 2000b fresh on the live golden with the recipe this
   page's history section describes — cleaner exhibit disk, more framebuffer
   work.)*
2. Cold-boot the live station off that disk; 2000b auto-launches (*Launch ICQ on
   startup* ON) and signs `95000` in on `10.99.0.13`.
3. Prove sign-in on the framebuffer, then `checkpoint-guard recapture win95`.
4. **The acceptance gate:** idle-pause until `95000` disappears from the gateway
   session list, then `labctl reset win95`, and prove the **silent, nudge-free**
   reconnect (fresh source port, low `online_seconds`, roster by name, HiveBot
   greeting) — exactly as reproduced on the clone above.
5. **Only if that passes:** in one push set `registry/stations/win95.json`
   `retronet.planes = ["web","icq"]` **and** flip the `roster.json` `95000` row
   to `onboarded: true` (the gate fails unless both move together); a final
   commit touches only the wave log.
6. Rollback if anything regresses: the 2002a golden is preserved byte-for-byte
   and SHA256-verified (paths in *§Disposition*); `checkpoint-guard rollback
   win95` puts it back.

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

- **LIVE golden (unchanged):** internal snapshot `golden` in
  `/data/vms/streamhost/stations/win95/win95-golden.qcow2` — **ICQ 2002a signed
  in as `95000`**, IE 4.01, clean 1280×1024. `labctl reset win95` = `loadvm
  golden`. See [`WEB-STATION-win95.md`](WEB-STATION-win95.md) for the web plane.
- **Byte-copy backup of the live golden** (QEMU stopped, SHA256-verified):
  `/data/gallery-guests/Win95/golden-backup-ie401-icq2002a-keepalive-20260824/win95-golden.qcow2`
  (`bc4490d831d833d2e6e96ca4d752ca4320c64d831f1cd02d7ff984c3104b98db`). This is
  the rollback for the 2000b switch.
- **Staged 2000b disk (ready to promote):**
  `/data/vms/sandbox/win95-icq2000b/rig/w95clone.qcow2` — the byte-copy clone
  this pass built and proved on. Not a station golden until re-baked as above.
- Older rollbacks: `golden-backup-ie401-icq2002a-20260824/` (2002a, keep-alive
  OFF), `golden-backup-preicq2001b-20260823/` (IE 3.01, no ICQ).

## Media

`icq2000b.exe` — ICQ 2000b build **3281**, sha256
`9d5574cea30a8a0353d815555c59d589189b0fb98d9de63e74d908c16de3e11f`, the same
blob win98se uses (recorded in [`../ASSETS-MANIFEST.md`](../ASSETS-MANIFEST.md)
§`icq2000b.exe`); found in the media archive at
`blobs/9d/9d5574cea30a8a03…`. In-guest API tracing used the period SysInternals
**Filemon** (2000-12) and **Regmon** (2000-11) builds, sourced from the Wayback
capture of `sysinternals.com/files/` — facts only, **never committed**.

## Operating it

```bash
ssh lab 'labctl exec win95 "ver"'                                   # Windows 95. [Version 4.00.1111]
ssh lab 'labctl exec win95 "route print"'                           # no default route == contained
# server-side: is the persona online, and did the bot greet?
ssh lab 'pct exec 951 -- python3 -c "import urllib.request,json;print([s[\"screen_name\"] for s in json.loads(urllib.request.urlopen(\"http://127.0.0.1:8080/session\").read())[\"sessions\"]])"'
ssh lab 'journalctl -u retronet-bot -n 40 --no-pager | grep 95000'
ssh lab 'labctl reset win95'                                        # loadvm golden
```
