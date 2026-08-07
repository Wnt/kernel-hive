# streamhost input-latency notes

Distilled from a read-only mining of open-source cloud-gaming stacks
(Moonlight/moonlight-common-c, moonlight-qt, Sunshine, GOW Wolf, Selkies, neko)
mapped onto our pipeline (2026-07-08, workflow whymk61by). Clones were under
scratchpad; findings verified against our own source at file:line.

## Already reference-optimal (mining corroborates — DO NOT change)
- Client decoder `optimizeForLatency:true` (streamClient.ts).
- No client jitter buffer; present-ASAP: AU decoded on stream completion, decoded
  frame drawn immediately, no JS frame queue (streamClient.ts / useStreamhostTexture.ts).
- `repeat-headers=1` — SPS/PPS inline on every IDR (encode.rs).
- Input split: unreliable QUIC **datagrams** for moves, **reliable** for keys/clicks
  (transport.rs). neko/Selkies carry moves reliably and are *behind* us here.
- Delay-gradient ABR (rtt_floor / rtt_excess, asymmetric hysteresis, dwell) — stronger
  than Selkies' equivalent (abr.rs).
- Server-side warpd move coalesce + 8ms pacing (warpd.rs) = Moonlight `moreData`/delta-coalesce.
- CQP tier-0, no VBV (encode.rs) — neko/Wolf use VBV/CBR which is *higher* latency.
- Coalesced pointer events + pointer-lock unadjustedMovement + keyboard.lock (StreamView.tsx).

## Ranked adoptable items (latency-win-per-effort)
1. **Coalesce the abs/rel dbus move path** (small, biggest felt win) — see below.
   *Status: DONE — commit `4e10abb`, transport.rs drain-coalesce.*
2. **Verify SPS VUI `num_reorder_frames=0` / `max_dec_frame_buffering<=1`** (trivial/measure).
   bframes=0 does NOT guarantee the VUI flags; if the browser DPB defensively buffers,
   that's ~1 frame (~16ms). Dump the emitted SPS; add x264 VUI opts only if missing.
   Corroborated by moonlight-qt (ffmpeg.cpp) + Sunshine (cbs.cpp).
3. **Split the single reliable input bidi into per-type QUIC streams** (kbd/button/wheel/
   urgent-control) — kills head-of-line blocking (a mouse-button retransmit can't stall a
   keypress). Moonlight's 48-channel design. Medium (wire change both ends).
   *Status: DONE both ends — server fleet-wide + SPA per-class uni streams
   (`spa/src/three/streamClient.ts`). The per-type router is always on since
   2026-07-14 (`SH_INPUT_STREAMS` knob removed); the legacy bidi loop stays for
   old clients.*
4. **In-process libx264** (large) — removes the ffmpeg child pipe memcpy AND the ~2ms
   per-frame stdout "quiet-window" drain (encode.rs waits 2ms of pipe silence to detect AU
   end), plus unlocks x264_encoder_reconfig (ABR without IDR blip) + real per-frame QP.
   Proven viable in a daemon by neko/Wolf/Sunshine. Already the documented production step.
   KEEP our CQP/no-VBV; adopt only the in-process boundary, not their rate control.
   *Status: DONE, incl. the dedicated encode thread — deployed fleet-wide 2026-07-09;
   see docs/history/ENCODER-INPROCESS-FINDINGS.md (glass-to-glass isolated-input p50 390-564ms -> 22-44ms).*
5. **sliced-threads for big tiles** (trivial, measure first) — drop `-threads 1` →
   `sliced-threads=1:threads=N`; tune=zerolatency parallelizes WITHIN a frame (no frame
   latency). Only material for Solaris 1920x1200; check the enc-latency p95 log first.
   *Status: measured neutral at tile resolutions; kept as-is.*
6. **Glass-to-glass instrumentation** — stamp encode-done + client present delta (we already
   carry capture_ts_us). Prerequisite to *prove* 1/4/5, not itself a reducer.
   *Status: measurement rig exists at `/data/vms/streamhost/staging-encthread/rig`.*
7. DSCP/SO_PRIORITY + larger SNDBUF on the input socket — WAN/Wi-Fi only, no-op on LAN.

## NOT adoptable for us (mining confirms)
RFI/LTR reference-invalidation (libx264 has no API — Sunshine stubs it on its SW path);
intra-refresh (awkward for WebCodecs, and moot on reliable-stream video); FEC-on-datagrams /
speculative-loss / force-IDR-on-decode-error (moot — our video rides RELIABLE QUIC uni-streams,
so loss = retransmit delay on that AU only, never corruption); DMABuf zero-copy (CPU encode).

## Item 1 detail — the biggest felt input-lag win

*Status: DONE — commit `4e10abb` ("coalesce dbus mouse-move datagrams off the
receive loop"), the transport.rs drain-coalesce task described below.*

Root cause: the datagram receive loop applies each move as an AWAITED dbus `call_method`
(SetAbsPosition/RelMotion) that waits for a QEMU method REPLY *before* the next
receive_datagram. At pointer-lock move rates (~1 record/mousemove, up to ~1kHz) datagrams
queue in quinn and are applied late, one round-trip each — a backlog of superseded positions.
This is exactly what warpd.rs already prevents for warpd tiles; it affects ALL abs/rel dbus
tiles (winxp, win2000, reactos, haiku, the tablet tiles, the rel tiles).
Fix: mirror warpd.rs — funnel move datagrams (type1 abs / type4 rel) into an mpsc; a
drain-coalesce task keeps the LATEST abs position / SUMS rel deltas and issues ONE dbus inject
per drain, OFF the receive path; buttons/keys/wheel never pooled behind moves; hard coalesce
cap <= ~1 frame. Optional multiplier: send the inject as a NO-REPLY dbus message
(fire-and-forget) to remove the round-trip entirely. Measure with the framebuffer-timestamp
method: drive a high-rate move burst, screendump, compute wire-ts → pixel-change p50/p95
before/after.
