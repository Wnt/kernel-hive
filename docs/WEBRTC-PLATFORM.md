# WebRTC native-decoder fallback: platform architecture

Status: generic bridge implementation. This supersedes the Phase-1 per-station
spike and every per-station pilot artifact.

## Architecture

WebTransport + WebCodecs remains streamhost's primary path. The UI selects
native WebRTC whenever the browser lacks EITHER `WebTransport` or
`VideoDecoder` (`spa/src/three/streamTransportSelect.ts`, one decision for
every start, restore and reconnect). Firefox-Android lacks the decoder;
Safari 17 (macOS/iPadOS, `Version/17.x`) lacks WebTransport and was, until
2026-09-08, routed by the decoder test alone into four `ReferenceError: Can't
find variable: WebTransport` attempts. A browser with neither also takes WebRTC.
The `station-open`/`session-start` rows carry `transport` naming the choice.

The fallback is one platform service:

1. Every instance of the shared Rust streamhost binary automatically connects
   to `/run/osgallery-webrtc/feeds.sock` and registers its ordinary `SH_STATION`.
   It mirrors the existing encoded H.264 Annex-B AUs and Opus packets. There is
   no second capture or encoder.
2. One `osgallery-webrtc-bridge.service` owns that socket, loopback HTTP
   `127.0.0.1:18080`, and ICE UDP `54200` (registry `ports.webrtcBridgeUdp`;
   `55950` until 2026-09-08 — a port the edge never forwarded, see
   [Remote visitors](#remote-visitors)). It multiplexes independent station hubs
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

## Remote visitors

A remote browser (the operator's iPad on cellular, any visitor outside the
LAN) reaches the bridge through the same hole the WebTransport stations use:
the edge VPS DNATs UDP `54080-54200` to the box unchanged
(`docs/PUBLIC-GALLERY.md`, registry `ports.publicRelayLow..High`). The bridge
therefore listens on **54200**, the top of that range, reserved for it in
registry `ports.webrtcBridgeUdp` so no station is ever allocated slot 200
(`stations_registry.generate.slot_refusal`, `validate_rules`, `wave.sh alloc`
all refuse it; `kh-claim who port 54200` names the owner on the box).

Listening on a forwarded port is half of it. Pion gathers host candidates from
the box's own interfaces, so the SDP answer used to carry only LAN addresses —
a remote peer had nothing reachable to try and every attempt ended in
`webrtc-state pc=failed ice=failed signaling=stable`. The unit now passes
`-public-ip ${WEBRTC_PUBLIC_IP}` (the address `kernelhive.madekivi.fi`
resolves to, written box-side into `/etc/osgallery-webrtc/bridge.env` by
`streamhost/webrtc-bridge/deploy/install-bridge.sh` from `SH_GALLERY_HOST` in
`registry/local.env`; never committed). The bridge applies it as an ICE
address-rewrite rule of type **host, mode append**
(`webrtc.SetICEAddressRewriteRules`; `main.go` `iceSettings`), which is the one
combination that works with the UDP mux:

| rule | what the SDP carries | verdict |
|---|---|---|
| host + replace (the old `SetNAT1To1IPs(…, Host)`) | `public:54200` only | breaks LAN visitors — the Firefox-Android proof below is a LAN visitor |
| srflx (`ICECandidateTypeSrflx`) | `lan:54200` + `public:<ephemeral>` | pion gathers a mapped srflx candidate on a NEW socket (`ice/v4` `gatherCandidatesSrflxMapped`), not on the mux — a port the edge does not forward |
| **host + append** | `lan:54200` + `public:54200` | both on the mux socket; LAN visitors pick the LAN pair, remote ones the public pair |

`main_test.go` `TestPublicIPIsAppendedOnTheMuxPort` gathers against a real mux
and asserts exactly that shape. A remote session that works looks like this in
`clientlog.jsonl` (Safari 17 on cellular, 2026-09-08, session `c26c357c`):

```
webrtc-offer   attempt=0 playoutDelayOffered=true iceServers=0
webrtc-track   kind=video id=… jitterFloorMs=15
webrtc-state   pc=connecting ice=connected signaling=stable
webrtc-state   pc=connected ice=connected signaling=stable
webrtc-stats   media=live … framesDecoded=18 fps=7 … candidate=prflx/udp remote=host@<public>:54200
```

`candidate=` is the browser's OWN selected candidate — `prflx` on cellular is
normal (the client offers no STUN, so its NAT mapping is learnt from the
bridge's checks). `remote=` (added 2026-09-08) is the bridge-side half of the
pair: `<public>:54200` for a remote visitor, `<lan>:54200` for a LAN one. On
the box, `tcpdump -ni wg0 udp port 54200` shows the same session arriving
through the tunnel. The operator no longer hand-tests: drive the real tab
with `clientcmd.sh eval <sid> 'location.assign("/walkin/play/win311"); return "nav"'`
and read the rows (`docs/lab/STREAM-DEBUGGING.md` §5, "no reachable candidate").

## TURN status

TURN is not operational on CT950 as of 2026-07-16 — and after the remote path
above it is not needed for a visitor behind an ordinary NAT; only a network
that blocks outbound UDP entirely would still need a relay. The private ops declaration
describes a public TCP forward `tunnel.example.com:13478 -> CT950:3478`, but
the public endpoint refuses TCP connections and CT950 has no TCP or UDP listener
on 3478. There is no coturn service/config/binary and no forwarder-agent service
or executable on CT950. Restoring relay needs both missing components plus
credential provisioning; neither can be recovered through the permitted
`ssh lab` boundary.

`WEBRTC_ICE_SERVERS_FILE` therefore intentionally remains absent/empty; the
supported paths are LAN `host/udp` and the public host candidate on udp/54200.
Do not claim TURN fixed merely because a URL is configured. A TURN proof must
show `candidateType=relay` and `protocol=tcp` in `__kernelHiveWebRtcDebug()`.

## Deployment and rollback

The shared binary must be built first without restart, backed up, then restarted
on one canary. Confirm both its bridge feed and normal WebTransport stream before
using explicit, reviewed waves of station names. Never use a blind `--all` restart.

The generic bridge has one non-template unit:

```bash
# Neither CT950 nor the box has a Go toolchain any more (only the box's old
# module cache survived 2026-07-16). Fetch one into the sandbox; pion is pure
# Go, so the static amd64 binary runs on the box unchanged:
curl -sSL https://go.dev/dl/go1.24.7.linux-amd64.tar.gz | tar xz -C "$SANDBOX/build"
cd streamhost/webrtc-bridge
GOROOT=$SANDBOX/build/go GOPATH=$SANDBOX/build/gopath PATH=$GOROOT/bin:$PATH \
  CGO_ENABLED=0 go test ./... && go build -trimpath -o $SANDBOX/build/osgallery-webrtc-bridge .
# On the box (root): backs up the live binary with a timestamp, writes
# /etc/osgallery-webrtc/bridge.env from SH_GALLERY_HOST, installs the unit,
# restarts, and proves `ss -lun` shows udp/54200 + /healthz answers.
ssh lab "$SANDBOX/repo/streamhost/webrtc-bridge/deploy/install-bridge.sh \
  $SANDBOX/build/osgallery-webrtc-bridge $SANDBOX/repo"
```

The restart drops every open WebRTC peer (they reconnect within the open UI
session, see above); WebTransport stations never notice.

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
