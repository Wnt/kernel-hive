//! Unit tests for `realtime_input` — split into a sibling file purely for the
//! per-file line budget; `#[path]` keeps them the same inline `mod tests`, with
//! the same access to the module's private items.
use super::*;

#[test]
fn normalization_edges_and_rounding() {
    assert_eq!(normalize(0, 1920), 0);
    assert_eq!(normalize(1919, 1920), 32767);
    assert_eq!(normalize(960, 1920), 16392);
    assert_eq!(normalize(99, 1), 0);
    assert_eq!(normalize(9999, 1200), 32767);
}

#[test]
fn pointer_record_is_exact_t1_layout() {
    let frame = pointer_frame(PointerAbs {
        seq: 44,
        x: 1919,
        y: 0,
        width: 1920,
        height: 1200,
        buttons: 5,
        wheel_v: -1,
        wheel_h: 1,
        ordered: true,
    });
    assert_eq!(frame.0[0], 1);
    assert_eq!(&frame.0[2..4], &[0, 0]);
    assert_eq!(u16::from_le_bytes([frame.0[4], frame.0[5]]), 32767);
    assert_eq!(u16::from_le_bytes([frame.0[6], frame.0[7]]), 0);
    assert_eq!(u16::from_le_bytes([frame.0[8], frame.0[9]]), 5);
    assert_eq!(frame.0[10], 0xff);
    assert_eq!(frame.0[11], 1);
}

#[test]
fn key_record_keeps_canonical_xt_token() {
    let frame = key_frame(KeyEvent {
        seq: 1,
        key: 0xe048,
        down: true,
        repeat: false,
        modifiers: 0x0004,
    });
    assert_eq!(frame.0[0], 2);
    assert_eq!(frame.0[1], 1);
    assert_eq!(&frame.0[4..6], &0xe048u16.to_le_bytes());
    assert_eq!(&frame.0[6..8], &4u16.to_le_bytes());
}

#[test]
fn pointer_slot_is_latest_wins_and_transition_flushes_in_order() {
    let initial = pointer_frame(PointerAbs {
        seq: 0,
        x: 0,
        y: 0,
        width: 100,
        height: 100,
        buttons: 0,
        wheel_v: 0,
        wheel_h: 0,
        ordered: false,
    });
    let shared = Arc::new(GalleryShared {
        pending: Mutex::new(Pending {
            latest_pointer: None,
            ordered: VecDeque::new(),
            current_pointer: initial,
        }),
        notify: Notify::new(),
        control: Notify::new(),
        health: AtomicU8::new(HEALTH_HEALTHY),
        counters: Counters::default(),
        closed: AtomicBool::new(false),
        paused: AtomicBool::new(false),
    });
    let sink = GalleryHidSink {
        shared: shared.clone(),
    };
    let event = |seq, x, buttons, ordered| PointerAbs {
        seq,
        x,
        y: 10,
        width: 100,
        height: 100,
        buttons,
        wheel_v: 0,
        wheel_h: 0,
        ordered,
    };
    sink.try_pointer_abs(event(1, 10, 0, false)).unwrap();
    sink.try_pointer_abs(event(2, 20, 0, false)).unwrap();
    sink.try_pointer_abs(event(3, 20, 1, true)).unwrap();

    let pending = shared.pending.lock().unwrap();
    assert!(pending.latest_pointer.is_none());
    assert_eq!(pending.ordered.len(), 2);
    let first = pending.ordered.front().unwrap();
    assert_eq!(u16::from_le_bytes([first.0[8], first.0[9]]), 0);
    assert_eq!(shared.counters.accepted.load(Ordering::Relaxed), 3);
    assert_eq!(shared.counters.coalesced.load(Ordering::Relaxed), 1);
}

// ---- a button EDGE is never dropped -----------------------------------
// The router's state lock is a try_lock so a high-rate move stream never
// blocks the receive path. Applied to button edges that is a silent
// click-eater: on IRIX a ~25/s pen-hover stream beat every press to the lock
// and each one was discarded, so single taps did not land and drags never
// released (2026-08-05). Moves may still be dropped — another always follows.

/// Counts what actually reached a sink, and holds the lock long enough to
/// make the contention real rather than theoretical.
#[derive(Default)]
struct CountingSink {
    edges: AtomicU64,
    moves: AtomicU64,
}

impl RealtimeInputSink for CountingSink {
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject> {
        if event.ordered {
            self.edges.fetch_add(1, Ordering::Relaxed);
        } else {
            self.moves.fetch_add(1, Ordering::Relaxed);
        }
        std::thread::yield_now(); // widen the window the mover races for
        Ok(AcceptedSeq(event.seq))
    }
    fn health(&self) -> SinkHealth {
        SinkHealth::Healthy
    }
    fn backend_name(&self) -> &'static str {
        "counting"
    }
}

fn counting_router() -> (Arc<InputRouter>, Arc<CountingSink>) {
    let sink = Arc::new(CountingSink::default());
    let router = Arc::new(InputRouter {
        sink: sink.clone(),
        seq: AtomicU64::new(0),
        state: Mutex::new(RouterState {
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            buttons: 0,
            modifiers: 0,
        }),
    });
    (router, sink)
}

#[test]
fn every_button_edge_survives_a_flood_of_moves() {
    let (router, sink) = counting_router();
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let movers: Vec<_> = (0..4)
        .map(|_| {
            let r = router.clone();
            let stop = stop.clone();
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    let _ = r.try_move(10, 20, 640, 480);
                }
            })
        })
        .collect();

    const PRESSES: u64 = 200;
    for _ in 0..PRESSES {
        router
            .try_button(0, true)
            .expect("press must not be dropped");
        router
            .try_button(0, false)
            .expect("release must not be dropped");
    }
    stop.store(true, Ordering::Relaxed);
    for m in movers {
        m.join().unwrap();
    }
    // Both halves of every click, with nothing eaten by the mover threads.
    assert_eq!(sink.edges.load(Ordering::Relaxed), PRESSES * 2);
    assert!(
        sink.moves.load(Ordering::Relaxed) > 0,
        "the flood really ran"
    );
}

// …and the carried point rides the SAME acquisition as the edge, so no
// concurrent move can slip between a press and the pixel it was aimed at.
#[test]
fn a_carried_position_and_its_edge_are_one_event() {
    let (router, sink) = counting_router();
    router
        .try_button_at(0, true, Some((300, 400, 640, 480)))
        .unwrap();
    assert_eq!(sink.edges.load(Ordering::Relaxed), 1);
    assert_eq!(sink.moves.load(Ordering::Relaxed), 0); // NOT a move plus an edge
    let st = router.state.lock().unwrap();
    assert_eq!((st.x, st.y, st.buttons), (300, 400, 1));
}

/// EVERY pointer sink must DECLARE how it keeps its clicks from racing its
/// motion, and the button routing must FOLLOW the declaration.
///
/// The regression that produced this test: `mgactl` landed routing motion but
/// not clicks, and the failure mode hides itself — `apply_move_abs` hands
/// motion to whatever router exists, so the cursor tracks perfectly and only
/// the click is wrong: the press fires down the D-Bus PS/2 path while the
/// sink is still walking the cursor, and the guest sees press-at-A / motion /
/// release-at-B, a drag. On aix432 links kept working while HTML form fields
/// never took keyboard focus, reported as "the keyboard stopped working".
///
/// What this test actually enforces, precisely:
///  - every backend that builds a router AND has a pointer must have a
///    `Some(..)` arm in `edge_discharge` (a new sink with NO arm goes red
///    here — that is the mgactl regression guard);
///  - names with no pointer sink must declare nothing;
///  - `backend_routes_buttons` agrees with the declaration (it is derived
///    from the table, so this pins the derivation staying that way);
///  - the declared value per sink is pinned below, so an accidental table
///    edit is loud.
///
/// HONESTY — a declaration EXISTS here, it is not proven TRUE. A sink can
/// declare `VerifiedWarp` without implementing any verification and stay
/// green in this test. That is more LEGIBLE than the old exception list
/// (under which a sink could be exempted without implementing anything), not
/// more ENFORCED: the invariant does not cover what a `VerifiedWarp` or
/// `TimedHold` sink actually does — their own tests must (x11_warp.rs pins
/// the armed hold; the warpd delay lives untested in input.rs, as before).
/// The backend list below is hand-kept, like the enum it mirrors: adding the
/// variant here is part of adding a sink.
#[test]
fn every_pointer_sink_declares_an_edge_discharge_and_routing_follows_it() {
    use crate::config::InputBackend as B;
    for backend in [
        B::Disabled,
        B::DbusAbs,
        B::DbusRel,
        B::Warpd,
        B::GalleryHid,
        B::X11Test,
        B::MameCmd,
        B::MameSock,
        B::ViceSock,
        B::MgaCtl,
        B::ArtistCtl,
        B::RamAbs,
        B::X11Warp,
    ] {
        let builds_router = !matches!(backend, B::Disabled | B::DbusAbs | B::DbusRel);
        let has_pointer = backend.pointer_mode() != "none";
        for knob in [false, true] {
            let d = edge_discharge(backend.as_str(), knob);
            if builds_router && has_pointer {
                assert!(
                    d.is_some(),
                    "pointer sink {:?} declares NO edge discharge: its motion would \
                     route to the sink and its clicks around it -- the mgactl drag \
                     regression. Add an arm to edge_discharge, with the reason.",
                    backend.as_str()
                );
            } else {
                assert_eq!(
                    d,
                    None,
                    "{:?} has no pointer sink and must not declare a discharge",
                    backend.as_str()
                );
            }
            assert_eq!(
                backend_routes_buttons(backend.as_str(), knob),
                d == Some(EdgeDischarge::RoutesEdges),
                "backend_routes_buttons must stay derived from edge_discharge ({:?})",
                backend.as_str()
            );
        }
    }
    // Pin the declared values, so an accidental table edit is red, not silent.
    // warpd: the knob is warpd's alone -- agent buttons by default, and the
    // SH_WARPD_BUTTONS=qemu hybrid is a timed, unverified hold (TimedHold, and
    // named that way on purpose).
    assert_eq!(
        edge_discharge("warpd", false),
        Some(EdgeDischarge::RoutesEdges)
    );
    assert_eq!(
        edge_discharge("warpd", true),
        Some(EdgeDischarge::TimedHold)
    );
    // x11warp: no XTEST on the guest server, nothing to inject an edge WITH;
    // the QueryPointer-confirmed warp + armed hold discharge instead, and the
    // warpd knob must not change it.
    for knob in [false, true] {
        assert_eq!(
            edge_discharge("x11warp", knob),
            Some(EdgeDischarge::VerifiedWarp)
        );
    }
    // The socket/agent sinks take position+edge as one ordered event, knob or
    // no knob. artistctl (hpuxvue) and ramabs (rhapsody) are in this list on
    // purpose: `backend_routes_buttons` is now DERIVED from the table, so a
    // station missing from it silently loses its button routing, and a missing
    // arm is exactly what an enum-driven test cannot see.
    for b in [
        "gallery-hid",
        "x11test",
        "mamecmd",
        "mamesock",
        "mgactl",
        "artistctl",
        "ramabs",
    ] {
        for knob in [false, true] {
            assert_eq!(edge_discharge(b, knob), Some(EdgeDischarge::RoutesEdges));
            assert!(
                backend_routes_buttons(b, knob),
                "{b} must keep routing its edges, knob or no knob"
            );
        }
    }
}

/// The classic D-Bus pointer paths have no sink and must never be listed.
#[test]
fn dbus_pointer_paths_are_not_routed() {
    assert!(!backend_routes_buttons("dbus-abs", false));
    assert!(!backend_routes_buttons("dbus-rel", false));
    assert!(!backend_routes_buttons("disabled", false));
}
