//! Unit tests for `abr` — split into a sibling file purely for the per-file line
//! budget; `#[path]` keeps them the same inline `mod tests`, with the same access
//! to the module's private items.
//!
//! These tests ARE the specification of the tier decision: which signals may move
//! the ladder, how long a breach must hold, and what a fresh session is allowed to
//! say before it has measured anything.
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

/// ASYMMETRIC RTT SMOOTHING: a keyframe-burst transient must not leave a
/// tail. A short spike is absorbed within a few samples of the link
/// recovering (m=4 falling), so it cannot hold the excess above
/// DOWN_RTT_EXCESS_MS long enough to satisfy RTT_BREACH.
#[test]
fn rtt_spike_decays_without_a_tail() {
    let mut s = SessionState::new();
    let mut r = Report {
        rtt_ms: 3,
        ..Report::default()
    };
    fold(&mut s, 0);
    for _ in 0..40 {
        s.last = r;
        fold(&mut s, 0);
    }
    let floor = s.rtt_floor;
    // A burst: ten samples of badly-queued pings.
    r.rtt_ms = 400;
    for _ in 0..10 {
        s.last = r;
        fold(&mut s, 0);
    }
    assert!(s.rtt_ewma - floor > DOWN_RTT_EXCESS_MS, "spike registers");
    // The link recovers; the excess must collapse fast, not linger.
    r.rtt_ms = 3;
    for _ in 0..15 {
        s.last = r;
        fold(&mut s, 0);
    }
    assert!(
        s.rtt_ewma - s.rtt_floor < DOWN_RTT_EXCESS_MS,
        "excess must not linger after recovery: ewma={} floor={}",
        s.rtt_ewma,
        s.rtt_floor
    );
}

/// Sustained bufferbloat must STILL trip: rising is slow (m=16) but a path
/// that holds RTT high keeps feeding high samples, so the excess accumulates.
#[test]
fn sustained_rtt_growth_still_trips() {
    let mut s = SessionState::new();
    let mut r = Report {
        rtt_ms: 20,
        ..Report::default()
    };
    fold(&mut s, 0);
    for _ in 0..60 {
        s.last = r;
        fold(&mut s, 0);
    }
    r.rtt_ms = 300;
    for _ in 0..60 {
        s.last = r;
        fold(&mut s, 0);
    }
    assert!(
        s.rtt_ewma - s.rtt_floor >= DOWN_RTT_EXCESS_MS,
        "genuine bufferbloat must still read as congested: ewma={} floor={}",
        s.rtt_ewma,
        s.rtt_floor
    );
}

/// Fold `n` reports of `loss_pct` into a session (the ~100 ms T_STATS cadence).
fn fold_loss(s: &mut SessionState, loss_pct: f32, n: u32) {
    for _ in 0..n {
        s.last = Report {
            rtt_ms: 5,
            loss_pct_x10: (loss_pct * 10.0) as u16,
            ..Report::default()
        };
        fold(s, 0);
    }
}

/// Move a session past the wall-clock half of the warm-up without sleeping.
fn age_past_warmup(s: &mut SessionState) {
    s.created -= LOSS_WARMUP + Duration::from_secs(1);
}

/// L-5, the 2026-09-02 bug: a fresh session's first intervals report huge
/// bogus loss (the join gate withheld the AUs; the client counted the frame_id
/// hole). None of it may reach the ladder — not through the EWMA seed, not
/// through the smoothed value, not through `evaluate`'s aggregate.
#[test]
fn warmup_swallows_the_first_interval_loss() {
    let mut s = SessionState::new();
    fold_loss(&mut s, 86.7, 30);
    assert_eq!(s.loss_pct_ewma, 0.0, "warm-up must not smooth join loss");
    assert!(
        s.warming_up(Instant::now()),
        "30 reports is < 4 s of wall clock"
    );
}

/// The warm-up ENDS: both halves must pass. Wall-clock alone is not enough
/// (a client reporting twice a second must not qualify in 4 s), and reports
/// alone are not enough (a 100 ms cadence delivers 20 in 2 s).
#[test]
fn warmup_needs_both_halves() {
    let now = Instant::now();
    let mut s = SessionState::new();
    age_past_warmup(&mut s);
    s.reports = LOSS_WARMUP_REPORTS - 1;
    assert!(s.warming_up(now), "old enough, too few reports");
    s.reports = LOSS_WARMUP_REPORTS;
    assert!(!s.warming_up(now), "both halves satisfied");
    let mut s2 = SessionState::new();
    s2.reports = LOSS_WARMUP_REPORTS * 10;
    assert!(s2.warming_up(now), "reports enough, too young");
}

/// After warm-up the loss signal works exactly as before: sustained loss
/// lifts the smoothed value over the downshift threshold.
#[test]
fn sustained_loss_still_trips_after_warmup() {
    let mut s = SessionState::new();
    age_past_warmup(&mut s);
    fold_loss(&mut s, 20.0, 40);
    assert!(!s.warming_up(Instant::now()));
    assert!(
        loss_congested(s.loss_pct_ewma, 20.0),
        "genuine loss must still read congested: ewma={}",
        s.loss_pct_ewma
    );
}

/// A ONE-OFF burst must not downshift on its decay tail. At m=8 a single
/// 90 % sample keeps the EWMA over DOWN_LOSS_PCT for longer than BREACH, so
/// the smoothed value alone would satisfy the persistence window; requiring
/// the CURRENT report to agree is what makes the breach mean something.
#[test]
fn a_recovered_burst_is_not_congested() {
    let mut s = SessionState::new();
    age_past_warmup(&mut s);
    fold_loss(&mut s, 0.0, 30);
    fold_loss(&mut s, 90.0, 1);
    assert!(s.loss_pct_ewma > DOWN_LOSS_PCT, "the burst registers");
    // The link is clean again from the very next report...
    fold_loss(&mut s, 0.0, 5);
    assert!(
        s.loss_pct_ewma > DOWN_LOSS_PCT,
        "the EWMA tail alone still looks bad: ewma={}",
        s.loss_pct_ewma
    );
    assert!(
        !loss_congested(s.loss_pct_ewma, 0.0),
        "...but a recovered link must not be congested"
    );
}

/// The two-signal loss gate: both halves at/above the threshold, or nothing.
#[test]
fn loss_congested_needs_both_signals() {
    assert!(loss_congested(DOWN_LOSS_PCT, DOWN_LOSS_PCT));
    assert!(!loss_congested(DOWN_LOSS_PCT - 0.1, 50.0));
    assert!(!loss_congested(50.0, DOWN_LOSS_PCT - 0.1));
}

/// L-6: the per-session breach verdict. Loss and backlog keep the short BREACH;
/// an RTT-only breach must hold for RTT_BREACH; a clean session breaches never.
#[test]
fn session_breach_names_the_signal_and_its_window() {
    assert_eq!(session_breach(0.0, 0.0, 0.0, 0.0, false), None);
    assert_eq!(
        session_breach(50.0, 50.0, 0.0, 0.0, false),
        Some(("loss/backlog", BREACH))
    );
    assert_eq!(
        session_breach(0.0, 0.0, DOWN_RTT_EXCESS_MS, 0.0, false),
        Some(("rtt", RTT_BREACH))
    );
    // Backlog only counts while armed, and loss wins the naming when both hold.
    assert_eq!(session_breach(0.0, 0.0, 0.0, 99.0, false), None);
    assert_eq!(
        session_breach(0.0, 0.0, 0.0, DOWN_SKIP_RATE, true),
        Some(("loss/backlog", BREACH))
    );
    // A recovered burst (smoothed still high, current clean) is NOT a breach —
    // and RTT must not pick up the slack for it.
    assert_eq!(session_breach(50.0, 0.0, 0.0, 0.0, false), None);
}

/// L-6, the win95 `path0->1->0->1->0->1->0` of 2026-09-02: a downshift that an
/// upshift undoes taught the ladder nothing, so the next breach must hold longer.
/// It doubles per futile cycle, is capped, and a genuinely degrading link is
/// still caught within MAX_BREACH.
#[test]
fn a_futile_cycle_makes_the_next_breach_harder() {
    assert_eq!(breach_need(BREACH, 0), BREACH);
    assert_eq!(breach_need(BREACH, 1), BREACH * 2);
    assert_eq!(breach_need(BREACH, 2), BREACH * 4);
    // Capped: 1.5 s * 8 = 12 s is exactly MAX_BREACH, and nothing exceeds it.
    assert_eq!(breach_need(BREACH, 3), MAX_BREACH);
    assert_eq!(breach_need(BREACH, 99), MAX_BREACH);
    // The RTT window is already long; damping must not push it past the cap.
    assert_eq!(breach_need(RTT_BREACH, 0), RTT_BREACH);
    assert!(breach_need(RTT_BREACH, 9) <= MAX_BREACH);
}

/// A session inside its warm-up must produce no breach at all, whatever it
/// reports — the ladder cannot be moved by a client that has not measured
/// anything yet (L-5 feeding L-6).
#[test]
fn a_warming_session_breaches_on_nothing() {
    let s = SessionState::new();
    assert!(s.warming_up(Instant::now()));
    // `evaluate` zeroes a warming session's loss before asking; the verdict on
    // those zeroed inputs must be None even though the raw report was 93.8 %.
    assert_eq!(session_breach(0.0, 0.0, 0.0, 0.0, false), None);
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
