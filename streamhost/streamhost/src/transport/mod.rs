// Transport: WebTransport (QUIC) server. Ported from SPIKE B (proven Mac Chrome
// <-> Rust over the self-signed cert-hash path), hardened for production:
//   * VIDEO out: one H.264 Annex-B access unit per unidirectional QUIC stream.
//   * AUDIO out: one Opus packet per unidirectional QUIC stream (own tag).
//   * A 1-byte KIND prefix now leads every uni-stream so the client routes it:
//       kind=1 video: [1 | frame_id u32 | au_type u8 | capture_ts u32 | AnnexB]
//       kind=2 audio: [2 | seq u32       | ts_us u32               | Opus     ]
//     Both timestamps share one monotonic epoch (clock.rs) for A/V sync.
//   * INPUT in : mouse-move + RTT pings over datagrams (unreliable, coalesced);
//     buttons/keys/wheel/touch over CLIENT-opened reliable QUIC streams. Two
//     framings coexist (the server always reads both; the client picks one):
//       - PER-TYPE (the shipped UI): one client-opened UNIDIRECTIONAL
//         reliable stream per input CLASS, led by a 1-byte class tag (mirrors the
//         uni-stream KIND convention) — ICLASS_KEY=1 / ICLASS_BUTTON=2 /
//         ICLASS_WHEEL=3 / ICLASS_CONTROL=4 — then the same length-prefixed
//         [len u16 | record] framing. Separate streams = a retransmit on one class
//         can't head-of-line-block another (Moonlight-style HOL avoidance). Records
//         are still self-describing (rec[0] is the input type), so input::handle is
//         unchanged; the tag only demuxes the class onto its own ordered stream.
//       - LEGACY (an old UI): ALL classes on ONE client-opened reliable BIDI
//         stream, [len u16 | record]. Still accepted unconditionally so old and
//         new clients both work against this server.
//   * CERT ROTATION: the endpoint is rebuilt on a ~10-day timer with a fresh
//     self-signed cert; signaling.json is re-published each cycle. Clients fetch
//     the live hash and reconnect (gallery stations auto-reconnect), so rotation is
//     a sub-second blip on the same UDP port — no hardcoded pin ever.
//
// This module is split along its natural seams: the SERVER->CLIENT uni-stream
// framing lives in `egress` (send_au / send_audio / send_params_*), the
// CLIENT->SERVER reliable-input draining lives in `input_stream`, and the
// session lifecycle (endpoint bind + cert rotation, per-session task fan-out)
// stays here.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use wtransport::config::QuicTransportConfig;
use wtransport::endpoint::IncomingSession;
use wtransport::{Endpoint, ServerConfig};

use crate::abr::Abr;
use crate::audio::AudioOut;
use crate::capture::Capture;
use crate::cert;
use crate::config::Config;
use crate::encode::EncoderOut;
use crate::input;

mod backlog;
mod egress;
mod input_bench;
mod input_stream;

use backlog::{session_backlog, BacklogGate, RelayVerdict};
use egress::{send_au, send_audio, send_params_encoder, send_params_stats};
use input_bench::spawn_input_bench;
use input_stream::drain_input_stream;

// CLIENT->SERVER feedback datagram opcode (SECTION 3.1). Distinct from the type-9
// RTT ping and the input record namespace {1..6}.
const OP_STATS: u8 = 10;

/// Conservative QUIC UDP payload used in both directions. The Android phone's
/// routed path is IP-MTU 1420 (1392 bytes after IPv4+UDP headers), while Quinn's
/// default DPLPMTUD upper bound is 1452 bytes. Firefox Android can keep the
/// session/control plane alive while large key-AU packets disappear on that
/// path, so do not probe above QUIC's universally safe 1200-byte floor.
pub(crate) const QUIC_MAX_UDP_PAYLOAD: u16 = 1200;

/// SH_VIDEO_TRACE=1 — per-AU video-path diagnostics (canary use only; the check
/// is a one-time env read, zero per-frame cost when off). Added while root-causing
/// the 2026-07-09 "zero video AUs" false blocker: it proves on the live journal
/// that every AU is subscribed, primed, relayed and finished per session.
fn video_trace() -> bool {
    static VT: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *VT.get_or_init(|| crate::config::env_flag("SH_VIDEO_TRACE"))
}

/// Per-session join gate: a freshly-joined session must start its broadcast
/// relay on a KEYFRAME. The broadcast channel resumes mid-GOP for a joiner on a
/// busy station, and mid-GOP deltas reference frames the session never received
/// (the gap between the primed cached key and the subscription point), so they
/// must be discarded until the first key AU arrives. After that everything is
/// admitted unconditionally — steady-state relay is unchanged. The B1 backlog
/// policy (transport/backlog.rs) RE-ARMS this gate whenever a skip/Lagged
/// episode ends on a delta, so a resume can never relay broken references.
struct JoinGate {
    seen_key: bool,
}

impl JoinGate {
    fn new() -> Self {
        JoinGate { seen_key: false }
    }
    /// True = relay this AU; false = discard (pre-key delta).
    fn admit(&mut self, is_key: bool) -> bool {
        if !self.seen_key {
            if !is_key {
                return false;
            }
            self.seen_key = true;
        }
        true
    }
}

pub async fn serve(
    cfg: Arc<Config>,
    cap: Capture,
    enc: Arc<EncoderOut>,
    audio: Option<AudioOut>,
    pauser: Option<Arc<crate::idle::IdlePauser>>,
) -> Result<()> {
    let rotate_after = Duration::from_secs(cfg.cert_rotate_days * 86_400);
    let input_router = crate::realtime_input::InputRouter::from_config(&cfg);
    if let (Some(addr), Some(router)) = (cfg.input_bench_addr.clone(), input_router.clone()) {
        spawn_input_bench(addr, cap.clone(), router);
    }

    // Global-per-station ABR controller (SECTION 2). One in-process encoder per station
    // is broadcast to all sessions, so the tier is shared; the controller
    // aggregates the worst client and drives the encoder. When ABR is off, the
    // controller is not run and the encoder stays pinned to tier 0.
    let abr = Abr::new(cfg.clone(), enc.clone());
    if cfg.abr {
        abr.clone().spawn_controller();
        eprintln!(
            "[transport] ABR controller ON (min_restart={}ms floor_h={})",
            cfg.abr_min_restart_ms, cfg.abr_floor_height
        );
    } else {
        eprintln!("[transport] ABR OFF (pinned tier 0)");
    }

    // DAEMON-WIDE abs->rel pointer model: the guest cursor is a property of the
    // guest, not of a browser tab, so its tracked position must survive a client
    // reload. Sessions share this one MouseState (each re-arms only its own
    // per-connection fields via reset_for_session); a reload keeps tracking from
    // the known position instead of re-seeding and making the visitor corner-chase.
    let mouse = input::new_mouse();
    // SH_REL_PACED: the paced sender owns every bridge RelMotion. Spawned ONCE
    // here (not per session) now that the model is daemon-wide, so a reload does
    // not stack a second pacer on the same state.
    if cfg.rel_paced && cfg.input_backend == crate::config::InputBackend::DbusRel {
        tokio::spawn(crate::rel_bridge::run_pacer(
            cap.clone(),
            cfg.clone(),
            std::sync::Arc::downgrade(&mouse),
        ));
    }

    // Outer loop: (re)generate cert, (re)bind endpoint, serve until the rotation
    // deadline, then rebuild on the same UDP port.
    loop {
        let bundle = cert::generate(&cfg)?;
        cert::publish(&cfg, &bundle)?;

        let mut quic_transport = QuicTransportConfig::default();
        quic_transport
            .initial_mtu(QUIC_MAX_UDP_PAYLOAD)
            .min_mtu(QUIC_MAX_UDP_PAYLOAD)
            .mtu_discovery_config(None);
        // B2 (2026-07-17): BBR paces the send rate to the measured delivery
        // rate instead of filling the queue until loss (quinn's CUBIC default)
        // — on a bufferbloated 5G/WireGuard path (measured 42 ms unloaded vs
        // 510 ms loaded) video RTT stays near the floor and the ABR
        // rtt-excess signal stays honest. SH_CC=cubic restores the default.
        if cfg.cc_bbr {
            quic_transport.congestion_controller_factory(Arc::new(
                wtransport::quinn::congestion::BbrConfig::default(),
            ));
        }
        let mut config = ServerConfig::builder()
            .with_bind_default(cfg.udp_port)
            .with_custom_transport(bundle.identity, quic_transport)
            .keep_alive_interval(Some(Duration::from_secs(3)))
            .build();
        // EndpointConfig governs the largest UDP payload we accept and the
        // max_udp_payload_size transport parameter sent to the peer. Together
        // with the fixed TransportConfig above, neither direction can grow past
        // the conservative ceiling.
        config
            .quic_endpoint_config_mut()
            .max_udp_payload_size(QUIC_MAX_UDP_PAYLOAD)?;
        let server = Endpoint::server(config)?;
        eprintln!(
            "LISTENING udp/{} tile={} audio={} quic_udp_payload={} mtud=off cc={}",
            cfg.udp_port,
            cfg.tile,
            audio.is_some(),
            QUIC_MAX_UDP_PAYLOAD,
            if cfg.cc_bbr { "bbr" } else { "cubic" },
        );

        let deadline = tokio::time::sleep(rotate_after);
        tokio::pin!(deadline);

        loop {
            tokio::select! {
                incoming = server.accept() => {
                    let cfg = cfg.clone();
                    let cap = cap.clone();
                    let enc = enc.clone();
                    let audio = audio.clone();
                    let abr = abr.clone();
                    let pauser = pauser.clone();
                    let input_router = input_router.clone();
                    let mouse = mouse.clone();
                    tokio::spawn(async move {
                        if let Err(e) = handle_session(incoming, cfg, cap, enc, audio, abr, pauser, input_router, mouse).await {
                            eprintln!("[transport] session error: {e:?}");
                        }
                    });
                }
                _ = &mut deadline => {
                    eprintln!("[cert] rotation deadline; rebuilding endpoint with a fresh cert");
                    break;
                }
            }
        }

        // Free the UDP socket before rebinding the same port.
        drop(server);
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}

// Each param is a distinct piece of per-session state (capture/encoder/audio/abr/
// pauser/input-router) threaded through one WebTransport session handler; bundling
// them into a struct is a bigger structural change than this hygiene pass covers.
#[allow(clippy::too_many_arguments)]
async fn handle_session(
    incoming: IncomingSession,
    cfg: Arc<Config>,
    cap: Capture,
    enc: Arc<EncoderOut>,
    audio: Option<AudioOut>,
    abr: Arc<Abr>,
    pauser: Option<Arc<crate::idle::IdlePauser>>,
    input_router: Option<Arc<crate::realtime_input::InputRouter>>,
    mouse: input::SharedMouse,
) -> Result<()> {
    let req = incoming.await?;
    eprintln!("[transport] SESSION path={}", req.path());
    // Media-plane gate. Inert on the LAN (SH_SESSION_KEY unset); on a station whose
    // UDP port is published, an unticketed session is refused BEFORE accept() —
    // this session would otherwise carry the guest's input plane, not just video.
    if let Err(why) = crate::session_ticket::admit(&cfg, req.path()) {
        eprintln!("[transport] SESSION_REJECTED reason={why}");
        req.forbidden().await;
        return Ok(());
    }
    let conn = Arc::new(req.accept().await?);
    eprintln!(
        "[transport] SESSION_ACCEPTED addr={}",
        conn.remote_address()
    );

    // AUTO-PAUSE: resume a paused guest FIRST — before priming/keyframe work —
    // so the joiner's forced IDR captures the live (resuming) screen. The RAII
    // guard reports the session end on every exit path below, which starts the
    // idle-pause grace clock once the last session is gone.
    let _pause_guard = match &pauser {
        Some(p) => {
            p.session_started().await;
            Some(crate::idle::SessionGuard::new(p.clone()))
        }
        None => None,
    };

    // Register this session with the ABR aggregate (T_STATS reports fold in here).
    let sess_id = abr.register();
    // Server-side tx-byte counter for this session (measured_send_kbps, KIND_PARAMS
    // subtype 2). Incremented on every AU we successfully hand to a uni-stream.
    let tx_bytes = Arc::new(AtomicU64::new(0));
    // L-1: cumulative per-session egress SKIPS — non-key AUs the backlog gate drops
    // plus wholesale broadcast-ring overruns (Lagged). Surfaced to the client over
    // KIND_PARAMS subtype 2 (so it subtracts them from its gap-derived loss) and to
    // the ABR controller (the server-authoritative backlog signal). Stays 0 on a LAN
    // (the gate never skips there), so every downstream use is a no-op there.
    let skip_count = Arc::new(AtomicU64::new(0));

    // The abs->rel model is DAEMON-WIDE (created in serve()); a new client session
    // re-arms only its own per-connection fields and keeps the tracked guest
    // position, so a browser reload continues tracking without a corner-chase.
    mouse.lock().await.reset_for_session();

    // MOVE COALESCER for the dbus (abs/rel) stations — mirrors warpd.rs. The datagram
    // receive loop must NOT apply each move as an awaited dbus call_method
    // (SetAbsPosition/RelMotion waits for a QEMU method REPLY), because at
    // pointer-lock move rates (~1 record per mousemove, up to ~1 kHz) that serializes
    // the loop on the reply RTT and a backlog of SUPERSEDED positions piles up in
    // quinn -> the guest cursor lags behind + rubber-bands. Instead we funnel move
    // records into an mpsc; a drain-coalesce task takes ALL pending each wakeup, keeps
    // the LATEST absolute (type 1) / SUMS relative deltas (type 4), and issues ONE
    // dbus inject — so a burst collapses to the freshest position and receive_datagram
    // is never throttled. Buttons/keys/wheel ride the reliable stream and are never
    // pooled here. Warpd stations skip this (warpd.rs already coalesces downstream).
    let move_tx = if matches!(
        cfg.input_backend,
        crate::config::InputBackend::DbusAbs | crate::config::InputBackend::DbusRel
    ) {
        // Item = (bytes, recv Instant for telemetry age; None when telemetry off).
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(Vec<u8>, Option<Instant>)>();
        let cap = cap.clone();
        let cfg = cfg.clone();
        let mouse = mouse.clone();
        tokio::spawn(async move {
            while let Some(first) = rx.recv().await {
                let mut batch = vec![first];
                while let Ok(m) = rx.try_recv() {
                    batch.push(m);
                }
                let (batch_len, oldest) = (batch.len() as u64, batch[0].1);
                let mut last_abs: Option<Vec<u8>> = None;
                let (mut sdx, mut sdy, mut have_rel) = (0i32, 0i32, false);
                for (rec, _) in &batch {
                    match rec.first() {
                        Some(1) if rec.len() >= 5 => last_abs = Some(rec.clone()),
                        Some(4) if rec.len() >= 5 => {
                            sdx += i16::from_le_bytes([rec[1], rec[2]]) as i32;
                            sdy += i16::from_le_bytes([rec[3], rec[4]]) as i32;
                            have_rel = true;
                        }
                        _ => {}
                    }
                }
                let t0 = crate::input_telemetry::enabled().then(Instant::now);
                if let Some(rec) = last_abs {
                    input::handle(&cap, &cfg, &mouse, None, &rec).await;
                } else if have_rel {
                    let dx = sdx.clamp(i16::MIN as i32, i16::MAX as i32) as i16;
                    let dy = sdy.clamp(i16::MIN as i32, i16::MAX as i32) as i16;
                    let mut rec = vec![4u8, 0, 0, 0, 0];
                    rec[1..3].copy_from_slice(&dx.to_le_bytes());
                    rec[3..5].copy_from_slice(&dy.to_le_bytes());
                    input::handle(&cap, &cfg, &mouse, None, &rec).await;
                }
                if let Some(t0) = t0 {
                    let age = oldest.map(|o| t0.saturating_duration_since(o).as_micros() as u64);
                    let rtt = t0.elapsed().as_micros() as u64;
                    crate::input_telemetry::record_inject("dbus", batch_len, rtt, age);
                }
                if cfg.abs_pace_ms > 0 {
                    tokio::time::sleep(Duration::from_millis(cfg.abs_pace_ms)).await;
                }
            }
        });
        Some(tx)
    } else {
        None
    };

    // ---- datagrams: mouse-move + RTT ping echo + T_STATS feedback ----
    {
        let conn = conn.clone();
        let cap = cap.clone();
        let cfg = cfg.clone();
        let mouse = mouse.clone();
        let input_router = input_router.clone();
        let abr = abr.clone();
        let move_tx = move_tx.clone();
        let skip_count = skip_count.clone();
        tokio::spawn(async move {
            while let Ok(dg) = conn.receive_datagram().await {
                let p = dg.payload();
                if p.is_empty() {
                    continue;
                }
                if p[0] == 9 {
                    let _ = conn.send_datagram(p.clone()); // RTT ping: echo verbatim
                } else if p[0] == OP_STATS {
                    // CLIENT->SERVER ABR feedback (SECTION 3.1); intercept
                    // BEFORE input::handle so opcode 10 never reaches input.
                    if let Some(r) = crate::abr::parse_report(&p) {
                        abr.submit(sess_id, r, skip_count.load(Ordering::Relaxed));
                    }
                } else if let (Some(tx), true) = (&move_tx, p[0] == 1 || p[0] == 4) {
                    // Move -> coalescer (never blocks). Instant only when tel on.
                    let at = crate::input_telemetry::enabled().then(Instant::now);
                    let _ = tx.send((p.to_vec(), at));
                } else {
                    input::handle(&cap, &cfg, &mouse, input_router.as_ref(), &p).await;
                }
            }
        });
    }

    // ---- LEGACY reliable input: client opens ONE bidi stream, all classes
    // interleaved as length-prefixed records. Kept running unconditionally so an
    // old UI still drives input. A new
    // client that uses per-type uni streams simply never opens a bidi, so this loop
    // idles harmlessly. `has_tag=false`: no leading class byte on this framing.
    {
        let conn = conn.clone();
        let cap = cap.clone();
        let cfg = cfg.clone();
        let mouse = mouse.clone();
        let input_router = input_router.clone();
        tokio::spawn(async move {
            while let Ok((_send, recv)) = conn.accept_bi().await {
                let cap = cap.clone();
                let cfg = cfg.clone();
                let mouse = mouse.clone();
                let input_router = input_router.clone();
                tokio::spawn(async move {
                    drain_input_stream(recv, &cap, &cfg, &mouse, input_router.as_ref(), false)
                        .await;
                });
            }
        });
    }

    // ---- PER-TYPE reliable input (HOL avoidance): the client opens ONE
    // unidirectional reliable stream PER input class, each led by a 1-byte class tag
    // (ICLASS_KEY/BUTTON/WHEEL/CONTROL) then the same [len u16 | record] framing. A
    // retransmit on one class's stream can't stall another's. Each accepted stream
    // gets its own reader task with a CLONE of the shared per-session `mouse` state,
    // so keys/buttons/wheel still reach input::handle in per-class order and the
    // abs->rel pointer state stays coherent with the datagram (moves) task.
    // `has_tag=true`: the first byte of the stream is the class tag. Always on:
    // the shipped UI opens per-class uni streams unconditionally, so disabling
    // this router (the old SH_INPUT_STREAMS=off) silently killed all reliable
    // input; the knob was removed 2026-07-14.
    {
        let conn = conn.clone();
        let cap = cap.clone();
        let cfg = cfg.clone();
        let mouse = mouse.clone();
        let input_router = input_router.clone();
        tokio::spawn(async move {
            while let Ok(recv) = conn.accept_uni().await {
                let cap = cap.clone();
                let cfg = cfg.clone();
                let mouse = mouse.clone();
                let input_router = input_router.clone();
                tokio::spawn(async move {
                    drain_input_stream(recv, &cap, &cfg, &mouse, input_router.as_ref(), true).await;
                });
            }
        });
    }

    // ---- audio: one Opus packet per uni-stream (kind=2) ----
    if let Some(audio) = audio {
        let conn = conn.clone();
        let mut arx = audio.tx.subscribe();
        tokio::spawn(async move {
            loop {
                match arx.recv().await {
                    Ok(pkt) => {
                        if send_audio(&conn, &pkt).await.is_err() {
                            break;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => break,
                }
            }
        });
    }

    // ---- video: one AU per uni-stream (kind=1) ----
    // Subscribe FIRST so we don't miss the fresh IDR our keyframe request triggers,
    // THEN ask the encoder to force one ASAP (keyframe-on-connect). The client
    // (streamClient.feedVideoAU) drops every delta until it sees a `key` AU, so a
    // joiner must get a keyframe promptly or it stays on the poster. Two things
    // guarantee that now: (1) the freshest cached keyframe below primes instant
    // go-live, and (2) request_keyframe() + the wall-clock heartbeat deliver a
    // fresh, correctly-chained IDR within <= keyframe_ms that the decoder locks
    // onto cleanly (the primed cached IDR alone can be up to a heartbeat stale).
    // ---- SERVER->CLIENT encoder-params push (KIND_PARAMS subtype 1) ----
    // Watch the encoder's params_gen: it bumps at connect (first observation),
    // on every ABR tier restart, and on first-SPS refinement. Push subtype-1 on
    // each change so the client keeps its VideoDecoder codec string in sync.
    {
        let conn = conn.clone();
        let enc = enc.clone();
        tokio::spawn(async move {
            let mut last_gen = u64::MAX;
            loop {
                let g = enc.params_gen();
                if g != last_gen {
                    last_gen = g;
                    if send_params_encoder(&conn, &enc.params()).await.is_err() {
                        break;
                    }
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        });
    }

    // ---- SERVER->CLIENT server-stats for the HUD (KIND_PARAMS subtype 2, 1 Hz) ----
    {
        let conn = conn.clone();
        let enc = enc.clone();
        let abr = abr.clone();
        let tx_bytes = tx_bytes.clone();
        let skip_count = skip_count.clone();
        tokio::spawn(async move {
            let mut last_bytes = 0u64;
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let now_bytes = tx_bytes.load(Ordering::Relaxed);
                let send_kbps = ((now_bytes.saturating_sub(last_bytes)) * 8 / 1000) as u32;
                last_bytes = now_bytes;
                // wtransport 0.7 exposes only rtt(); cwnd/lost need the `quinn`
                // feature (not enabled) -> published as 0 per the spec fallback.
                let path_rtt_us = conn.rtt().as_micros().min(u32::MAX as u128) as u32;
                let (ls, os, bs, ov) = abr.session_scores(sess_id).unwrap_or((0, 0, 0, 0));
                // L-1: cumulative egress skips (append-only wire tail) so the client
                // subtracts server-intentional skips from its gap-derived loss.
                let skipped = skip_count.load(Ordering::Relaxed).min(u32::MAX as u64) as u32;
                let p = enc.params();
                if send_params_stats(
                    &conn,
                    &p,
                    send_kbps,
                    path_rtt_us,
                    0,
                    0,
                    ls,
                    os,
                    bs,
                    ov,
                    skipped,
                )
                .await
                .is_err()
                {
                    break;
                }
            }
        });
    }

    let vt = video_trace();
    let mut rx = enc.tx.subscribe();
    if vt {
        eprintln!(
            "[vtrace] subscribed (receivers={})",
            enc.tx.receiver_count()
        );
    }
    enc.request_keyframe();
    if vt {
        eprintln!("[vtrace] keyframe requested; locking last_key");
    }
    let primed = enc.last_key.lock().await.clone();
    if vt {
        eprintln!("[vtrace] last_key lock ok; primed={}", primed.is_some());
    }
    // B1: frame_id of the last AU relayed to THIS session, the `sent` half of
    // the sent-acked backlog estimate (see transport/backlog.rs).
    let mut last_sent_id: u32 = 0;
    if let Some(k) = primed {
        let r = send_au(&conn, &k).await;
        if vt {
            eprintln!(
                "[vtrace] primed key frame_id={} sent ok={}",
                k.frame_id,
                r.is_ok()
            );
        }
        if r.is_ok() {
            tx_bytes.fetch_add((10 + k.data.len()) as u64, Ordering::Relaxed);
            last_sent_id = k.frame_id;
        }
    }
    // JOIN GATE (2026-07-11): relay nothing to this session until the first
    // broadcast KEYFRAME. On a busy station the broadcast resumes mid-GOP: every
    // frame between the primed cached key and the subscription point was never
    // delivered here (measured on freedos: primed id=423, first broadcast
    // id=453), so relaying those deltas hands the decoder up to keyframe_ms of
    // broken references — some decoders paint corruption, WebCodecs can error
    // out. request_keyframe() above now forces a real IDR within ~1 frame
    // (encode.rs keyframe-on-connect), so this gate discards almost nothing;
    // the primed key still paints instantly and the forced IDR restarts a
    // correctly-chained stream. Steady-state relay after the first key is
    // byte-for-byte unchanged.
    let mut gate = JoinGate::new();
    // BOUNDED EGRESS BACKLOG (B1, 2026-07-17): the ring alone drops nothing
    // until it laps (~12.8 s @ 20 fps), so on a bufferbloated WAN path a
    // session used to stream seconds-stale frames and resume mid-GOP after
    // every overrun. The gate below skips stale non-key AUs while the session
    // is more than the effective backlog bound (SH_SEND_MAX_BACKLOG scaled
    // with fps, see backlog.rs) ahead of the client's acked pointer, and
    // forces every skip/Lagged episode to end on a clean IDR. LAN sessions
    // measure behind well under the bound, so their relay is byte-identical.
    let mut backlog_gate = BacklogGate::new(cfg.send_max_backlog, cfg.fps);
    loop {
        match rx.recv().await {
            Ok(au) => {
                // SH_SEND_MAX_BACKLOG=0 rollback: skip the whole behind
                // estimate — the legacy hot loop did no per-AU clock reads or
                // ABR-mutex traffic here, and the rollback knob must restore
                // exactly that, not just the legacy verdicts.
                if backlog_gate.enabled() {
                    let now = Instant::now();
                    let behind = session_backlog(
                        abr.client_last_frame_id(sess_id),
                        last_sent_id,
                        rx.len(),
                        now,
                    );
                    match backlog_gate.on_au(au.is_key, behind, now) {
                        RelayVerdict::Skip => {
                            skip_count.fetch_add(1, Ordering::Relaxed);
                            if vt {
                                eprintln!(
                                    "[vtrace] backlog-skip frame_id={} behind={behind}",
                                    au.frame_id
                                );
                            }
                            continue;
                        }
                        RelayVerdict::ResumeOnDelta { rekey } => {
                            // Everything since the skip references frames this
                            // session never sent: discard deltas until a fresh
                            // IDR (re-armed gate) and ask the encoder for one
                            // now — same call as session-join, coalesced
                            // encoder-side.
                            gate = JoinGate::new();
                            if rekey {
                                enc.request_keyframe();
                            }
                            if vt {
                                eprintln!(
                                    "[vtrace] backlog-resume frame_id={} rekey={rekey}",
                                    au.frame_id
                                );
                            }
                        }
                        RelayVerdict::ResumeOnKey => {
                            if vt {
                                eprintln!(
                                    "[vtrace] backlog-resume frame_id={} on-key",
                                    au.frame_id
                                );
                            }
                        }
                        RelayVerdict::Relay => {}
                    }
                }
                if !gate.admit(au.is_key) {
                    if vt {
                        eprintln!(
                            "[vtrace] join-gate discard frame_id={} (pre-key delta)",
                            au.frame_id
                        );
                    }
                    continue;
                }
                if vt {
                    eprintln!(
                        "[vtrace] recv frame_id={} key={} len={}; sending",
                        au.frame_id,
                        au.is_key,
                        au.data.len()
                    );
                }
                let r = send_au(&conn, &au).await;
                if vt {
                    eprintln!("[vtrace] sent frame_id={} ok={}", au.frame_id, r.is_ok());
                }
                if r.is_err() {
                    break;
                }
                tx_bytes.fetch_add((10 + au.data.len()) as u64, Ordering::Relaxed);
                last_sent_id = au.frame_id;
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                backlog_gate.on_lagged();
                // Wholesale ring overrun: n frames vanished before the relay saw
                // them — count them as skips too so the client's gap for this lap is
                // attributed to the server, not to network loss.
                skip_count.fetch_add(n, Ordering::Relaxed);
                if vt {
                    eprintln!("[vtrace] lagged {n}");
                }
                continue;
            }
            Err(_) => break,
        }
    }
    abr.unregister(sess_id);
    eprintln!("[transport] SESSION_ENDED");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::JoinGate;

    /// Busy-station join (the 2026-07-11 freedos bug): the broadcast resumes
    /// mid-GOP, so every delta before the first key must be discarded, then
    /// everything relays.
    #[test]
    fn join_gate_discards_pre_key_deltas() {
        let mut g = JoinGate::new();
        assert!(!g.admit(false)); // mid-GOP delta -> discard
        assert!(!g.admit(false)); // still pre-key -> discard
        assert!(g.admit(true)); // first keyframe -> relay
        assert!(g.admit(false)); // chained delta -> relay
        assert!(g.admit(true)); // later keyframes -> relay
        assert!(g.admit(false));
    }

    /// Idle-station join: the keyframe-on-connect IDR is the first broadcast AU,
    /// so the gate must be transparent from the very first frame.
    #[test]
    fn join_gate_transparent_when_stream_starts_on_key() {
        let mut g = JoinGate::new();
        assert!(g.admit(true));
        assert!(g.admit(false));
        assert!(g.admit(false));
    }
}
