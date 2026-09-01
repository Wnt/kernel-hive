//! Unit tests for `x11_warp` — a sibling file purely for the per-file line
//! budget; `#[path]` keeps them the same inline `mod tests`, with the same
//! access to the module's private items. No live X server: the tests build
//! `Shared` directly and exercise the queueing, gating and arming logic the
//! worker runs against it.
use super::*;

fn shared(health: u8) -> Arc<Shared> {
    Arc::new(Shared {
        pending: Mutex::new(Pending {
            latest_move: None,
            ordered: VecDeque::with_capacity(ORDERED_CAPACITY),
            cur_x: 0,
            cur_y: 0,
        }),
        cv: Condvar::new(),
        health: AtomicU8::new(health),
        counters: Counters::default(),
        closed: AtomicBool::new(false),
        edge_pending: AtomicU64::new(0),
        settled: tokio::sync::Notify::new(),
        armed: AtomicBool::new(false),
        readback: AtomicU8::new(READBACK_NONE),
        last_err: Mutex::new(String::new()),
        repair_marker: None,
    })
}

fn ev(seq: u64, x: u32, y: u32, ordered: bool) -> PointerAbs {
    PointerAbs {
        seq,
        x,
        y,
        width: 1152,
        height: 900,
        buttons: 0,
        wheel_v: 0,
        wheel_h: 0,
        ordered,
    }
}

#[test]
fn moves_coalesce_latest_wins() {
    let shared = shared(HEALTH_HEALTHY);
    let sink = X11WarpSink {
        shared: shared.clone(),
    };
    sink.try_pointer_abs(ev(1, 10, 10, false)).unwrap();
    sink.try_pointer_abs(ev(2, 20, 20, false)).unwrap();
    sink.try_pointer_abs(ev(3, 30, 30, false)).unwrap();
    let p = shared.pending.lock().unwrap();
    assert_eq!(p.latest_move, Some((30, 30)));
    assert!(p.ordered.is_empty());
    assert_eq!(shared.counters.coalesced.load(Ordering::Relaxed), 2);
    assert_eq!(shared.counters.accepted.load(Ordering::Relaxed), 3);
}

/// An ordered record flushes the pending move ahead of itself, then restates
/// ITS OWN target with verify set — the warp the held edge waits on — and
/// arms the edge gate.
#[test]
fn ordered_flushes_move_then_verified_restate() {
    let shared = shared(HEALTH_HEALTHY);
    let sink = X11WarpSink {
        shared: shared.clone(),
    };
    sink.try_pointer_abs(ev(1, 100, 100, false)).unwrap();
    sink.try_pointer_abs(ev(2, 101, 101, true)).unwrap();
    let p = shared.pending.lock().unwrap();
    assert!(p.latest_move.is_none());
    let q: Vec<_> = p.ordered.iter().map(|w| (w.x, w.y, w.verify)).collect();
    assert_eq!(q, vec![(100, 100, false), (101, 101, true)]);
    assert_eq!(shared.edge_pending.load(Ordering::Relaxed), 1);
}

#[test]
fn clamps_to_surface() {
    let shared = shared(HEALTH_HEALTHY);
    let sink = X11WarpSink {
        shared: shared.clone(),
    };
    sink.try_pointer_abs(ev(1, 5000, 5000, false)).unwrap();
    let p = shared.pending.lock().unwrap();
    assert_eq!(p.latest_move, Some((1151, 899)));
}

/// FAIL CLOSED: while down the offer is REJECTED (so the caller can see it),
/// but browser truth keeps updating for the reconnect restate.
#[test]
fn down_rejects_but_tracks_truth() {
    let shared = shared(HEALTH_DOWN);
    let sink = X11WarpSink {
        shared: shared.clone(),
    };
    assert_eq!(
        sink.try_pointer_abs(ev(1, 40, 50, false)),
        Err(Reject::BackendDown)
    );
    let p = shared.pending.lock().unwrap();
    assert_eq!((p.cur_x, p.cur_y), (40, 50));
    assert!(p.latest_move.is_none());
    assert_eq!(shared.counters.backend_down.load(Ordering::Relaxed), 1);
}

#[test]
fn ordered_queue_is_bounded() {
    let shared = shared(HEALTH_HEALTHY);
    let sink = X11WarpSink {
        shared: shared.clone(),
    };
    for i in 0..ORDERED_CAPACITY as u64 {
        sink.try_pointer_abs(ev(i, 1, 1, true)).unwrap();
    }
    assert_eq!(
        sink.try_pointer_abs(ev(99, 2, 2, true)),
        Err(Reject::Overflow)
    );
    assert_eq!(shared.counters.overflow.load(Ordering::Relaxed), 1);
    // The rejected edge never armed the gate.
    assert_eq!(
        shared.edge_pending.load(Ordering::Relaxed),
        ORDERED_CAPACITY as u64
    );
}

/// THE EXCLUSION WINDOW. With an edge armed (what the worker sets on a
/// confirmed readback, before the gate releases), a move offered before
/// `edge_done()` keeps updating browser truth but is NOT drained/applied;
/// after `edge_done()` it is.
#[test]
fn armed_edge_excludes_motion_until_done() {
    let shared = shared(HEALTH_HEALTHY);
    let sink = X11WarpSink {
        shared: shared.clone(),
    };
    shared.armed.store(true, Ordering::Release);
    sink.try_pointer_abs(ev(1, 50, 60, false)).unwrap();
    // Parked: browser truth updated, nothing drainable while armed.
    assert!(shared.take_next().is_none());
    {
        let p = shared.pending.lock().unwrap();
        assert_eq!((p.cur_x, p.cur_y), (50, 60));
        assert_eq!(p.latest_move, Some((50, 60)));
    }
    // The injection signalled done: the parked move now applies.
    edge_done_on(&shared);
    assert!(!shared.armed.load(Ordering::Acquire));
    let w = shared.take_next().expect("move applies after edge_done");
    assert_eq!((w.x, w.y, w.verify), (50, 60, false));
}

/// A caller that dies between the gate release and the injection must not
/// wedge the pointer: the armed window expires on the bound, COUNTED.
#[test]
fn arm_expiry_is_counted_never_silent() {
    let shared = shared(HEALTH_HEALTHY);
    shared.armed.store(true, Ordering::Release);
    // Fresh window: not yet due.
    assert!(!shared.expire_arm_if_due(Instant::now()));
    assert!(shared.armed.load(Ordering::Acquire));
    // Outlived the bound: disarmed and counted.
    let stale = Instant::now() - (EDGE_HOLD_MAX + Duration::from_millis(50));
    assert!(shared.expire_arm_if_due(stale));
    assert!(!shared.armed.load(Ordering::Acquire));
    assert_eq!(shared.counters.arm_expired.load(Ordering::Relaxed), 1);
}

/// The stat line can say "I do not know": before any readback it reports
/// last-readback=none, and a give-up reports unconfirmed — never confirmed.
/// It also states the WITNESS scope: a released edge means warp confirmed +
/// handoff, never guest application (there is no ack on the PS/2 channel).
#[test]
fn stat_line_never_fakes_a_confirmation() {
    let shared = shared(HEALTH_HEALTHY);
    assert!(shared.stat_line().contains("last-readback=none"));
    assert!(shared
        .stat_line()
        .contains("edge-witness=warp-confirmed-then-handoff"));
    shared.edge_pending.fetch_add(1, Ordering::AcqRel);
    shared.counters.gaveup.fetch_add(1, Ordering::Relaxed);
    shared.release_edge(READBACK_UNCONFIRMED);
    assert!(shared.stat_line().contains("last-readback=unconfirmed"));
    assert!(shared.stat_line().contains("warp-gaveup=1"));
    assert_eq!(shared.edge_pending.load(Ordering::Relaxed), 0);
}

#[tokio::test]
async fn edge_hold_releases_on_confirmation_and_is_bounded() {
    let shared = shared(HEALTH_HEALTHY);
    // Nothing pending: returns immediately.
    wait_settled_on(&shared, Duration::from_millis(50)).await;
    // Pending and never confirmed: the bound fires, counted.
    shared.edge_pending.fetch_add(1, Ordering::AcqRel);
    let t = Instant::now();
    wait_settled_on(&shared, Duration::from_millis(50)).await;
    assert!(t.elapsed() >= Duration::from_millis(50));
    assert_eq!(shared.counters.hold_timeout.load(Ordering::Relaxed), 1);
    // Confirmed from another task: the hold releases early.
    let s2 = shared.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(20)).await;
        s2.release_edge(READBACK_CONFIRMED);
    });
    let t = Instant::now();
    wait_settled_on(&shared, Duration::from_secs(5)).await;
    assert!(t.elapsed() < Duration::from_secs(5));
}

/// `golden-state` must distinguish "no marker configured" from "all is well" —
/// an unconfigured station must never read as `baked`, or a missing check looks
/// like a passing one.
#[test]
fn golden_state_separates_unknown_from_baked() {
    let dir = std::env::temp_dir().join(format!("x11warp-gs-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let marker = dir.join("x11warp-repaired");
    let _ = std::fs::remove_file(&marker);
    assert_eq!(golden_state(None), "unknown");
    assert_eq!(golden_state(Some(marker.as_path())), "baked");
    std::fs::write(&marker, b"").unwrap();
    assert_eq!(golden_state(Some(marker.as_path())), "REPAIRED-AT-RUNTIME");
    let _ = std::fs::remove_file(&marker);
    let _ = std::fs::remove_dir(&dir);
}

/// The degraded mode is a STATEMENT in STAT, not something to infer from a
/// counter: there is no fallback, and motion stops until the X server is back.
#[test]
fn stat_states_the_degraded_mode_and_the_golden_state() {
    let s = shared(HEALTH_DOWN);
    let line = s.stat_line();
    assert!(
        line.contains("on-backend-down=motion-stops"),
        "STAT must say what a BackendDown move DOES, not leave it to be inferred: {line}"
    );
    assert!(line.contains("golden-state=unknown"), "{line}");
}
