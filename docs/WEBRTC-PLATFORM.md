# WebRTC native-decoder fallback: platform architecture

Status: generic bridge implementation. This supersedes the Phase-1 per-station
spike and every per-station pilot artifact.

## Architecture

WebTransport + WebCodecs remains streamhost's primary path. When and only when
the browser has no `VideoDecoder`, the UI selects native WebRTC.

The fallback is one platform service:

1. Every instance of the shared Rust streamhost binary automatically connects
   to `/run/osgallery-webrtc/feeds.sock` and registers its ordinary `SH_TILE`.
   It mirrors the existing encoded H.264 Annex-B AUs and Opus packets. There is
   no second capture or encoder.
2. One `osgallery-webrtc-bridge.service` owns that socket, loopback HTTP
   `127.0.0.1:18080`, and ICE UDP `55950`. It multiplexes independent station hubs
   and per-peer Pion sessions. `POST /offer/<tile>` chooses a registered feed.
3. The HTTPS server advertises `/webrtc/<tile>/offer` for every key in its
   ordinary `tiles.json`. The bridge upstream and ICE list are global platform
   settings; `tiles.json` cannot contain a WebRTC gate or upstream.
4. Bridge `S`/`E` lease commands share streamhost's idle-pause counter with
   WebTransport sessions. A WebRTC-only visitor wakes and holds the guest rather
   than watching it freeze after the idle grace period.

Pion is the deliberate interim rather than in-process webrtc-rs: its
H.264/RTP, NACK/PLI/FIR, per-peer playout-delay extension, and reconnect behavior
were already proven. This limits the shared Rust binary change to a small,
best-effort Unix mirror and avoids putting a new WebRTC stack on the latency-
sensitive WebTransport path. Adding a station requires only the normal streamhost
station registration; the same shared binary and bridge discover it automatically.

## Client recovery and live state

An ICE `failed`, sustained `disconnected`, muted video track, or decoded-frame
stall closes the current `RTCPeerConnection` and creates a fresh offer with
bounded backoff. Recovery happens within the open UI session. Attempt identity
guards prevent late callbacks from an old peer tearing down its replacement.

The UI is not marked live on `ontrack` or PC connectivity. `LIVE · WebRTC
fallback` appears only after `getStats()` reports `framesDecoded` advancing.
While recovering or stalled it shows that state. Initial negotiation has a
bounded failure budget and ends at the ordinary error overlay instead of a
permanent false-LIVE or infinite connecting state.

## TURN status

TURN is not operational on CT950 as of 2026-07-16. The private ops declaration
describes a public TCP forward `tunnel.example.com:13478 -> CT950:3478`, but
the public endpoint refuses TCP connections and CT950 has no TCP or UDP listener
on 3478. There is no coturn service/config/binary and no forwarder-agent service
or executable on CT950. Restoring relay needs both missing components plus
credential provisioning; neither can be recovered through the permitted
`ssh lab` boundary.

`WEBRTC_ICE_SERVERS_FILE` therefore intentionally remains absent/empty and the
supported fallback is LAN `host/udp`. Do not claim TURN fixed merely because a
URL is configured. A remote proof must show `candidateType=relay` and
`protocol=tcp` in `__kernelHiveWebRtcDebug()`.

## Deployment and rollback

The shared binary must be built first without restart, backed up, then restarted
on one canary. Confirm both its bridge feed and normal WebTransport stream before
using explicit, reviewed waves of station names. Never use a blind `--all` restart.

The generic bridge has one non-template unit:

```bash
cd streamhost/webrtc-bridge
go build -o osgallery-webrtc-bridge .
install -m 0755 osgallery-webrtc-bridge \
  /data/vms/streamhost/webrtc/bin/osgallery-webrtc-bridge
install -m 0644 deploy/osgallery-webrtc-bridge.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now osgallery-webrtc-bridge.service
```

Rollback does not restore a forbidden per-station sidecar. Stop the one bridge,
restore the timestamped pre-platform shared streamhost binary, and explicitly
restart only the stations already rolled forward. Restore the pre-platform HTTPS
server (and UI through the normal orchestrator) if signaling/client rollback is
also required.

CT950 rollback artifacts from the 2026-07-16 rollout are:

- `/data/vms/streamhost/build/target/release/streamhost.pre-webrtc-platform-20260716T125912Z`
- `/data/vms/streamhost/serve/osgallery-https-server.py.pre-webrtc-platform-20260716T132103Z`

## Automated evidence (2026-07-16)

- Deliberate rollout: Win95 canary, FreeDOS second station, then four explicit
  reviewed waves. Final bridge health reported 28 live units, 28 registered
  feeds, no missing/extra feed, and every `/proc/<pid>/exe` resolving to the
  shared `build/target/release/streamhost`.
- Simultaneous native-decoder soak: Win95 remained live for 185.1 s and decoded
  1 -> 409 frames; FreeDOS remained live for 185.3 s and decoded 1 -> 5335.
  Both finished PC/ICE connected with `video/H264`, host/UDP.
- Recovery: a six-second stop of the one bridge produced the reconnecting state
  and recovered without reload; FreeDOS decoded 24 -> 1457 in 60.4 s with
  `reconnectCount=1`. Streamhost logged release of the outstanding viewer lease
  when the bridge disconnected, then acquired a fresh lease after restart.
- WebTransport regression: deployed desktop Firefox and Chromium each painted
  FreeDOS, Win95, and Solaris through WebCodecs/WebTransport; all 6 checks passed
  with no fallback debug object or decoder-failure banner.
- Static checks: UI TypeScript/Vite build and lint passed; HTTPS endpoint suite
  passed 26 assertions (including generic Win95 + FreeDOS offers); all 38 Rust
  daemon unit tests and all Go bridge tests passed.

These browser probes force `VideoDecoder` absent in Chromium to exercise the
same platform decision and native decode seam. They do not replace the final
real Firefox-Android device run below.

## Firefox Android proof

Open two different production stations in Firefox Android, for example
`/os/win95` and `/os/freedos`. Authenticate each operator tab with
`window.__kernelHiveAdminLogin()` through remote DevTools before looking up its
session. Eval is normally disabled; use a bounded explicit opt-in (see
`scripts/serve/README.md`) and turn it off immediately afterwards:

```bash
ssh lab 'OSG_ADMIN_EVAL=1 /data/vms/streamhost/serve/restart-https.sh'
OSG_ADMIN_EVAL=1 clientcmd.sh eval SESSION_ID "return globalThis.__kernelHiveWebRtcDebug?.()"
OSG_ADMIN_EVAL=1 clientcmd.sh evallog SESSION_ID
ssh lab '/data/vms/streamhost/serve/restart-https.sh'
```

Pass requires `transport=webrtc-fallback`, `mediaState=live`, connected PC/ICE,
`codec=video/H264`, `candidateType=host`, `protocol=udp`, and increasing
`framesDecoded` after 2–3 minutes. During one station, stop the single bridge long
enough to enter reconnecting, start it again, and verify the same page returns
to live with `reconnectCount` increased and frames advancing. Repeat without a
page reload. Desktop Firefox and Chrome must have `VideoDecoder=true`, no
fallback debug object, and a normally painted WebTransport surface.
