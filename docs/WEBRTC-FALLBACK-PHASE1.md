# WebRTC fallback Phase 1: decision and spike (historical, superseded)

The per-station test topology below is retained only as Phase-1 evidence. It is no
longer deployable and its launcher/config artifacts were removed. The current
zero-per-station platform architecture is [WEBRTC-PLATFORM.md](WEBRTC-PLATFORM.md).

Status: Phase-1 implementation and namespaced TinyCore spike. It is not a fleet
rollout and is inert unless both the server test environment and a WebCodecs-less
browser opt into it.

## Decision

Use a small Pion sidecar for the first on-device proof, fed by an optional Unix
socket mirror of streamhost's existing `encode::Au` broadcast. This is the
shortest route to Firefox-Android's native H.264 decoder because Pion already
provides ICE, DTLS-SRTP, RTP packetization, RTCP, and NACK interceptors. It keeps
the experiment out of the shared production Rust dependency graph.

The production recommendation is different: after the device proof and latency
measurement, replace the local spike framing with an in-process `webrtc-rs` (or,
if its packetization/interceptor support proves materially weaker, `str0m`) sink
next to `transport::serve`. Both designs subscribe to the same `EncoderOut` and
`AudioOut`; there remains one x264/Opus encode and two egresses. The Rust sink is
the cleaner fleet design because it removes one process, one local protocol, and
cross-process lifecycle/signaling coordination.

Resurrecting the old neko image was rejected for the spike. Its Pion plane was a
complete desktop-capture service around X11/PulseAudio, not a reusable source
sink for streamhost AUs, so it would reintroduce a second capture/encode path.
The historical code remains useful evidence for Pion/ICE behavior, but the GFN
receiver and the present encoded-media seam are the better reusable pieces.

## Phase-1 data and signaling paths

```text
QEMU D-Bus display -> x264 once -> EncoderOut broadcast
                                |-> WebTransport AUs (unchanged)
                                `-> SH_WEBRTC_SINK Unix framing -> Pion -> H.264 RTP

Firefox-Android -> GET /signal/tinycore.json
                <- optional webrtc {offerUrl, iceServers, jitter floor}
                -> POST /webrtc/tinycore/offer (complete ICE offer)
HTTPS server    -> loopback-only Pion /offer proxy
                <- complete ICE answer
Firefox-Android <- native H.264 MediaStreamTrack -> real <video>/VideoTexture
```

The UI checks capabilities, not user-agent strings. `VideoDecoder` present means
the existing WebTransport/WebCodecs client is used without fetching or creating a
PeerConnection. `VideoDecoder` absent means the signal document is checked for the
optional `webrtc` object. Only the namespaced test config has that object; without
it, the shipped decoder-unsupported banner remains in place.

Signaling is deliberately non-trickle for the spike: the browser gathers all ICE
candidates, POSTs one offer, Pion gathers and returns one answer. The HTTPS server
will proxy only to a loopback HTTP upstream configured for that exact station. SDP,
TURN credentials, and candidate contents are never logged. Production needs
authenticated session creation, trickle ICE, expiry, rate limits, and CSRF/origin
policy.

## Low-latency and loss behavior

- The browser puts H.264 first with `RTCRtpTransceiver.setCodecPreferences`.
- Pion advertises H.264 packetization-mode 1 with NACK, PLI, and FIR feedback;
  its default interceptors provide NACK retransmission. All PeerConnections use
  one shared ICE UDP mux, so concurrent viewers and a fast reconnect safely share
  the single namespaced port.
- Both tested desktop engines offer the `playout-delay` extension. The sidecar
  keeps the negotiated one-byte extension ID per PeerConnection and stamps that
  peer's RTP packets with a 0–10 ms playout window. This lets concurrent peers
  negotiate different IDs and releases the state with the peer. It does not
  merely add an SDP line.
- PLI/FIR received by Pion sends `K` over the Unix stream; streamhost calls
  `EncoderOut::request_keyframe()`.
- The receiver sets `jitterBufferTarget=15` ms and, where exposed,
  `playoutDelayHint=0.015` s. Phase 1 reapplies this floor during stats sampling
  but does not yet implement the planned jitter/RTT-driven backoff controller.
- Five-second `getStats()` telemetry records decoded/received frames, FPS,
  packet loss, jitter, average jitter-buffer delay, RTT, codec, candidate type,
  and transport. `__kernelHiveWebRtcDebug()` exposes the same snapshot to targeted
  `clientcmd eval`.
- FlexFEC/ULPFEC and Opus are intentionally deferred. NACK/PLI are active now.

## Namespaced test allocation and teardown

The test is a reflink clone of the TinyCore fixture, never the production QEMU:

- root: `/data/vms/streamhost/webrtc-phase1`
- QEMU label/VMID: `osgallery-webrtc-phase1-vmid-9951`
- clone QMP/pidfile: `tile/qmp.sock`, `tile/qemu.pid`
- WebTransport UDP: `55911`
- WebRTC ICE UDP: `55951`
- Pion loopback HTTP: `127.0.0.1:18081`
- test HTTPS: `18443`
- AU socket: `run/aus.sock`
- transient services: `osgallery-webrtc-phase1-{pion,streamhost,https}.service`

At the Phase-1 deployment check, the documented public TCP forward on port
13478 refused connections and there was no listener on labhost TCP 3478. The test
signal therefore intentionally serves an empty `iceServers` list and the proof
is LAN `host/udp` only. Remote `relay/tcp` proof is blocked until the existing
forwarder/coturn service is restored; credentials must then be written only to
the namespaced, untracked `serve/ice-servers.json`. A configured TURN URL alone
is not evidence—the selected candidate pair must say `relay/tcp`.

The launch/stop scripts only signal the PID in the clone's own pidfile. Teardown:

```bash
ssh lab 'systemctl stop osgallery-webrtc-phase1-pion.service \
  osgallery-webrtc-phase1-streamhost.service \
  osgallery-webrtc-phase1-https.service; \
  /data/vms/streamhost/webrtc-phase1/bin/stop-test-tile.sh'
```

Do not call `build-deploy.sh --all`, restart `streamhost@tinycore`, or add this
entry to `/data/vms/streamhost/serve/tiles.json`.

## Device proof runbook

1. On the phone, connect to the same LAN and open
   `https://192.0.2.10:18443/os/tinycore`. The local gallery CA must already be
   trusted. Use Firefox for Android; do not enable a desktop-mode UA override.
2. Confirm the TinyCore desktop moves (open/drag a window or wait for visible
   screen changes). The video element should be native WebRTC; no WebCodecs API is
   required. Input is not part of the Phase-1 fallback, so make motion from a
   normal WebCodecs session or the guest console if needed.
3. From the operator shell run the namespaced telemetry helper environment:
   `ssh lab 'SERVE=/data/vms/streamhost/webrtc-phase1/serve PORT=18443
   CLIENTCMD_TOKEN=/data/vms/streamhost/serve/pki/clientcmd.token
   /data/vms/streamhost/webrtc-phase1/bin/clientcmd.sh sessions'`.
   First authenticate the phone tab with `window.__kernelHiveAdminLogin()` through
   remote DevTools; then select the Firefox-Android session ID.
4. Request a snapshot, then evaluate the live WebRTC probe only in that session:
   `... clientcmd.sh snapshot tinycore` and
   `OSG_ADMIN_EVAL=1 ... clientcmd.sh eval <sessionId>
   'return globalThis.__kernelHiveWebRtcDebug?.()'`. The HTTPS server must also
   have been restarted with `OSG_ADMIN_EVAL=1`; reassemble with
   `OSG_ADMIN_EVAL=1 ... clientcmd.sh evallog <sessionId>`, then restart it with
   eval unset immediately after the probe.
5. Proof requires: `connectionState:"connected"`,
   `iceConnectionState:"connected"` or `"completed"`,
   `framesDecoded` increasing across two samples, `framesPerSecond>0` while the
   guest moves, `codec:"video/H264"`, and `playoutDelayNegotiated:true`. Record
   `candidateType/protocol`, `jitterBufferMs`, `rttMs`, and `packetsLost`.
6. For LAN proof the selected candidate should be `host/udp`. For the remote
   proof it must be `relay/tcp`; do not call a TURN-configured session proven
   until that selected candidate is visible in stats.
7. In desktop Chrome and desktop Firefox (where `VideoDecoder` is present), open
   the same test URL and confirm the debug snapshot is the normal streamhost
   metrics rather than `transport:"webrtc-fallback"`. This proves the test clone
   still serves the unchanged WebTransport path.

## Phase-1 evidence before the phone handoff

The namespaced live clone was exercised end to end with a Chrome tab whose
`VideoDecoder` property was removed before app startup. This is not the final
Firefox-Android device verdict, but it drives the exact capability branch and
uses the browser's native WebRTC decoder. The result was a non-black 1024×768
video; a QMP `sendkey ctrl-alt-t` visibly changed sampled video pixels; decoded
frames advanced 10→33; H.264 stats reported 0 lost packets, `host/udp`, negotiated
playout-delay, and a connected ICE/PeerConnection. Separate unmodified Chrome
and Firefox tabs both rendered the clone through WebTransport/WebCodecs with no
`__kernelHiveWebRtcDebug` object. Two simultaneous fallback viewers plus an
immediate third reconnect also decoded successfully through the shared UDP mux.
The remaining Phase-1 acceptance item is the real phone run above.

## Phased production plan

Phase 2 converts the proven egress to an in-process Rust sink, adds Opus from the
existing `AudioOut`, maps session ownership and input explicitly, and runs
WebTransport-vs-WebRTC latency/loss A/Bs on the test clone. It also implements the
basic stats-driven jitter controller: start at 10–20 ms, increase only when
measured interarrival jitter/loss/decode drops justify it, and decay slowly.

Phase 3 hardens signaling (authenticated short-lived sessions, trickle ICE,
origin/CSRF/rate limits, teardown/reaping), completes TURN TCP/UDP validation,
adds remote-path FEC/RTX tuning, and integrates WebRTC sessions into idle-pause,
ABR ownership, and fleet observability.

Phase 4 performs a small canary rollout, validates audio sync/mobile autoplay and
accessibility, then rolls out station-by-station with per-station kill switches. Only after
canary acceptance does the fallback become available for every production station
listed by the canonical registry (`python3 scripts/tiles-registry.py count`).
WebTransport/WebCodecs remains the default throughout.
