# Debugging a streaming complaint

**Start here when the operator says a station "froze", "went blurry", "got
laggy", "stopped", or "dropped quality".** This is the runbook: where the
evidence already is, how to read it, and the failure signatures we have seen.

You almost never need to reproduce a streaming bug. The client records its own
state continuously and ships it to the box, so the evidence for a complaint that
happened an hour ago is usually already on disk.

---

## 1. The three places evidence lives

| Plane | Where | Covers |
|---|---|---|
| **Client telemetry** | `lab:/data/vms/streamhost/serve/clientlog.jsonl` | What the BROWSER saw: quality tier, loss, RTT, freezes, decoder state. Rolling ~36 h. |
| **Station daemon** | `ssh lab 'journalctl -u streamhost@<station>'` | What the SERVER did: tier decisions, encoder reconfigs, session lifecycle, input. |
| **Live overlay** | the SPA, **Ctrl/Cmd+N** | The same client state as the log, live. Ask the operator for a screenshot. |

**The client plane is the one people forget, and it is usually the decisive
one.** The server cannot see most of what the browser knows (§3).

---

## 2. Client telemetry: `clientlog.jsonl`

Written by `POST /clientlog` in `scripts/serve/osgallery-https-server.py`.
Untokened (LAN/VPN-only deployment). One JSON object per line, with `srvTs`
(server receive time, epoch seconds), `ip`, `sessionId` (8 hex, per page load),
`tile`, `event`, `detail`.

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
    if d.get("tile") != "win311": continue          # <- station
    if d.get("srvTs", 0) < 1786968600: continue      # <- epoch cutoff
    print(datetime.datetime.fromtimestamp(d["srvTs"]).strftime("%H:%M:%S"),
          d.get("sessionId"), d.get("event"), "|", str(d.get("detail"))[:200])
EOF'
```

Other events: `connect`, `wt-close` (carries the exit reason), `stall`,
`decoder-config`, `decoder-error`, `drag-tel`, `ptr`, `client-error`.

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
