# Debugging a streaming complaint

**Start here when the operator says a station "froze", "went blurry", "got
laggy", "stopped", or "dropped quality".** This is the runbook: where the
evidence already is, how to read it, and the failure signatures we have seen.

You almost never need to reproduce a streaming bug. The client records its own
state continuously and ships it to the box, so the evidence for a complaint that
happened an hour ago is usually already on disk.

---

## 1. The places evidence lives

| Plane | Where | Covers |
|---|---|---|
| **Log plane** | `lab:/data/vms/streamhost/serve/logs.db`, or `POST /auth/logs/search` | Every producer's records — browser, serving plane, station daemon — with severity and, where a span was open, `traceId`/`spanId`. 7 days. |
| **Client telemetry** | `lab:/data/vms/streamhost/serve/clientlog.jsonl` | The same browser events as the log plane, as flat JSONL. Rolling ~36 h. **Being retired** — see §1.1. |
| **Station daemon** | `ssh lab 'journalctl -u streamhost@<station>'` | Everything the daemon printed. The subset at WARN and above is also in the log plane, correlated. |
| **Live overlay** | the SPA, **Ctrl/Cmd+N** | The same client state as the log, live. Ask the operator for a screenshot. |

**The client plane is the one people forget, and it is usually the decisive
one.** The server cannot see most of what the browser knows (§3).

### 1.1 Start here now: the log plane, and the pivot

The instruction that used to open this document — *start with
`clientlog.jsonl`, not a repro* — is still right about where to start and wrong
about the file. The same events now land in `logs.db` **carrying the trace
context that was open when they happened**, which turns the two questions this
document exists to answer into one query each:

```sh
# "What did EVERY plane say during this trace?" — the pivot. `id` is the trace
# id from a slow span, or off the `traceresponse` header of the request itself.
ssh lab 'curl -sk -X POST https://127.0.0.1:8443/auth/logs/trace \
  -H "Content-Type: application/json" -H "Cookie: osg_session=$TOK" \
  -d "{\"id\":\"<trace id>\"}"'

# "What went wrong for anybody in the last hour?" — severity is a RANGE.
#   {"minSeverity":"WARN","sinceMs":<now-3600000>,"limit":200}
# Filter further with service (kernel-hive-spa | -serve | -daemon), instance
# (the station or the box), session, build, traceId, or `contains` on the body.
```

Reads are **admin-only** and live under `/auth/logs/*`, exactly like
`/auth/traces/*`; ingest is open, so a visitor can report the error that broke
their visit without holding an admin session. Straight SQL against
`/data/vms/streamhost/serve/logs.db` works too and is often faster to iterate
on — the schema is in `scripts/serve/logs_schema.py`.

The reverse direction is the one that was impossible before: take a
`traceId` out of a log row, open it in `/admin/observability`, and read the
flame graph the record was emitted inside.

**What is NOT here yet**, so you know when to fall back to the file: the
pre-bundle bootstrap error handler in `spa/index.html` still posts only to
`/clientlog` (it runs before any module loads and has no span to name), and
`clientlog.jsonl` is still being written in parallel for one deploy. Until both
are settled, a client error from the very first moments of a page load is in the
file and not in the store.

---

## 2. Client telemetry: `clientlog.jsonl` (being retired)

**This file is on its way out.** Everything below is still true and still works;
it is documented because the file is still written and still holds the ~36 hours
before the log plane landed. New investigations should start at §1.1 — the same
events, with severity and a trace id, and a query surface that is not `grep`.

Written by `POST /clientlog` in `scripts/serve/osgallery-https-server.py`.
Untokened, and open to **every** session — on the public listener the visitor's
own sign-in authorizes it, on LAN it is simply open. No operator setup is
involved anywhere. One JSON object per line:

| Field | Meaning |
|---|---|
| **`clientTs`** | **Millisecond epoch, stamped in the BROWSER at the moment the event happened** (`logClientEvent`, `clientDebug.ts`). **Use this for every timing question.** |
| `srvTs` | Server receive time, epoch *seconds*. This is when the BATCH arrived, not when the event happened. |
| `ip`, `sessionId`, `tile`, `event`, `detail` | Source, 8-hex per page load, station id, event name, payload. |
| `ua`, `build` | The user agent and the **bundle the tab is running** (`<branch>@<short-sha>`), both on the **first event of a batch only**. `build` is what answers "is this session even running the code I am reading?" — see [`docs/ANALYTICS.md`](../ANALYTICS.md) §8.3. |

**Timing must be read from `clientTs`, never from `srvTs`.** Events are batched
and flushed every ~5 s, so a whole batch shares one `srvTs` — sorting or
measuring on it quantises everything to the flush cadence and makes sub-5 s
intervals vanish. `clientTs` has none of that: it is per-event and
millisecond-accurate, and two events in the same flush routinely sit seconds
apart. (Measuring reconnects on `srvTs` is exactly how a 2026-08-23 session
talked itself into "sub-5 s timing is not recoverable from this log". It is.)

The one thing `srvTs` is authoritative for is **retention**, which prunes on it.

### Every session logs from its first moment

`session-start` is the first row of every session, written when the SPA boots —
before a station is chosen, before signaling, before anything can fail. Its
`detail` is a capability probe (`wt`, `vd`, `rtc`, `secure`, `sw`, `net`,
`href`), which is usually enough on its own to explain an early failure.
`station-open` follows when a station page opens, with the same probe.

**This is the fix for the session that logged nothing.** Every telemetry call
used to hang off the stream effect, so a tab that never started a stream — a
manifest that did not load, a non-streamable binding, a visitor sitting on the
grid — emitted NOTHING, for as long as they sat there. Worse, the `/clientcmd`
poller started in the same place, so that tab could not be reached by an
operator command either: **invisible and unreachable at the same time.** The
poller now belongs to the tab, not to the station, and keeps running after a
station closes.

The give-up path is logged too. `connect-retry` carries each attempt and its
reason; `connect-giveup` is written when the session falls back to the poster;
`connect-stalled` is written when the WebTransport handshake has not settled
after 3 s, which is what a network that silently blackholes QUIC looks like from
the browser. All three used to exist only in the *visitor's* console — the one
place an operator can never look.

So a broken session now reads end to end:

```
session-start   {"tile":"","wt":true,"vd":true,"secure":true,...}
station-open    {"tile":"win95",...}
connect-retry   attempt=1/4 live=false why=connect: WebTransportError: ...
connect-giveup  timed out negotiating tile stream (poster fallback) attempts=4
```

`clientcmd.sh sessions` derives from this file, not from who is polling, and
prints a STATE column (`live`, `retrying`, `STALLED`, `FAILED`, `no-station`),
so a session that never managed to stream is listed rather than absent.

**Retention is a rolling window pruned by age** — `CLIENTLOG_RETENTION_SECS`
(default 36 h), with `CLIENTLOG_MAX` (64 MiB) only as a runaway backstop. Rows
that cannot be dated are never pruned.

### The `stats` event — the one you want

Emitted **every 5 s by every live session**, carrying the full Ctrl+N overlay
state. Built by `formatStatsLine` in `spa/src/three/streamClient/telemetry.ts`.
Because `clientDebug` flushes on `pagehide`/`visibilitychange` with a keepalive
fetch, **the last sample before a session dies still reaches disk** — that is
what makes a post-mortem of a freeze possible at all.

```
T0/crf10 1024x768@30 rx1.8M fps30 dec2.1/q0 rtt12.4/fl10.3/ex2
rttpk27@2396ms/br0 loss0.0/w0.0n82 pk33n6! dr2/40pm fz0/0pm
tier2ch path0→1→0 age18s good avc err1 rb1 STALLED
```

| Field | Meaning |
|---|---|
| `T0/crf10` | ABR tier and CRF. T0 best, T3 floor. |
| `1024x768@30` | Encoded geometry and fps cap. A drop here is a real resolution step (tier 3). |
| `rx1.8M` | Received video bitrate, Mbps. **`rx0.0M` with `fps0` = the stream is dead.** |
| `dec2.1/q0` | Decode ms per frame / decoder queue depth. |
| `rtt12.4/fl10.3/ex2` | RTT / learned path floor / **excess over floor**. The server decides on `ex`, threshold 80 ms. |
| `rttpk27@2396ms/br0` | Worst raw RTT in the 3 s window, its age, and **ticks over the 80 ms threshold**. Catches bursts an instantaneous reading misses. |
| `loss0.0/w0.0n82` | Instantaneous loss % / 3 s-window loss % / **frames the window figure came from**. |
| `pk33n6!` | Worst single-tick loss and its sample size. **A trailing `!` means the percentage is untrustworthy** — over the 5 % downshift threshold but computed from <10 frames. |
| `dr2/40pm` `fz0/0pm` | Cumulative drops/freezes and their per-minute rates. |
| `tier2ch path0→1→0 age18s` | Tier changes in 5 min, the trajectory, and age of the last one. **A long `path` is flapping, not adapting.** |
| trailing words | banner state, decode path (`avc`/`annexb`), `errN` decoder errors, `rbN` session rebuilds, `STALLED`. |

### Querying it

```bash
ssh lab 'python3 - <<EOF
import json, datetime
for line in open("/data/vms/streamhost/serve/clientlog.jsonl", errors="replace"):
    try: d = json.loads(line)
    except: continue
    if d.get("tile") != "win311": continue           # <- station
    ts = d.get("clientTs")                           # ms epoch, per EVENT
    if ts is None or ts < 1786968600_000: continue   # <- ms cutoff
    print(datetime.datetime.fromtimestamp(ts / 1000).strftime("%H:%M:%S.%f")[:-3],
          d.get("sessionId"), d.get("event"), "|", str(d.get("detail"))[:200])
EOF'
```

Sort on `clientTs` too — a batch is appended in flush order, which is not
necessarily event order across sessions.

Other events: `connect`, `wt-close` (carries the exit reason), `stall`,
`decoder-config`, `decoder-error`, `drag-tel`, `ptr`, `client-error`.

### Measuring a reconnect

Time-to-recover is `clientTs` of the first `stats` line with `fps>0` minus
`clientTs` of the preceding `wt-close`. Over the stats era that baseline is
**n=61, p50 6.6 s, p90 36 s, max 56 s** — and the cost is dominated by how long
the client takes to *notice*, not by the re-handshake. Exclude samples spanning
a long absence (say > 120 s): those measure how long the tab was away, not how
long recovery took.

---

## 3. What the server does NOT know

The station daemon's only client feed is the 29-byte `T_STATS` datagram at
10 Hz (`streamhost/streamhost/src/abr.rs`, `parse_report`): rtt, recv_kbps, the
decode counters, frames_dropped, freeze_count, loss_pct, last_frame_id.

**Everything else in the overlay is derived in the browser and exists only in
`clientlog.jsonl`**: loss peaks with their sample sizes, RTT peak/floor/excess,
breach ticks, drop and freeze rates, tier history, decoder errors, banner state.
If you are trying to answer "why did the tier drop" purely from journald, you
are missing half the picture.

---

## 4. Station daemon log

```bash
ssh lab 'journalctl -u streamhost@<station> --since "-1 hour" --no-pager | grep -vE "input-tel|input-router|enc latency"'
```

Filtering out `input-tel`/`input-router`/`enc latency` is essential — they are
per-second and drown everything else.

| Grep for | Meaning |
|---|---|
| `[abr] DOWN why=` | **A quality drop, and the metric that caused it**: `why=loss/backlog` or `why=rtt`, with the loss %, rtt excess, skip rate and session count. |
| `[abr] UP` | A quality recovery, same metrics. |
| `[abr] tier N -> M (restart)` | The change itself. |
| `[encode] geometry ... tier=N -> out WxH crf=C maxrate=Mk` | What the encoder actually reconfigured to. |
| `SESSION_ACCEPTED` / `SESSION_ENDED` | Session lifecycle. Count them: accepted minus ended = live sessions. |
| `[idle] no sessions for 60s -> guest paused` | Idle auto-pause. **Only fires with zero sessions** — if a guest paused "while in use", the session died first; that is the bug, not the pause. |
| `[idle] session connected -> guest resumed` | Resume on reconnect. |
| `LISTENING udp/<port> tile=<id>` | Startup readiness line. |

---

## 5. Known failure signatures

### Quality collapses on a healthy link
Overlay/log shows a long `path` (`0→1→2→3→0`) with changes ~25 s apart — 25 s is
`SH_ABR_MIN_RESTART_MS`, so every transition sitting exactly on the dwell means
the controller wants to move *continuously*: a limit cycle, not adaptation.
Two causes, both fixed 2026-08-17 (see `abr.rs`), both worth re-checking:

- **`pk…n…!` flag set** — loss quantisation. On a low-fps station a 100 ms
  window holds 0–1 frames, so one dropped frame reads as 100 % loss. Loss is now
  measured over 3 s and reported as zero under 10 frames.
- **`rttpk` large with `br` > 0 while `rtt`/`ex` look fine** — self-inflicted
  RTT. The RTT ping shares the QUIC connection with the video and queues behind
  a keyframe; tier 0 has no bitrate ceiling (CQP, no VBV), so a big station's
  heartbeat IDR spikes the ping. RTT smoothing is now asymmetric (rise m=16,
  fall m=4) and an RTT-only breach must persist 4 s, not 1.5 s.

### Station "freezes" while in use
Look for `rx0.0M fps0` in consecutive `stats` rows with healthy `rtt` and zero
loss. If it starts right after an `[abr] tier` change, the reconfig wedged the
stream. The client eventually gives up (`dropStaleSession`) and reconnects,
which the operator sees as a freeze-then-recover.

### The tab came back and the picture stayed black
The complaint is "I resume the session, a Reconnecting screen shows, it goes
away, and the video area stays black".

**Ask first whether the `<video>` element is PAUSED.** Not whether the transport
is up, not what the retry loop is doing — those are the questions that cost a
day. A paused element decodes nothing, so a perfectly healthy stream produces a
black rectangle, `fps0`, `dec0.0` and `rx0.0M`, and the client's own keyframe
watchdog then blames the transport for a fault that is entirely on this side of
the wire. The client-debug plane answers it directly, on the visitor's real tab:

```bash
scripts/serve/clientcmd.sh sessions
scripts/serve/clientcmd.sh eval <session> \
  'const v=document.querySelector("video");return {vis:document.visibilityState,
   paused:v.paused,rs:v.readyState,w:v.videoWidth,ct:v.currentTime,err:v.error}'
scripts/serve/clientcmd.sh evallog <session>   # reassembles the result
```

**The eval code runs inside an async function body** (`clientDebug.ts` wraps it
in `(async () => { <code> })()`), so it MUST end with an explicit top-level
`return <value>` — a bare trailing expression, or an IIFE as the last
statement, evaluates fine and then delivers `"[Undefined]"`, which reads like
a broken tab when it is only a missing `return`. `await` is available; objects
are serialized safely, no need to `JSON.stringify` yourself. The result comes
back through telemetry — read it with `evallog`, and remember delivery needs
the tab to be foreground and its network alive (Mode D below is the shape
where a `live`-listed session never answers).

**`paused: true` on a `visible` page, `readyState 4`, a correct `videoWidth`, no
`error`, and `fps0` is a PAUSED SINK, not a broken stream.** That exact reading
came off the operator's own tab on 2026-08-24 (rhapsody, Chrome 151 Android,
installed PWA). A single `await v.play()` fixed it and the media clock jumped
655 s straight to the live edge — the transport, decoder and encoder had been
healthy the whole time.

The rest of this section is the older, transport-side shapes. Rule out the
paused sink before you read them.

**Recognise the transport-side shapes from one grep** — find the telemetry
silence gap, then look at what the client did on the far side of it:

```bash
ssh lab "grep -c '\"tile\": \"\"' /data/vms/streamhost/serve/clientlog.jsonl"
```

**An empty `tile` on a `connect` is a 100 % predictor of a black stream** — 0 of
14 such sessions ever decoded a frame. It is not a logging cosmetic; it is the
fingerprint of two overlapping mounts of the same station, where the outgoing
one's cleanup wiped the tag the incoming one had just claimed. If the tag is
gone, so is the guarantee that the canvas is wired to the transport that opened.

Backgrounding a tab throttles the client's 100 ms tick to ~1/min and freezes it
outright in an installed PWA, so **nothing that normally notices a dead session
runs while the tab is away**. Several shapes come out of that, and they need
different fixes (A–C below are fixed; D is open):

| | **Mode A — no reconnect at all** | **Mode B — reconnect storm** | **Mode C — paused sink** |
|---|---|---|---|
| Signature | a burst of `T-/crf- -x-@-` banner-state `stats` lines inside ~1 s, then **nothing** | many `connect` lines, **no `wt-close` between them**, `tile` empty, a different codec each attempt | `connect-retry … why=no keyframe within budget` repeating on a transport that never failed; `sink-stalled` rows |
| Cause | the frozen 5 s stats timer flushing its backlog on wake; no code path drives a reconnect from the resume event | attempts never serialised — up to 12 WebTransports open at once; the retry timer closes whichever handle it last held | Chrome-Android paused the `<video>` when the PWA was backgrounded and nothing resumed it on return |
| Also emits | — | `connect failed: WebTransportError: close() is called while connecting` | `attempt=5/4`, `6/4`, `7/4` — a retry ladder chasing a fault that is not on the wire |

The banner clears in all three because the transport layer reports *something*;
the picture stays black because nothing is painting into it — in A and B because
nothing is *arriving*, in C because nothing is being *consumed*. Those two want
opposite responses, which is why the client now logs which one it is
(`streamClient/videoResume.ts`): `sink-resumed` carries the live-edge jump,
`sink-blocked` means autoplay policy refused and the visitor was shown a **Tap to
resume** affordance, and `sink-stalled` means the keyframe watchdog declined to
tear down a healthy transport because the sink was the thing that had stopped.

All three are fixed client-side. A and B in `useStreamhostSession.ts`:
`visibilitychange`/`pageshow` drive an immediate reconnect after a short grace
window instead of waiting on a watchdog; `startAttempt` tears down any attempt
still in flight so exactly one exists; and `clearDebugTile` is guarded by an
ownership token so a stale unmount cannot blank the tag. C in
`StreamView/useStreamSession.ts`, which resumes the element on every way back to
the foreground — `visibilitychange`, `pageshow`, the Page-Lifecycle `resume`
event a frozen PWA thaws on, `focus`, and the element's own `pause` event — and
resumes it **at the live edge**, so a returning visitor sees now, never eleven
minutes of history.

**Mode D — the page is healthy but its whole network plane is dead** (OPEN;
2026-08-25, the operator's own installed PWA, Chrome 151 Android, win98se).
Seen after an app switch long enough to freeze the PWA and idle-pause the
guest. On thaw everything above WORKED: the sink resumed, signaling was
fetched, the daemon accepted a fresh WT session, resumed the guest and primed
a keyframe — and then not one video byte reached the decoder. Every later
attempt failed too, the live ladder burnt its 6 attempts and correctly parked
on `phase error` ("lost the connection to this tile — tap Reconnect"). The
page stayed fully interactive the whole time — the StageMenu opened and
rendered the right banner; a screenshot of that menu is what disproved the
renderer-hang theory this shape invites. The stage behind the banner was
BLACK, not the last frame: the canvas backing had been discarded during the
freeze. Marks that name this shape:

- **telemetry goes silent while the page lives on.** `flushNow()` slices the
  batch out of `pending` BEFORE the POST, so a failed flush drops its events —
  a network-outage window is invisible in `clientlog.jsonl` by construction.
  The last rows are ordinary `stats`; no giveup, no `wt-close`, nothing.
- `clientcmd.sh sessions` keeps answering `live` for 30 min
  (`SESSION_ACTIVE_SECS`) and queued evals never execute — the command
  poller's fetches are failing with everything else. An eval that does not
  come back from a session marked `live` is this shape until proven otherwise.
- the daemon side records a ghost: SESSION_ACCEPTED → guest resumed → encoder
  reconfigured → SESSION_ENDED ~45 s later, zero consumption in between.

Whether the outage was the phone's network path (VPN/5G rebind after doze) or
Chrome wedging the page's network context on thaw is not distinguishable from
the box; a Reload built a session that connected instantly, so nothing durable
was broken. What this shape still wants, none of it built yet: an error-phase
recovery probe (after ladder exhaustion, re-probe signaling every ~20 s and
restart the ladder on success — the visitor should never have to find the
button), the poster instead of black behind the banner, and re-queueing
telemetry batches on failed POST so the outage prints its own shape in the log.

**Retry budgets are finite on both ladders** (`streamClient/retryBudget.ts`). A
log line reading `attempt=5/4` was the old code: the budget was checked only
before the first paint, so a station that had already painted retried forever,
never terminated and never escalated. A cold connect now gets 4 attempts then
falls back to the poster; a proven-live session gets 6 then shows a working
**Reconnect** button. An attempt number above its own limit is a bug, not a
reading.

Reproduce and prove any of this in a real browser with
`scripts/e2e/paused-sink-resume-probe.mjs` — it pauses the element while the
page is hidden (where a pause is correct), returns to the foreground, and counts
DISTINCT decoded frames. **Motion is the only proof**: `videoWidth`,
`readyState` and a non-black percentage all pass on a paused element showing a
stale frame.

**A reconnect is judged on a different clock than a first connect.** A cold
connect keeps the 12 s keyframe budget — an idle station legitimately takes a
while to produce frame #1. Once a station has painted it is marked *warm*, and
the budget drops to 3 s: the daemon forces an IDR on subscribe on top of priming
its freshest cached key (`transport/mod.rs`), so a warm reconnect that has not
painted in 3 s is broken, not slow.

### The decoder is silent and rebuilding it changes nothing
`stall | decoder rebuild (silent stall: AUs arriving, no output)` repeating every
5 s, with healthy transport underneath — the giveaway is a `stats` line like
`rx11.5M fps2 ... rtt3.3/fl2.5/ex0`: **11.5 Mbps of access units arriving and
almost nothing decoding.** Rare (about 1 % of `fps0` samples also have `rx>0`)
but terminal when it happens.

The rebuild used to be a **byte-identical no-op**: 123 of 124 field rebuilds
re-created the exact same codec string, avcC descriptor length and hardware
preference, so a wedged decoder looped until the session died black. The one
recorded recovery came only when an ABR tier drop forced a genuinely *new*
encoder config. Two consequences now in the client:

- a rebuild **demotes to software decode**, and the demotion is
  page-lifetime (`softwareDecodeLatch.ts`) — `hwDecodeOk`/`hwFellBack` are
  per-`StreamClient`, so before this every reconnect built a fresh client that
  probed `prefer-hardware` again and reproduced the identical stall;
- rebuilds are **bounded** (`MAX_SILENT_STALL_REBUILDS`). Beyond the cap the
  session is left to `dropStaleSession`, which correctly refuses to act while the
  page is hidden — that is why a hidden tab could burn 10 rebuilds over 65 s.

### `frame watchdog latched` is mostly NOT a fault
1610 latches in a 427 h window, and **62 % of them fire more than 5 minutes
after the last `connect`; only 5 % land within 15 s of one.** They cluster on the
static-screen low-fps stations (`dbr-arma`, `mpf2`, `atarist`, `c64`) because
`FRAME_STALL_MS` (2000) is simply below the natural inter-frame interval of a
still desktop. **74 % of latches are followed by a session that keeps running
normally.** Do not chase a latch on its own — it is a detector, not a verdict.
Chase it only when it is paired with `rx>0` (the silent-stall signature above)
or with a session that then dies.

### Reconnect detection latency dominates, not the network
Measured on `clientTs`, `wt-close` → first `stats` with `fps>0`, excluding
samples spanning a background absence: **n=61, p50 6.6 s, p90 36 s, max 56 s.**
Almost all of that is the client deciding the session is dead, not the QUIC
re-handshake. By exit reason (p50):

| `wt-close` reason | n | p50 |
|---|---|---|
| `connect failed: …` | 34 | 6.6 s |
| `ping-timeout: tile stopped responding to liveness pings` | 26 | 5.8 s |
| `transport error: WebTransportError: Connection lost` | 4 | 7.0 s |

The **resume fast path only pre-empts the detection latency of a session that
died while the tab was AWAY.** A `ping-timeout` on a tab that stayed visible
still costs its full detection time and is untouched by it — an observed
post-fix Android sample took 10.8 s that way. If that path matters, it is a
separate fix (the ping budget is 3 consecutive 600 ms timeouts, so ~1.8 s is the
floor it should be approaching, not 10 s).

`TypeError: Failed to fetch` arriving in a batch of 4–5 identical lines within
the same millisecond, after a telemetry silence gap, is the reliable
**"this machine just woke up"** marker.

### Guest paused mid-session
Check `SESSION_ENDED` *before* the `[idle]` pause line. The pause is correct
behaviour 60 s after the last session ends; the real question is why the session
ended. `wt-close` in `clientlog.jsonl` carries the reason when the client got to
report it.

---

## 6. Deploy and promotion gotchas

- **`serve-https-spa.sh deploy` republishes the runtime manifests** from the
  registry and **silently wipes dark-launch overlays**. Check
  `ssh lab 'ls /data/vms/streamhost/serve/darklaunch.d/'` first; re-run each
  declaration's `owner` script with `publish` afterwards. A clean gate reads
  `N MATCH, k DARKLAUNCH, 0 need attention`.
- **`build-deploy.sh --promote`** enumerates only `--state=active` units, so a
  deliberately-off station (sailfishos is off by intent) cannot abort a wave,
  and rejects ids containing `@` so malformed double-instance units
  (`streamhost@streamhost@<tile>`) can never be targeted.
- **`READINESS_SECS` defaults to 120.** openvms brings up a dual-VM stack and
  needs ~40 s+; a shorter wait declares it failed and the abort's own restore
  then restarts it mid-boot, compounding the failure.
- A station is per-station canaried: `--canary <tile>`, verify, then `--promote`.
  `--rollback <tile>` swaps back atomically.
- **The complaint may be about a bundle you no longer ship.** The gallery is an
  installable PWA, and its service worker keeps one HTML shell for offline use.
  Before this was fixed the shell cache was named by a constant nobody ever
  bumped, so a client could hold an old shell indefinitely; the cache is now
  named after the build id and every deploy retires the previous one. Either
  way, **check the build before you reproduce anything**: `build` on the first
  event of the session's `clientlog` batch, or the `builds` facet /
  `build` filter on the trace store. Two live builds in one window means
  somebody is on a shell the box no longer serves. The full differential —
  including how to tell "ran an old shell" from "its beacons were blocked"
  using only our own data — is [`docs/ANALYTICS.md`](../ANALYTICS.md) §8.3.

## An observer holding QMP stops sessions negotiating (2026-08-30)

**If a station streams for the first visitor and then every later session times
out negotiating, check what else is talking to its QMP socket before you touch
the station.** This cost a cutover a rollback and very nearly condemned an
innocent component.

QEMU's QMP chardev serves **one monitor at a time**. Anything that connects and
holds it — an observation script, a screendump poller, an interactive session
somebody left open — makes every *other* QMP client wait. `idle.rs::qmp_execute`
gives up after 2 s (that timeout exists precisely "so a busy socket ... fails
fast instead of wedging the pauser") and returns `EAGAIN`, which surfaces as:

```
[idle] resume on connect failed (Resource temporarily unavailable (os error 11)); reconciler will retry
```

The damage is not the failed resume. `IdlePauser::session_started()` holds the
pauser's `st` mutex **across** that 2 s blocking call, and `handle_session`
awaits `session_started()` **before** any priming or keyframe work. So sessions
queue behind it: the first one through is fine, everything after it blows the
SPA's negotiation timeout. The symptom is `SESSION_ACCEPTED` with nothing after
it, and input-router counters **frozen at exactly the first session's totals** —
which reads exactly like a sink holding a claim, and is not.

Reproduced deliberately on a sandbox clone, driving real browser sessions
through a real daemon, with a second QMP client screendumping at 1 Hz:

| backend | QMP holder | result |
|---|---|---|
| `ramabs` | none | 5/5 sessions negotiate, counters advance |
| `ramabs` | 1 Hz | session 1 OK (degraded), sessions 2-4 time out |
| `dbus-rel` | none | 3/3 negotiate |
| `dbus-rel` | 1 Hz | sessions 1-2 OK (degraded), 3-4 time out |

`dbus-rel` builds **no InputRouter at all**, so no sink exists on that row: the
variable that decides the outcome is the observer, not the backend.

**Two rules follow.**

1. **Never diagnose a streaming complaint with an observer attached**, and never
   compare a suspect configuration measured *with* an observer against a control
   measured *without* one. That is the mistake that pointed a whole wave at the
   wrong component. Sample sparsely, and connect/read/close rather than holding
   the monitor open.
2. **This is a fleet-wide fragility, not a station's bug.** One well-behaved QMP
   client can stall every new session on any of the 61 stations. Recorded here
   deliberately un-fixed: it belongs to `idle.rs` and deserves its own change
   with its own proof, not a rider on a station cutover.
