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
mod datagram;
mod egress;
mod input_bench;
mod input_stream;

use backlog::{session_backlog, BacklogGate, RelayVerdict};
use datagram::{spawn_datagram_plane, DatagramCtx};
use egress::{send_au, send_audio, send_params_encoder, send_params_stats};
use input_bench::spawn_input_bench;
use input_stream::{spawn_bi_readers, spawn_uni_readers, SessionInputCtx};

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

    // Held-key teardown reaper (key_state.rs), ONE per station like the pacer
    // above — see its module doc for why sessions get their OWN fresh
    // `KeyState` yet release through this one shared channel/task.
    let (key_reap_tx, key_reap_rx) = tokio::sync::mpsc::unbounded_channel();
    tokio::spawn(crate::key_state::run_reaper(
        cap.clone(),
        cfg.clone(),
        input_router.clone(),
        key_reap_rx,
    ));

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
                    let key_reap_tx = key_reap_tx.clone();
                    tokio::spawn(async move {
                        if let Err(e) = handle_session(incoming, cfg, cap, enc, audio, abr, pauser, input_router, mouse, key_reap_tx).await {
                            // No ctx: the session's own context died with it,
                            // and inventing one here would manufacture a
                            // correlation that joins to nothing. The record is
                            // still searchable by station and severity, which
                            // is what "which station is failing sessions" needs.
                            crate::sh_log!(
                                crate::trace::Level::Error,
                                None,
                                "[transport] session error: {e:?}"
                            );
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
    key_reap_tx: tokio::sync::mpsc::UnboundedSender<Vec<u16>>,
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
    // The browser's trace id rides the session path's query string — the input
    // plane has no headers to carry it (contract §3). Parsed BEFORE accept so
    // the session span starts where the session does; `None` means this becomes
    // a ROOT rather than a fabricated child (contract §7). The ticket half of
    // the path is never read here and never reaches a span.
    let trace_parent = crate::trace::context::from_wt_path(req.path());
    let conn = Arc::new(req.accept().await?);
    crate::probes::probe!(TRANSPORT_WT_SESSION);
    let (strace, mut session_span) = crate::trace_session::begin(
        trace_parent,
        "webtransport",
        cfg.capture_backend.as_str(),
        cfg.input_backend.as_str(),
    );
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
            // `guest.resume` — the emulator span that answers "was it slow
            // because the machine was asleep". The belief is read BEFORE the
            // resume, which clears it.
            crate::trace_session::guest_resume(
                strace.ctx(),
                crate::idle::guest_believed_paused(),
                if cfg.capture_backend.is_qemu() {
                    "qmp"
                } else {
                    "signal"
                },
                p.session_started(),
            )
            .await;
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
    // ...and the CONGESTION half of the same story, reported to nobody but the ABR
    // controller. `skip_count` above answers "what did the relay withhold from this
    // client", which the HUD wants and which must include the join gate. The ladder
    // must NOT: a join-gate discard is the cost of starting a session cleanly, it
    // happens once, in the first milliseconds, and feeding a ~30-frame burst of it
    // into `skip_rate_ewma` would let a connect read as sustained egress backlog the
    // moment SH_ABR_BACKLOG_DOWNSHIFT is ever armed. Only the backlog gate and a
    // ring overrun — the two things that mean "this session cannot keep up" —
    // increment this one.
    let congestion_skips = Arc::new(AtomicU64::new(0));

    // The abs->rel model is DAEMON-WIDE (created in serve()); a new client session
    // re-arms only its own per-connection fields and keeps the tracked guest
    // position, so a browser reload continues tracking without a corner-chase.
    mouse.lock().await.reset_for_session();

    // OPPOSITE of `mouse` above: genuinely per-session, fresh every time (see
    // key_state.rs). `Drop` queues whatever is still held once the LAST
    // clone below is gone — every exit from this session, abrupt or not.
    let keys = crate::key_state::new_session(key_reap_tx);

    // The DATAGRAM plane (moves, the RTT ping echo, T_STATS) — its own module so
    // the one loop that must never block has one place to be read. See
    // `transport/datagram.rs`.
    spawn_datagram_plane(DatagramCtx {
        conn: conn.clone(),
        cfg: cfg.clone(),
        cap: cap.clone(),
        mouse: mouse.clone(),
        keys: keys.clone(),
        input_router: input_router.clone(),
        abr: abr.clone(),
        skip_count: congestion_skips.clone(),
        strace: strace.clone(),
        sess_id,
    });

    // Bundle for the two reliable-input acceptors below (input_stream.rs):
    // one clone per accepted stream instead of five.
    let input_ctx = SessionInputCtx {
        cap: cap.clone(),
        cfg: cfg.clone(),
        mouse: mouse.clone(),
        keys: keys.clone(),
        input_router: input_router.clone(),
    };

    // LEGACY reliable input: client opens ONE bidi stream, all classes
    // interleaved as length-prefixed records. Kept running unconditionally
    // so an old UI still drives input; a client that uses per-type uni
    // streams simply never opens a bidi, so this idles harmlessly.
    spawn_bi_readers(conn.clone(), input_ctx.clone(), strace.clone());

    // PER-TYPE reliable input (HOL avoidance): the client opens ONE
    // unidirectional reliable stream PER input class (ICLASS_KEY/BUTTON/
    // WHEEL/CONTROL), each a retransmit-isolated class so one can't stall
    // another. Always on -- the shipped UI opens these unconditionally.
    spawn_uni_readers(conn.clone(), input_ctx, strace.clone());

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
    // Set only on a daemon-internal fault; a client that simply left is not one.
    let mut fault: Option<&'static str> = None;
    // PER-SESSION WIRE FRAME IDs (2026-09-02). The id on the wire counts the AUs
    // THIS session was sent, starting at 0 — it is NOT the encoder's `au.frame_id`.
    //
    // WHY: the client derives its loss percentage from frame_id gaps (spa
    // videoDecode.ts feedVideoAU), and that percentage is what it reports back in
    // T_STATS for abr.rs to steer the ladder with. The ENCODER id is shared by every
    // viewer of the station and is wrong for a single session in three ways:
    //   * SESSION START — the primed cached key carries whatever id it was encoded
    //     with, and the join gate below then discards every mid-GOP delta until the
    //     first broadcast keyframe. Measured on freedos: primed id=423, first
    //     relayed id=453. The client saw one AU, then a 29-frame hole, and reported
    //     45-87 % loss for its first interval on a flawless LAN.
    //   * TIER CHANGE — encode/worker.rs sets `frame_id = 0` on every Reopen, so an
    //     ABR step rewinds the id space under a session that never lost anything.
    //   * OTHER VIEWERS — a second viewer's join keyframe and its input burst make
    //     the relay skip AUs for the FIRST viewer (backlog gate / ring overrun), and
    //     the 1 Hz KIND_PARAMS subtype-2 skip credit arrives up to a second after the
    //     gaps it explains, far too late for the client's 100 ms accounting ticks.
    //     The operator's win95 tab read 93-96 % "loss" at 19:17 for exactly this.
    // Counting what we actually SENT removes all three at the source: a gap that
    // reaches the client is now a gap the wire made, and nothing else. The skip
    // counter below is unchanged and still reported (HUD + the server-authoritative
    // ABR backlog signal); it simply no longer has to race the frames it explains.
    let mut out_id: u32 = 0;
    // B1: wire id of the last AU relayed to THIS session, the `sent` half of the
    // sent-acked backlog estimate (see transport/backlog.rs). The client's acked
    // `last_frame_id` is in the same session-local space, so the two are directly
    // comparable — which they were NOT while an encoder reopen could rewind one of
    // them to 0 mid-session.
    let mut last_sent_id: u32 = 0;
    if let Some(k) = primed {
        let r = send_au(&conn, &k, out_id).await;
        if vt {
            eprintln!(
                "[vtrace] primed key f={out_id} (enc {}) sent ok={}",
                k.frame_id,
                r.is_ok()
            );
        }
        if r.is_ok() {
            tx_bytes.fetch_add((10 + k.data.len()) as u64, Ordering::Relaxed);
            last_sent_id = out_id;
            out_id = out_id.wrapping_add(1);
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
                            congestion_skips.fetch_add(1, Ordering::Relaxed);
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
                    // A pre-key delta withheld from THIS session is a server
                    // skip like any other: count it so the HUD and the ABR
                    // backlog signal see the whole picture. (The client no
                    // longer needs it to explain a gap — the wire id above
                    // never had one — but "what the relay dropped" must still
                    // be one honest number.)
                    skip_count.fetch_add(1, Ordering::Relaxed);
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
                // One-shot marks: an AtomicBool swap per AU, never a span per
                // frame (trace/mod.rs states the rule and why).
                strace.mark_first_au(out_id, au.is_key);
                // Sampled-input EFFECT, half 1 of 2: one relaxed load unless a
                // sampled edge is pending (input_trace.rs / trace_session.rs).
                strace.effect_encoded(out_id, au.is_key, au.encode_us);
                let r = send_au(&conn, &au, out_id).await;
                if vt {
                    eprintln!(
                        "[vtrace] sent f={out_id} (enc {}) ok={}",
                        au.frame_id,
                        r.is_ok()
                    );
                }
                if r.is_err() {
                    break;
                }
                tx_bytes.fetch_add((10 + au.data.len()) as u64, Ordering::Relaxed);
                strace.mark_first_send(au.data.len());
                // Half 2 of 2: closes the window `effect_encoded` peeked at. A
                // `Some` means THIS au answered a sampled edge — tell the
                // client which frame_id it was so it can close the return leg
                // (RETURN LEG doc, trace_session.rs header). Spawned: the mark
                // is its own tiny uni-stream and must never make the next
                // video AU wait on it.
                // The mark names the id the CLIENT will see, not the encoder's.
                if let Some(effect_ctx) = strace.effect_sent(out_id, au.data.len()) {
                    egress::spawn_frame_mark(conn.clone(), effect_ctx, out_id);
                }
                last_sent_id = out_id;
                out_id = out_id.wrapping_add(1);
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                backlog_gate.on_lagged();
                // Wholesale ring overrun: n frames vanished before the relay saw
                // them — count them as skips too so the client's gap for this lap is
                // attributed to the server, not to network loss.
                skip_count.fetch_add(n, Ordering::Relaxed);
                congestion_skips.fetch_add(n, Ordering::Relaxed);
                if vt {
                    eprintln!("[vtrace] lagged {n}");
                }
                continue;
            }
            Err(_) => {
                // The encoder's broadcast SENDER is gone: a daemon-internal
                // fault, unlike the send failure above, which is just a visitor
                // closing the tab. Only the former makes the session a red span.
                fault = Some("encoder stream closed");
                break;
            }
        }
    }
    abr.unregister(sess_id);
    eprintln!("[transport] SESSION_ENDED");
    match fault {
        Some(f) => session_span.error(f),
        None => session_span.ok(),
    };
    session_span.end();
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
