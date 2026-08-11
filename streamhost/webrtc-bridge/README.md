# Platform WebRTC bridge

This Go service is the native-decoder fallback egress for **every** streamhost
tile. Despite the historical directory name, it is no longer a per-tile spike:

- one service owns one HTTP listener, one ICE UDP port, and one Unix feed socket;
- every instance of the shared Rust streamhost binary registers `SH_STATION`
  automatically on that socket and mirrors its existing H.264/Opus output;
- `POST /offer/<tile>` selects the registered feed on demand;
- the HTTPS server advertises the same platform endpoint for every tile in its
  ordinary signal registry; and
- no tile env, launcher, signal stanza, sidecar, WebRTC port, or opt-in exists.

The bridge is intentionally out of process for this interim: it reuses the
already proven Pion H.264/RTP/RTCP behavior and avoids adding a large WebRTC Rust
dependency to the shared latency-sensitive streamhost binary. The only Rust
addition is a small best-effort Unix mirror. WebTransport does not depend on the
bridge and remains the default whenever `VideoDecoder` exists.

Build with `go build -o osgallery-webrtc-bridge .`. Install the single unit in
`deploy/`; do not instantiate a template unit. `/healthz` reports all currently
registered tile feeds and peer/frame counters without credentials or SDP.

TURN is configured globally by the HTTPS server's
`WEBRTC_ICE_SERVERS_FILE`, never here or in `tiles.json`. An absent file means
host/UDP only.
