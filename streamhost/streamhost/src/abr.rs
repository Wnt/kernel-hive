// Adaptive-bitrate controller (SECTION 2, GFN-style tier restart).
//
// MODEL: the client MEASURES + REPORTS (datagram opcode T_STATS=10 @ ~100 ms);
// the server STEPS. One in-process encoder per station is broadcast to ALL sessions,
// so the ABR tier is GLOBAL per station. This controller aggregates across connected sessions
// using the WORST (minimum smoothed overall) client to protect the weakest
// viewer; a tier restart's fresh IDR re-syncs everyone at once.
//
// The per-session SCORES (latency/loss/bandwidth/overall) are ported from the
// client `el` scorer (SECTION 2.3) and are still computed for the HUD, but the
// TIER DECISION is now driven ONLY by genuine NETWORK-congestion signals:
//   * sustained packet LOSS (client loss_pct, derived from frame_id gaps), and
//   * sustained RTT GROWTH above the path floor (bufferbloat).
// Decode-side metrics (decode_ms / decode_fps / decode_queue) are DELIBERATELY
// excluded from the downshift decision: a busy client decoding large 1920x1200
// frames can be legitimately slow (high decode_ms, growing queue, the odd freeze)
// with a perfectly healthy network, and must NOT drag the whole station down. We also
// never treat low fps as degradation (museum caveat 2.4: idle stations emit ~2 fps).
//
// STABILITY (anti-oscillation), all four properties hold together:
//   1. NETWORK-ONLY downshift (loss / rtt-growth), never decode-side alone.
//   2. PERSISTENCE: a breach must hold for BREACH_MS (>= 3 report intervals,
//      ~1.5 s) before it counts — a single noisy sample is ignored.
//   3. DWELL: `abr_min_restart_ms` (default 25 s) between ANY two tier changes, so
//      the tier physically cannot ping-pong.
//   4. ASYMMETRIC HYSTERESIS: the downshift thresholds are far worse than the
//      upshift thresholds (wide dead-band), so a metric hovering near a boundary
//      never oscillates. On a LAN (near-zero loss, low RTT) the tier stays at 0.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::config::Config;
use crate::encode::EncoderOut;

/// One parsed CLIENT->SERVER T_STATS report (SECTION 3.1, 29 bytes, little-endian).
/// Some fields are parsed but not yet consumed by the controller (wired for the
/// HUD / future scoring inputs) — keep them; the wire format is fixed.
/// `last_frame_id` feeds the B1 bounded-egress-backlog policy via
/// `Abr::client_last_frame_id` (transport/backlog.rs).
#[allow(dead_code)]
#[derive(Clone, Copy, Default)]
pub struct Report {
    pub seq: u32,
    pub rtt_ms: u16,
    pub recv_kbps: u32,
    pub decode_ms_x10: u16,
    pub decode_fps_x10: u16,
    pub decode_queue: u16,
    pub frames_dropped: u32,
    pub freeze_count: u16,
    pub loss_pct_x10: u16,
    pub last_frame_id: u32,
}

/// Parse a 29-byte T_STATS datagram (opcode byte already checked == 10).
pub fn parse_report(p: &[u8]) -> Option<Report> {
    if p.len() < 29 || p[0] != 10 {
        return None;
    }
    let u16le = |o: usize| u16::from_le_bytes([p[o], p[o + 1]]);
    let u32le = |o: usize| u32::from_le_bytes([p[o], p[o + 1], p[o + 2], p[o + 3]]);
    Some(Report {
        seq: u32le(1),
        rtt_ms: u16le(5),
        recv_kbps: u32le(7),
        decode_ms_x10: u16le(11),
        decode_fps_x10: u16le(13),
        decode_queue: u16le(15),
        frames_dropped: u32le(17),
        freeze_count: u16le(21),
        loss_pct_x10: u16le(23),
        last_frame_id: u32le(25),
    })
}

/// Per-session smoothed scores + the raw state the scorer needs interval-to-interval.
struct SessionState {
    last: Report,
    last_seq: Option<u32>,
    init: bool,
    prev_freeze: u16,
    // EWMA (SECTION 2.3): latency/bandwidth m=16, loss m=8, overall m=4.
    lat_ewma: f32,
    loss_ewma: f32,
    bw_ewma: f32,
    overall_ewma: f32,
    rtt_ewma: f32,
    // ---- NETWORK-congestion decision signals (the only inputs to a downshift) ----
    /// Smoothed packet-loss percentage (m=8). Client loss_pct is derived from
    /// frame_id gaps, so this is genuine transport loss, not a decode stall.
    loss_pct_ewma: f32,
    /// Path RTT floor (ms): tracks the minimum smoothed RTT fast (down) and decays
    /// UP very slowly. `rtt_ewma - rtt_floor` is the congestion/bufferbloat excess,
    /// which stays ~0 on a LAN and only grows under real queueing delay.
    rtt_floor: f32,
    stale: Instant, // last time a fresh report was folded
    // ---- L-1 SERVER-AUTHORITATIVE backlog signal (not from the client) ----
    /// Cumulative per-session egress skips (relay drops) last seen — the server
    /// counts these itself (transport/mod.rs), the client is not involved.
    prev_server_skips: u64,
    /// Smoothed skip DELTA per report interval (m=8): a proxy for sustained
    /// egress backlog that stays ~0 on a LAN (the gate never skips there).
    skip_rate_ewma: f32,
    /// L-3: the session's FIRST real RTT sample (ms), ignoring the 0xFFFF
    /// "unknown" the client sends before its first ping resolves. Used only to
    /// seed the conservative start tier; None until a real sample arrives.
    first_real_rtt: Option<f32>,
}

impl SessionState {
    fn new() -> Self {
        SessionState {
            last: Report::default(),
            last_seq: None,
            init: false,
            prev_freeze: 0,
            lat_ewma: 100.0,
            loss_ewma: 100.0,
            bw_ewma: 100.0,
            overall_ewma: 100.0,
            rtt_ewma: 0.0,
            loss_pct_ewma: 0.0,
            rtt_floor: 0.0,
            stale: Instant::now(),
            prev_server_skips: 0,
            skip_rate_ewma: 0.0,
            first_real_rtt: None,
        }
    }
}

/// EWMA: lw(prev,new,m) = prev*(m-1)/m + new/m.
fn lw(prev: f32, new: f32, m: f32) -> f32 {
    prev * (m - 1.0) / m + new / m
}

struct Inner {
    sessions: HashMap<u64, SessionState>,
    tier: u8,
    /// Wall-clock of the last tier change; the DWELL gate is measured from here.
    last_restart: Instant,
    /// When the network first entered the CONGESTED region (loss/rtt breach); the
    /// breach must persist BREACH_MS from here before a downshift is taken.
    down_since: Option<Instant>,
    /// When the network first entered the fully-HEALTHY region; an upshift requires
    /// UP_HOLD sustained from here.
    up_since: Option<Instant>,
    /// L-3: the conservative-start seed has been attempted for the CURRENT active
    /// spell (reset when the station goes idle). Prevents re-seeding every tick.
    start_seeded: bool,
    /// L-3: when the current idle->active spell began (for the seed's RTT-wait
    /// timeout); None while no sessions are active.
    active_since: Option<Instant>,
}

// ---- Decision thresholds (asymmetric hysteresis: DOWN >> UP => wide dead-band) --
/// Downshift when smoothed loss reaches this % ...
const DOWN_LOSS_PCT: f32 = 5.0;
/// ... upshift only once smoothed loss is back at/below this % (5:1 dead-band).
const UP_LOSS_PCT: f32 = 1.0;
/// Downshift when RTT sits this many ms above the path floor (bufferbloat). On a
/// LAN the excess is ~0 ms, so this never fires; a distant WAN client's baseline
/// RTT is absorbed by rtt_floor, so only genuine queueing growth trips it.
const DOWN_RTT_EXCESS_MS: f32 = 80.0;
/// ... upshift only once the RTT excess is back at/below this many ms.
const UP_RTT_EXCESS_MS: f32 = 20.0;
/// A breach (either direction's condition) must persist this long to count as real
/// (>= 3 report intervals @ ~100 ms; comfortably >= 1.5 s).
const BREACH: Duration = Duration::from_millis(1500);
/// An RTT-ONLY breach must persist far longer than a loss breach (2026-08-17).
///
/// WHY: the client's RTT ping is a datagram on the SAME QUIC connection as the
/// video, so it queues behind whatever we just sent. Tier 0 is the one tier with
/// no bitrate ceiling (CQP, no VBV — encode/x264.rs), so a big station's ~2.5 s
/// heartbeat IDR is emitted as one unpaced burst and every ping measured during
/// it reads hundreds of ms. That is REAL queueing delay, but it is OURS, not the
/// network's, and "lower the bitrate" is the wrong response — it shrinks the
/// keyframe, the link reads healthy, we climb back to tier 0, and the burst
/// returns. tru64 rode that limit cycle 0->1->2->3->0 every 25 s on a 3 ms LAN.
///
/// A genuinely bufferbloated path holds RTT high CONTINUOUSLY, so it still trips
/// this; a per-keyframe burst cannot. Loss and backlog keep the short BREACH —
/// they are not self-inflicted, so they must still react fast.
const RTT_BREACH: Duration = Duration::from_secs(4);
/// A healthy window must persist this long before stepping the tier back up.
const UP_HOLD: Duration = Duration::from_secs(8);
/// L-1 backlog trigger (armed by SH_ABR_BACKLOG_DOWNSHIFT): downshift when the
/// smoothed per-report egress SKIP count (the relay dropping non-key AUs while a
/// session runs past its backlog bound) stays at/above this. On a LAN the gate
/// never skips, so `worst_skip` is ~0 and this can never fire.
const DOWN_SKIP_RATE: f32 = 1.5;
/// ... and only treat the link healthy-enough to UPSHIFT once skipping is back
/// at/below this (asymmetric dead-band, like the loss/rtt thresholds above).
const UP_SKIP_RATE: f32 = 0.3;

/// Pure backlog-signal contribution to the CONGESTED decision (L-1), split out so
/// the threshold logic is unit-testable without an Abr/EncoderOut. `armed` is
/// SH_ABR_BACKLOG_DOWNSHIFT; when off this is always false (loss/rtt-only, today).
fn skip_congested(worst_skip: f32, armed: bool) -> bool {
    armed && worst_skip >= DOWN_SKIP_RATE
}

/// Pure backlog-signal veto on the HEALTHY decision (L-1): while the trigger is
/// armed, a session still skipping must not read as healthy-enough to upshift.
fn skip_blocks_upshift(worst_skip: f32, armed: bool) -> bool {
    armed && worst_skip > UP_SKIP_RATE
}

/// L-3 RTT-keyed conservative START tier (pure, testable). `threshold_ms` is
/// SH_ABR_START_RTT_MS (0 disables → always tier 0). A WAN/5G connect opens at
/// tier 1 (>= threshold) or tier 2 (>= 2x) so it doesn't flood the queue with a
/// generous tier-0 keyframe before ABR reacts; a LAN connect (sub-ms) maps to 0.
fn start_tier_for_rtt(rtt_ms: f32, threshold_ms: u32) -> u8 {
    if threshold_ms == 0 {
        return 0;
    }
    let t = threshold_ms as f32;
    if rtt_ms >= 2.0 * t {
        2
    } else if rtt_ms >= t {
        1
    } else {
        0
    }
}

/// The global-per-station ABR controller.
pub struct Abr {
    inner: Mutex<Inner>,
    next_id: AtomicU64,
    cfg: Arc<Config>,
    enc: Arc<EncoderOut>,
}

/// Ladder max bitrate tier (SECTION 2.1): 0-2 keep native resolution, 3 steps down.
const MAX_TIER: u8 = 3;

impl Abr {
    pub fn new(cfg: Arc<Config>, enc: Arc<EncoderOut>) -> Arc<Self> {
        let now = Instant::now();
        Arc::new(Abr {
            inner: Mutex::new(Inner {
                sessions: HashMap::new(),
                tier: 0,
                last_restart: now,
                down_since: None,
                up_since: None,
                start_seeded: false,
                active_since: None,
            }),
            next_id: AtomicU64::new(1),
            cfg,
            enc,
        })
    }

    /// Register a new session; returns its id. Unregister on disconnect.
    pub fn register(&self) -> u64 {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        self.inner
            .lock()
            .unwrap()
            .sessions
            .insert(id, SessionState::new());
        id
    }

    pub fn unregister(&self, id: u64) {
        self.inner.lock().unwrap().sessions.remove(&id);
    }

    /// Fold a fresh report from a session into its smoothed scores. `server_skips`
    /// is the CUMULATIVE per-session egress-skip count the relay has taken for this
    /// session (transport/mod.rs) — folded into the L-1 backlog signal here so the
    /// controller can see congestion the client-reported loss no longer shows (the
    /// client subtracts the same skips from its loss, so skips never masquerade as
    /// network loss in either place).
    pub fn submit(&self, id: u64, r: Report, server_skips: u64) {
        let mut g = self.inner.lock().unwrap();
        if let Some(s) = g.sessions.get_mut(&id) {
            // Ignore stale/duplicate reports (unreliable datagram may reorder).
            if let Some(prev) = s.last_seq {
                if r.seq == prev {
                    return;
                }
            }
            s.last = r;
            s.last_seq = Some(r.seq);
            s.stale = Instant::now();
            fold(s, server_skips);
        }
    }

    /// B1 (bounded egress backlog): the session's acked consumption pointer —
    /// the last T_STATS `last_frame_id` (set by the client at AU-receive time,
    /// parsed in `parse_report`) plus the instant it was folded, so the relay
    /// loop can freshness-filter it. `sent - acked` measures exactly the
    /// network + quinn in-flight backlog for the session. None until the
    /// session's first report has been folded.
    pub fn client_last_frame_id(&self, id: u64) -> Option<(u32, Instant)> {
        let g = self.inner.lock().unwrap();
        let s = g.sessions.get(&id)?;
        s.last_seq?;
        Some((s.last.last_frame_id, s.stale))
    }

    /// Snapshot a session's smoothed scores for the HUD (latency, loss, bandwidth,
    /// overall), each 0..100.
    pub fn session_scores(&self, id: u64) -> Option<(u8, u8, u8, u8)> {
        let g = self.inner.lock().unwrap();
        g.sessions.get(&id).map(|s| {
            (
                s.lat_ewma.round().clamp(0.0, 100.0) as u8,
                s.loss_ewma.round().clamp(0.0, 100.0) as u8,
                s.bw_ewma.round().clamp(0.0, 100.0) as u8,
                s.overall_ewma.round().clamp(0.0, 100.0) as u8,
            )
        })
    }

    /// Spawn the evaluation loop (~100 ms). Steps the GLOBAL tier with hysteresis +
    /// cooldowns and drives the encoder via `EncoderOut::request_tier`.
    pub fn spawn_controller(self: Arc<Self>) {
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_millis(100));
            loop {
                ticker.tick().await;
                self.evaluate();
            }
        });
    }

    fn evaluate(&self) {
        let now = Instant::now();
        let mut g = self.inner.lock().unwrap();

        // Aggregate the WORST network across active sessions (protect the weakest
        // viewer). Drop stale sessions (no report in >3 s) so a frozen/gone client
        // never pins the station low forever. We look ONLY at network signals here:
        // packet loss and RTT growth. Decode-side metrics are intentionally not
        // consulted — a slow decoder on a busy client is not a network problem.
        let stale_cutoff = Duration::from_secs(3);
        let mut worst_loss = 0.0f32; // smoothed loss %, max across sessions
        let mut worst_excess = 0.0f32; // RTT above path floor (ms), max across sessions
        let mut worst_skip = 0.0f32; // smoothed egress-skip rate, max across sessions (L-1)
        let mut worst_first_rtt: Option<f32> = None; // highest first-real-RTT (L-3 seed)
        let mut n_active = 0u32;
        for s in g.sessions.values() {
            if now.duration_since(s.stale) > stale_cutoff || !s.init {
                continue;
            }
            n_active += 1;
            worst_loss = worst_loss.max(s.loss_pct_ewma);
            worst_excess = worst_excess.max((s.rtt_ewma - s.rtt_floor).max(0.0));
            worst_skip = worst_skip.max(s.skip_rate_ewma);
            if let Some(fr) = s.first_real_rtt {
                worst_first_rtt = Some(worst_first_rtt.map_or(fr, |w| w.max(fr)));
            }
        }
        if n_active == 0 {
            // No active viewers: reset transient windows + the L-3 start seed, leave
            // the tier as-is.
            g.up_since = None;
            g.down_since = None;
            g.start_seeded = false;
            g.active_since = None;
            return;
        }

        // L-3 RTT-keyed conservative START: once per idle->active spell, seed the
        // GLOBAL tier from the first real RTT so a WAN/5G connect opens conservatively
        // instead of flooding tier-0 before ABR reacts. Wait up to 1.5 s for a real
        // RTT (the client's first report is 0xFFFF); a LAN connect (sub-ms) seeds
        // tier 0, so this is inert there. Default-off (threshold 0 → start_tier 0).
        if g.active_since.is_none() {
            g.active_since = Some(now);
        }
        if !g.start_seeded && self.cfg.abr_start_rtt_ms > 0 {
            let waited = now.duration_since(g.active_since.unwrap());
            if worst_first_rtt.is_some() || waited >= Duration::from_millis(1500) {
                g.start_seeded = true;
                if g.tier == 0 {
                    if let Some(rtt) = worst_first_rtt {
                        let target = start_tier_for_rtt(rtt, self.cfg.abr_start_rtt_ms);
                        if target > 0 {
                            eprintln!("[abr] conservative start tier 0 -> {target} (first rtt {rtt:.0}ms)");
                            self.apply_tier(&mut g, target, now);
                            return;
                        }
                    }
                }
            }
        }

        // Asymmetric hysteresis with a wide dead-band (req 4). CONGESTED requires a
        // clearly-bad network; HEALTHY requires a clearly-good one; in between we
        // HOLD. On a LAN worst_loss~0 and worst_excess~0 => always HEALTHY, so a
        // station at tier 0 never moves.
        let armed = self.cfg.abr_backlog_downshift;
        // Split by signal: loss/backlog are not self-inflicted and keep the short
        // BREACH; an RTT-only breach must hold for RTT_BREACH (see its comment).
        let fast_congested =
            worst_loss >= DOWN_LOSS_PCT || skip_congested(worst_skip, armed);
        let rtt_congested = worst_excess >= DOWN_RTT_EXCESS_MS;
        let congested = fast_congested || rtt_congested;
        // A session still skipping is not healthy-enough to upshift (L-1 veto).
        let healthy = worst_loss <= UP_LOSS_PCT
            && worst_excess <= UP_RTT_EXCESS_MS
            && !skip_blocks_upshift(worst_skip, armed);

        // DWELL (req 3): no tier change within the dwell of the last one, so the
        // controller physically cannot ping-pong. ASYMMETRIC (L-2): a DOWNSHIFT may
        // use the shorter abr_down_dwell_ms so a handover / congestion onset is
        // absorbed in a couple of seconds, while an UPSHIFT keeps the full
        // abr_min_restart_ms dwell so recovery probes up slowly. Defaults leave both
        // equal to abr_min_restart_ms (symmetric = today).
        let since_change = now.duration_since(g.last_restart);
        let can_change_down = since_change >= Duration::from_millis(self.cfg.abr_down_dwell_ms);
        let can_change_up = since_change >= Duration::from_millis(self.cfg.abr_min_restart_ms);
        let cur = g.tier;

        if congested {
            g.up_since = None;
            // PERSISTENCE: the breach must hold for BREACH before it counts (req 2).
            if g.down_since.is_none() {
                g.down_since = Some(now);
            }
            let need = if fast_congested { BREACH } else { RTT_BREACH };
            let sustained = g
                .down_since
                .map(|t| now.duration_since(t) >= need)
                .unwrap_or(false);
            if sustained && cur < MAX_TIER && can_change_down {
                let why = if fast_congested { "loss/backlog" } else { "rtt" };
                eprintln!(
                    "[abr] DOWN why={why} loss={worst_loss:.1}% rtt_excess={worst_excess:.0}ms skip={worst_skip:.2} sessions={n_active}"
                );
                self.apply_tier(&mut g, cur + 1, now);
            }
        } else if healthy {
            g.down_since = None;
            if g.up_since.is_none() {
                g.up_since = Some(now);
            }
            let sustained = g
                .up_since
                .map(|t| now.duration_since(t) >= UP_HOLD)
                .unwrap_or(false);
            if sustained && cur > 0 && can_change_up {
                eprintln!(
                    "[abr] UP loss={worst_loss:.1}% rtt_excess={worst_excess:.0}ms skip={worst_skip:.2} sessions={n_active}"
                );
                self.apply_tier(&mut g, cur - 1, now);
            }
        } else {
            // Dead-band: neither clearly bad nor clearly good — hold and reset both
            // sustain windows so a metric hovering at a boundary cannot accumulate.
            g.down_since = None;
            g.up_since = None;
        }
    }

    fn apply_tier(&self, g: &mut Inner, target: u8, now: Instant) {
        let target = target.min(MAX_TIER);
        eprintln!("[abr] tier {} -> {} (restart)", g.tier, target);
        g.tier = target;
        g.last_restart = now; // arm the dwell gate
        g.up_since = None;
        g.down_since = None;
        self.enc.request_tier(target);
    }
}

/// Compute + smooth the per-session scores from its latest report (SECTION 2.3).
/// Called under the inner lock whenever a fresh report is folded. bandwidthScore
/// is driven by decode_queue / freeze (NOT recv/cap) to honor the museum caveat.
fn fold(s: &mut SessionState, server_skips: u64) {
    let r = s.last;
    let rtt = if r.rtt_ms == 0xFFFF {
        250.0
    } else {
        r.rtt_ms as f32
    };
    // L-3: latch the first REAL RTT (not the 0xFFFF placeholder) for the start seed.
    if r.rtt_ms != 0xFFFF && s.first_real_rtt.is_none() {
        s.first_real_rtt = Some(r.rtt_ms as f32);
    }
    let loss_pct = r.loss_pct_x10 as f32 / 10.0;
    let freeze_delta = r.freeze_count.saturating_sub(s.prev_freeze);
    s.prev_freeze = r.freeze_count;

    // latencyScore = clamp((250 - rttMs)/2.4, 0, 100).
    let lat = ((250.0 - rtt) / 2.4).clamp(0.0, 100.0);

    // lossScore = 100 - lossPct; forced to 0 if a freeze occurred WITH any loss.
    let mut loss = (100.0 - loss_pct).clamp(0.0, 100.0);
    if freeze_delta > 0 && loss_pct > 0.0 {
        loss = 0.0;
    }

    // bandwidthScore relative to the CURRENT tier cap: 100 when decode_queue <= 1
    // and no freeze; drops as the decode queue grows / freezes appear (starved).
    // Driven by queue/freeze, NOT recv/cap — idle stations legitimately sit far below
    // the cap and must NOT read as starved.
    let mut bw = 100.0f32;
    if r.decode_queue > 1 {
        bw -= (r.decode_queue as f32 - 1.0) * 25.0;
    }
    if freeze_delta > 0 {
        bw -= 40.0;
    }
    let bw = bw.clamp(0.0, 100.0);

    let overall_raw = lat.min(loss).min(bw);

    if !s.init {
        s.lat_ewma = lat;
        s.loss_ewma = loss;
        s.bw_ewma = bw;
        s.rtt_ewma = rtt;
        s.overall_ewma = overall_raw;
        s.loss_pct_ewma = loss_pct;
        s.rtt_floor = rtt;
        // Seed the skip baseline so the first interval's delta is 0, not the whole
        // pre-connect cumulative count.
        s.prev_server_skips = server_skips;
        s.skip_rate_ewma = 0.0;
        s.init = true;
    } else {
        s.lat_ewma = lw(s.lat_ewma, lat, 16.0);
        s.loss_ewma = lw(s.loss_ewma, loss, 8.0);
        s.bw_ewma = lw(s.bw_ewma, bw, 16.0);
        s.overall_ewma = lw(s.overall_ewma, overall_raw, 4.0);

        // ASYMMETRIC RTT SMOOTHING (2026-08-17): rise SLOWLY (m=16), fall FAST
        // (m=4). A symmetric m=16 window decays far more slowly than the spike
        // that filled it — one second of pings queued behind a keyframe burst
        // held the smoothed excess above DOWN_RTT_EXCESS_MS for many seconds
        // AFTER the link was healthy again, which is how a burst shorter than
        // the persistence window still satisfied it. Falling fast means a
        // transient cannot leave a tail; sustained bufferbloat keeps feeding
        // high samples, so it still accumulates and still trips.
        let m = if rtt < s.rtt_ewma { 4.0 } else { 16.0 };
        s.rtt_ewma = lw(s.rtt_ewma, rtt, m);

        // ---- NETWORK-decision signals ----
        // Smoothed loss %, reacts a touch faster than the HUD score (m=8).
        s.loss_pct_ewma = lw(s.loss_pct_ewma, loss_pct, 8.0);
        // RTT floor: snap DOWN to any new minimum immediately, but decay UP only
        // very slowly (0.1%/sample). A LAN floor stays ~1 ms; a WAN client's
        // steady baseline is learned so only true queueing growth reads as excess,
        // while a genuinely relocated baseline is eventually absorbed (adapts back).
        if s.rtt_ewma < s.rtt_floor {
            s.rtt_floor = s.rtt_ewma;
        } else {
            s.rtt_floor += (s.rtt_ewma - s.rtt_floor) * 0.001;
        }

        // ---- L-1 backlog signal ----
        // Smooth the per-report SKIP delta (m=8, same window as loss). Saturating
        // so a counter reset (never happens — cumulative per session) can't wrap.
        let skip_delta = server_skips.saturating_sub(s.prev_server_skips) as f32;
        s.prev_server_skips = server_skips;
        s.skip_rate_ewma = lw(s.skip_rate_ewma, skip_delta, 8.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The L-1 backlog trigger is fully inert unless SH_ABR_BACKLOG_DOWNSHIFT is
    /// armed — so a bare deploy keeps the loss/rtt-only tier decision (no LAN change).
    #[test]
    fn skip_trigger_is_inert_when_disarmed() {
        assert!(!skip_congested(100.0, false));
        assert!(!skip_blocks_upshift(100.0, false));
    }

    /// Armed thresholds: congested at/above DOWN_SKIP_RATE; the up-veto trips just
    /// above UP_SKIP_RATE (asymmetric dead-band).
    #[test]
    fn skip_trigger_thresholds_when_armed() {
        assert!(!skip_congested(DOWN_SKIP_RATE - 0.1, true));
        assert!(skip_congested(DOWN_SKIP_RATE, true));
        assert!(!skip_blocks_upshift(UP_SKIP_RATE, true));
        assert!(skip_blocks_upshift(UP_SKIP_RATE + 0.1, true));
    }

    /// L-3 conservative start: default (threshold 0) never moves off tier 0; a LAN
    /// sub-ms RTT stays 0; a WAN RTT opens at tier 1 (>= threshold) or 2 (>= 2x).
    #[test]
    fn start_tier_from_rtt() {
        assert_eq!(start_tier_for_rtt(500.0, 0), 0); // disabled → always 0
        assert_eq!(start_tier_for_rtt(0.6, 120), 0); // LAN
        assert_eq!(start_tier_for_rtt(119.0, 120), 0); // just under
        assert_eq!(start_tier_for_rtt(120.0, 120), 1);
        assert_eq!(start_tier_for_rtt(239.0, 120), 1);
        assert_eq!(start_tier_for_rtt(240.0, 120), 2);
    }

    /// The smoothed skip rate: first fold seeds the baseline (delta 0, not the whole
    /// pre-connect count); sustained skipping lifts it above the up-veto; a quiet
    /// spell decays it back toward zero (so it can't pin the tier low forever).
    #[test]
    fn fold_smooths_server_skip_delta() {
        let mut s = SessionState::new();
        fold(&mut s, 1000);
        assert_eq!(s.skip_rate_ewma, 0.0);
        assert_eq!(s.prev_server_skips, 1000);
        for _ in 0..64 {
            let n = s.prev_server_skips + 3;
            fold(&mut s, n);
        }
        assert!(s.skip_rate_ewma > UP_SKIP_RATE, "rate={}", s.skip_rate_ewma);
        for _ in 0..64 {
            let n = s.prev_server_skips;
            fold(&mut s, n);
        }
        assert!(s.skip_rate_ewma < UP_SKIP_RATE, "rate={}", s.skip_rate_ewma);
    }
}
