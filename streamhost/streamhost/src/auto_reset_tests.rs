use super::{decide, Snap, Why};

const S: u64 = 1000;

fn snap() -> Snap {
    Snap {
        now: 1_000 * S,
        sessions: 0,
        idle_since: 0,
        last_input: 0,
        last_reset: 0,
        leased: false,
        resetting: false,
        after_session: 30 * S,
        input_idle: 600 * S,
    }
}

#[test]
fn untouched_guest_is_never_reset() {
    // No input ever: nothing to undo, however long nobody watched.
    assert_eq!(decide(snap()), None);
    let s = Snap {
        sessions: 1,
        ..snap()
    };
    assert_eq!(decide(s), None);
}

#[test]
fn session_end_resets_after_the_grace() {
    let left = Snap {
        idle_since: 990 * S,
        last_input: 985 * S,
        ..snap()
    };
    assert_eq!(
        decide(left),
        None,
        "10 s after leaving: a reload may still come back"
    );
    let later = Snap {
        now: 1_021 * S,
        ..left
    };
    assert_eq!(decide(later), Some(Why::SessionEnded));
}

#[test]
fn a_returning_session_cancels_the_session_end_reset() {
    let back = Snap {
        sessions: 1,
        idle_since: 900 * S,
        last_input: 980 * S,
        ..snap()
    };
    assert_eq!(decide(back), None);
}

#[test]
fn input_idle_resets_an_open_tab() {
    let open = Snap {
        sessions: 1,
        last_input: 399 * S,
        ..snap()
    };
    assert_eq!(decide(open), Some(Why::InputIdle));
    let active = Snap {
        last_input: 700 * S,
        ..open
    };
    assert_eq!(decide(active), None);
}

#[test]
fn one_reset_per_dirty_period() {
    let done = Snap {
        idle_since: 100 * S,
        last_input: 90 * S,
        last_reset: 200 * S,
        ..snap()
    };
    assert_eq!(decide(done), None, "no input since the last reset");
    let touched_again = Snap {
        last_input: 201 * S,
        ..done
    };
    assert_eq!(decide(touched_again), Some(Why::SessionEnded));
}

#[test]
fn lease_and_running_reset_withhold() {
    let due = Snap {
        idle_since: 100 * S,
        last_input: 90 * S,
        ..snap()
    };
    assert_eq!(decide(due), Some(Why::SessionEnded));
    assert_eq!(
        decide(Snap {
            leased: true,
            ..due
        }),
        None
    );
    assert_eq!(
        decide(Snap {
            resetting: true,
            ..due
        }),
        None
    );
}

#[test]
fn triggers_are_independent() {
    let due = Snap {
        idle_since: 100 * S,
        last_input: 90 * S,
        ..snap()
    };
    assert_eq!(
        decide(Snap {
            after_session: 0,
            ..due
        }),
        Some(Why::InputIdle)
    );
    assert_eq!(
        decide(Snap {
            after_session: 0,
            input_idle: 0,
            ..due
        }),
        None
    );
}
