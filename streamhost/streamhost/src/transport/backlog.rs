// Per-session egress backlog policy (B1, 2026-07-17 mobile-lag fix).
//
// The broadcast ring's only native drop mechanism is lapping the relay
// (256 AUs ~= 12.8 s @ 20 fps), so a bufferbloated WAN client used to watch
// seconds-old frames and then resume MID-GOP after every overrun — delta
// frames decoded over missing references painted the "partial screen update"
// corruption. This module bounds the per-session send pipeline and guarantees
// every skip episode ends on a clean IDR:
//
//   * `session_backlog` measures frames-in-flight END-TO-END: last SENT
//     frame_id minus the client's acked consumption pointer (T_STATS
//     `last_frame_id`, set client-side at AU-receive time), so it sees the
//     network + quinn send-buffer backlog the local queue depth cannot. It
//     falls back to the broadcast-queue depth when the pointer is unusable.
//   * `BacklogGate` is the pure skip/resume state machine the relay loop
//     drives: non-key AUs are dropped while the session is behind (latest
//     wins), keys ALWAYS pass, and a resume on a delta demands a fresh IDR.
//     Under congestion so sustained the acked pointer never recovers under the
//     bound, a forced resume+IDR every REKEY_MIN_INTERVAL floors the worst case
//     at a ~2 fps clean slideshow — never the 0.4 fps "wait for the 2.5 s
//     keyframe heartbeat" freeze, and never a seconds-stale smear.
//     The effective bound scales with the configured fps (see `new`): the
//     acked pointer legitimately sawtooths up to fps x report-cadence on a
//     healthy LAN, so a rate-blind bound would skip during 60 fps bursts.
//
// SH_SEND_MAX_BACKLOG=0 makes the whole policy inert (legacy relay loop,
// rollback knob); `enabled()` lets the relay loop skip the per-AU backlog
// estimate entirely in that mode, so rollback also removes the added lock
// traffic. Pure state + explicit `now` parameters keep it unit-testable.

use std::time::{Duration, Instant};

/// A client ack older than this is STALE: the report cadence is ~100 ms, so
/// 1 s of silence means the pointer no longer reflects the send pipeline and
/// the local queue depth is the safer signal.
const ACK_FRESH: Duration = Duration::from_secs(1);

/// Min interval between skip-triggered encoder re-keys per session. Rapid
/// skip/resume flapping must not storm `request_keyframe`; the wall-clock
/// keyframe heartbeat (SH_KEYFRAME_MS, 2.5 s) is the backstop whenever the
/// limiter suppresses one (the re-armed join gate just waits for it).
const REKEY_MIN_INTERVAL: Duration = Duration::from_millis(500);

/// End-to-end frames-in-flight estimate for one session.
///
/// Prefers the client's acked consumption pointer (`sent - acked`), falling
/// back to the local broadcast-queue depth when the pointer is unusable:
///   * no report folded yet, or the last one is stale (>= `ACK_FRESH`) — a
///     silent/stalled client must not disable the bound;
///   * ack of 0 — the client reports `last_frame_id=0` until its very first
///     received AU, which would read as a huge spurious backlog on any station
///     whose frame counter has advanced;
///   * a wrapped/"ahead" diff — `frame_id` restarts at 0 on every encoder
///     reopen (ABR tier change, geometry change), so for ~1 report interval
///     the client acks old-epoch ids that make `sent - acked` meaningless.
pub(super) fn session_backlog(
    client_ack: Option<(u32, Instant)>,
    last_sent_id: u32,
    queue_len: usize,
    now: Instant,
) -> u32 {
    if let Some((acked, at)) = client_ack {
        if acked != 0 && now.duration_since(at) < ACK_FRESH {
            let behind = last_sent_id.wrapping_sub(acked);
            if behind <= u32::MAX / 2 {
                return behind;
            }
        }
    }
    queue_len as u32
}

/// What the relay loop must do with one received AU (see `BacklogGate::on_au`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RelayVerdict {
    /// Steady state: relay through the join gate unchanged.
    Relay,
    /// Backlog bound exceeded: drop this stale non-key AU (latest wins).
    Skip,
    /// A skip/Lagged episode ends on this KEY AU: relay it directly — it is
    /// itself the clean resume point (no re-key, no gate re-arm needed; every
    /// following delta chains off it correctly).
    ResumeOnKey,
    /// A skip/Lagged episode ends on a DELTA: the caller must re-arm the join
    /// gate (this delta and every following one reference frames the session
    /// never sent) and, when `rekey`, request a fresh IDR from the encoder
    /// now. `rekey=false` means the per-session rate limiter suppressed the
    /// request — the re-armed gate then waits for the heartbeat IDR instead.
    ResumeOnDelta { rekey: bool },
}

/// The pure B1 skip/resume state machine. One per session, fed every AU the
/// broadcast hands the relay loop plus every `Lagged` overrun.
pub(super) struct BacklogGate {
    /// EFFECTIVE bound: max frames the session may run ahead of the client
    /// before non-key AUs are dropped (`new` scales the configured knob with
    /// fps). 0 = policy fully inert (legacy).
    max_backlog: u32,
    /// Inside a skip episode: stale deltas are being dropped and the next
    /// relayed AU must be (or force) a clean IDR.
    skipping: bool,
    /// When the CURRENT unbroken skip episode began. Drives the forced-resume
    /// cadence: under congestion so sustained the acked pointer never recovers
    /// under the bound, the resume-on-recovery path never fires, so without this
    /// the only clean frame is the 2.5 s keyframe heartbeat (a 0.4 fps freeze).
    /// Once a skip has been held REKEY_MIN_INTERVAL we force a resume+IDR anyway,
    /// flooring worst-case degradation at a ~2 fps slideshow.
    skip_since: Option<Instant>,
    /// Last skip-triggered re-key, for the per-session rate limit.
    last_rekey: Option<Instant>,
}

impl BacklogGate {
    /// `max_backlog` = SH_SEND_MAX_BACKLOG (0 disables the policy); `fps` =
    /// the station's configured capture rate. The knob is a LATENCY budget
    /// expressed in frames — the default 6 encodes ~250 ms at the 24 fps it
    /// was sized for — but `behind` measured off the acked pointer sawtooths
    /// up to fps x report-cadence between T_STATS folds (the client acks on
    /// a 100 ms setInterval, and browser timers only ever fire LATE: 105-130
    /// ms under WebGL+WebCodecs load), so during 60 fps burst delivery a
    /// perfectly healthy LAN session peaks at behind ~= 8 — past a bare
    /// default of 6. The effective bound is therefore
    /// `max(max_backlog, fps / 4)`: the same ~250 ms budget at every rate,
    /// clearing the sawtooth peak (fps/10 + late-timer margin) without
    /// weakening WAN protection — genuine bufferbloat holds `behind` far
    /// above it for hundreds of ms. An explicit knob above fps/4 still wins.
    /// Invariant: the bound MUST exceed fps x report-cadence (~fps/10).
    pub(super) fn new(max_backlog: u32, fps: u32) -> Self {
        let max_backlog = if max_backlog == 0 {
            0 // rollback knob: keep the whole policy inert
        } else {
            max_backlog.max(fps / 4)
        };
        BacklogGate {
            max_backlog,
            skipping: false,
            skip_since: None,
            last_rekey: None,
        }
    }

    /// False in rollback mode (SH_SEND_MAX_BACKLOG=0): the relay loop uses
    /// this to bypass the per-AU `session_backlog` estimate entirely — the
    /// `Instant::now()` + ABR-mutex traffic must roll back with the policy,
    /// not just the verdicts.
    pub(super) fn enabled(&self) -> bool {
        self.max_backlog > 0
    }

    /// Decide one AU. `behind` is the `session_backlog` estimate at receive
    /// time; `now` feeds the re-key rate limiter.
    pub(super) fn on_au(&mut self, is_key: bool, behind: u32, now: Instant) -> RelayVerdict {
        if self.max_backlog == 0 {
            return RelayVerdict::Relay; // legacy mode: never skip, never re-key
        }
        if !is_key && behind > self.max_backlog {
            // Stale delta over the bound: drop it (latest wins). But if the skip
            // episode has run unbroken for REKEY_MIN_INTERVAL, force a clean
            // resume+IDR right now instead of waiting out the whole keyframe
            // heartbeat — sustained congestion then degrades to a ~2 fps
            // slideshow (rate-limited to 1 forced IDR / 500 ms), never a 0.4 fps
            // freeze. `get_or_insert` starts the episode clock on entry (also
            // covers a skip opened by on_lagged, which has no `now`).
            let since = *self.skip_since.get_or_insert(now);
            self.skipping = true;
            if now.duration_since(since) >= REKEY_MIN_INTERVAL
                && self
                    .last_rekey
                    .is_none_or(|t| now.duration_since(t) >= REKEY_MIN_INTERVAL)
            {
                self.skipping = false;
                self.skip_since = None;
                self.last_rekey = Some(now);
                return RelayVerdict::ResumeOnDelta { rekey: true };
            }
            return RelayVerdict::Skip;
        }
        if self.skipping {
            self.skipping = false;
            self.skip_since = None;
            if is_key {
                return RelayVerdict::ResumeOnKey;
            }
            let rekey = self
                .last_rekey
                .is_none_or(|t| now.duration_since(t) >= REKEY_MIN_INTERVAL);
            if rekey {
                self.last_rekey = Some(now);
            }
            return RelayVerdict::ResumeOnDelta { rekey };
        }
        RelayVerdict::Relay
    }

    /// The broadcast ring lapped this session (`Err(Lagged)`): frames were
    /// dropped wholesale, so the next AU must resume through the same
    /// clean-IDR path as a backlog skip. Inert in legacy mode (`on_au` never
    /// reads `skipping` when disabled).
    pub(super) fn on_lagged(&mut self) {
        if self.max_backlog > 0 {
            self.skipping = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAX: u32 = 6;

    /// Skip entry: a delta AT the bound still relays; one frame beyond it is
    /// dropped and the gate stays in the skip episode.
    #[test]
    fn delta_beyond_bound_is_skipped() {
        let mut g = BacklogGate::new(MAX, 24);
        let now = Instant::now();
        assert_eq!(g.on_au(false, MAX, now), RelayVerdict::Relay);
        assert_eq!(g.on_au(false, MAX + 1, now), RelayVerdict::Skip);
        assert_eq!(g.on_au(false, MAX + 50, now), RelayVerdict::Skip);
    }

    /// Sustained congestion the acked pointer never escapes: the resume-on-
    /// recovery path can never fire (behind stays over the bound), so without
    /// the forced-resume cadence the only clean frame would be the 2.5 s
    /// heartbeat. Deltas are dropped for REKEY_MIN_INTERVAL, then a resume+IDR
    /// is forced anyway (the ~2 fps floor), rate-limited to one per 500 ms.
    #[test]
    fn sustained_skip_forces_periodic_resume() {
        let mut g = BacklogGate::new(MAX, 24);
        let t0 = Instant::now();
        // Enter the skip episode; deltas stay far over the bound throughout.
        assert_eq!(g.on_au(false, 100, t0), RelayVerdict::Skip);
        // Within the interval: keep dropping (latest wins), no premature resume.
        assert_eq!(
            g.on_au(false, 100, t0 + Duration::from_millis(100)),
            RelayVerdict::Skip
        );
        assert_eq!(
            g.on_au(false, 100, t0 + Duration::from_millis(400)),
            RelayVerdict::Skip
        );
        // Held REKEY_MIN_INTERVAL -> force a clean resume+IDR though still behind.
        assert_eq!(
            g.on_au(false, 100, t0 + Duration::from_millis(500)),
            RelayVerdict::ResumeOnDelta { rekey: true }
        );
        // A fresh episode opens; the next forced resume is ~500 ms later, not now.
        assert_eq!(
            g.on_au(false, 100, t0 + Duration::from_millis(516)),
            RelayVerdict::Skip
        );
        assert_eq!(
            g.on_au(false, 100, t0 + Duration::from_millis(800)),
            RelayVerdict::Skip
        );
        assert_eq!(
            g.on_au(false, 100, t0 + Duration::from_millis(1016)),
            RelayVerdict::ResumeOnDelta { rekey: true }
        );
    }

    /// Keys always pass the backlog check — under sustained congestion the
    /// session degrades to a clean keyframe-cadence slideshow (key, skip
    /// deltas, key, ...), never a stale smear.
    #[test]
    fn keys_always_pass() {
        let mut g = BacklogGate::new(MAX, 24);
        let now = Instant::now();
        assert_eq!(g.on_au(false, 100, now), RelayVerdict::Skip);
        assert_eq!(g.on_au(true, 100, now), RelayVerdict::ResumeOnKey);
        assert_eq!(g.on_au(false, 100, now), RelayVerdict::Skip);
        assert_eq!(g.on_au(true, 100, now), RelayVerdict::ResumeOnKey);
    }

    /// Resume on an IDR: the key IS the clean resume point — relayed directly
    /// with no re-key, and the machine is back in steady state.
    #[test]
    fn resume_on_idr_needs_no_rekey() {
        let mut g = BacklogGate::new(MAX, 24);
        let now = Instant::now();
        assert_eq!(g.on_au(false, 50, now), RelayVerdict::Skip);
        assert_eq!(g.on_au(true, 2, now), RelayVerdict::ResumeOnKey);
        assert_eq!(g.on_au(false, 2, now), RelayVerdict::Relay);
    }

    /// Resume on a delta demands a fresh IDR; rapid skip/resume flapping is
    /// rate-limited to one encoder re-key per 500 ms per session.
    #[test]
    fn resume_on_delta_rekeys_rate_limited() {
        let mut g = BacklogGate::new(MAX, 24);
        let t0 = Instant::now();
        assert_eq!(g.on_au(false, 50, t0), RelayVerdict::Skip);
        assert_eq!(
            g.on_au(false, 1, t0),
            RelayVerdict::ResumeOnDelta { rekey: true }
        );
        // Immediate flap: the limiter suppresses the second re-key ...
        assert_eq!(g.on_au(false, 50, t0), RelayVerdict::Skip);
        assert_eq!(
            g.on_au(false, 1, t0 + Duration::from_millis(100)),
            RelayVerdict::ResumeOnDelta { rekey: false }
        );
        // ... and re-allows once the window has passed.
        assert_eq!(g.on_au(false, 50, t0), RelayVerdict::Skip);
        assert_eq!(
            g.on_au(false, 1, t0 + Duration::from_millis(600)),
            RelayVerdict::ResumeOnDelta { rekey: true }
        );
    }

    /// A broadcast-ring overrun resumes exactly like a backlog skip: on a
    /// delta the join gate must be re-armed + an IDR requested; on a key the
    /// session resumes directly.
    #[test]
    fn lagged_forces_clean_resume() {
        let mut g = BacklogGate::new(MAX, 24);
        let now = Instant::now();
        g.on_lagged();
        assert_eq!(
            g.on_au(false, 0, now),
            RelayVerdict::ResumeOnDelta { rekey: true }
        );
        g.on_lagged();
        assert_eq!(g.on_au(true, 0, now), RelayVerdict::ResumeOnKey);
    }

    /// SH_SEND_MAX_BACKLOG=0: the whole policy is inert — the relay loop
    /// behaves exactly like the legacy unbounded version (no skip, no re-key,
    /// Lagged stays a bare `continue`).
    #[test]
    fn zero_disables_policy() {
        let mut g = BacklogGate::new(0, 60);
        let now = Instant::now();
        assert_eq!(g.on_au(false, 10_000, now), RelayVerdict::Relay);
        g.on_lagged();
        assert_eq!(g.on_au(false, 10_000, now), RelayVerdict::Relay);
        assert_eq!(g.on_au(true, 10_000, now), RelayVerdict::Relay);
    }

    /// Fresh client ack: `behind` is exactly sent - acked, end-to-end.
    #[test]
    fn backlog_prefers_fresh_client_ack() {
        let now = Instant::now();
        assert_eq!(session_backlog(Some((90, now)), 100, 3, now), 10);
        assert_eq!(session_backlog(Some((100, now)), 100, 3, now), 0);
    }

    /// Stale (>= 1 s old) or missing stats fall back to the local
    /// broadcast-queue depth — a silent client must not disable the bound.
    #[test]
    fn stale_or_missing_stats_fall_back_to_queue_depth() {
        let t0 = Instant::now();
        let now = t0 + Duration::from_secs(2);
        assert_eq!(session_backlog(Some((90, t0)), 100, 4, now), 4);
        assert_eq!(session_backlog(None, 100, 4, now), 4);
    }

    /// An ack of 0 (client has not received an AU yet) and an old-epoch ack
    /// "ahead" of last_sent (frame_id restarts on encoder reopen) are both
    /// meaningless for sent - acked and must fall back, not trip the bound.
    #[test]
    fn unset_or_cross_epoch_ack_falls_back() {
        let now = Instant::now();
        assert_eq!(session_backlog(Some((0, now)), 5000, 2, now), 2);
        assert_eq!(session_backlog(Some((5000, now)), 40, 2, now), 2);
    }

    /// The effective bound scales with the configured rate: at 60 fps the
    /// bare default of 6 sits exactly on the healthy ack sawtooth peak, so
    /// `new` widens it to fps/4 (the same ~250 ms budget the default encodes
    /// at 24 fps). An explicit knob above fps/4 wins; at 24 fps the default
    /// is unchanged (fps/4 == 6).
    #[test]
    fn bound_scales_with_fps() {
        let now = Instant::now();
        let mut g = BacklogGate::new(6, 60); // effective bound 15
        assert_eq!(g.on_au(false, 15, now), RelayVerdict::Relay);
        assert_eq!(g.on_au(false, 16, now), RelayVerdict::Skip);
        let mut g = BacklogGate::new(30, 60); // knob above fps/4: knob wins
        assert_eq!(g.on_au(false, 30, now), RelayVerdict::Relay);
        assert_eq!(g.on_au(false, 31, now), RelayVerdict::Skip);
        let mut g = BacklogGate::new(6, 24); // the default's design point
        assert_eq!(g.on_au(false, 6, now), RelayVerdict::Relay);
        assert_eq!(g.on_au(false, 7, now), RelayVerdict::Skip);
    }

    /// The fps x report-cadence steady state the shipped defaults must
    /// survive: 60 fps burst delivery acked by the client's 100 ms T_STATS
    /// setInterval firing up to 30 ms LATE (browser timers under
    /// WebGL+WebCodecs load never fire early). Between folds `behind`
    /// legitimately sawtooths
    /// past the bare knob default of 6 on a perfectly healthy LAN — nothing
    /// may skip. Then the acked pointer stalls (genuine bufferbloat: reports
    /// keep arriving, frames do not) and the skip must still fire.
    #[test]
    fn healthy_60fps_sawtooth_relays_but_real_backlog_skips() {
        const FRAME_US: u64 = 1_000_000 / 60;
        let mut g = BacklogGate::new(6, 60);
        let t0 = Instant::now();
        // T_STATS fold times: a ~100 ms browser timer, always late.
        let gaps_ms: [u64; 8] = [110, 130, 105, 125, 115, 130, 100, 120];
        let mut folds: Vec<u64> = Vec::new();
        let mut acc = 0u64;
        for gap in gaps_ms.iter().cycle().take(24) {
            acc += gap * 1000;
            folds.push(acc);
        }
        // Healthy phase: two seconds of 60 fps emission, relay keeps up
        // (queue depth 0), the client acks every frame emitted by fold time.
        let mut last_sent: u32 = 0;
        let mut peak_behind = 0u32;
        for n in 1..=120u64 {
            let t = n * FRAME_US;
            let now = t0 + Duration::from_micros(t);
            let ack = folds
                .iter()
                .rev()
                .find(|&&f| f <= t)
                .map(|&f| ((f / FRAME_US) as u32, t0 + Duration::from_micros(f)));
            let behind = session_backlog(ack, last_sent, 0, now);
            peak_behind = peak_behind.max(behind);
            assert_eq!(
                g.on_au(false, behind, now),
                RelayVerdict::Relay,
                "healthy 60 fps frame {n} skipped (behind={behind})"
            );
            last_sent = n as u32;
        }
        // The model must actually exceed the bare knob default — this test
        // fails against a rate-blind bound of 6.
        assert!(
            peak_behind > 6,
            "sawtooth never peaked (behind={peak_behind})"
        );
        // Congestion phase: reports keep folding (uplink fine) but the acked
        // pointer is stuck — behind grows with emission past the bound.
        let frozen_ack =
            (folds.iter().rev().find(|&&f| f <= 120 * FRAME_US).unwrap() / FRAME_US) as u32;
        let mut skipped = false;
        for n in 121..=180u64 {
            let now = t0 + Duration::from_micros(n * FRAME_US);
            let behind = session_backlog(Some((frozen_ack, now)), last_sent, 0, now);
            match g.on_au(false, behind, now) {
                RelayVerdict::Skip => skipped = true,
                _ => last_sent = n as u32,
            }
        }
        assert!(
            skipped,
            "genuine backlog growth past the bound never skipped"
        );
    }
}
