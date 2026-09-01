//! Unit tests for `key_state` -- split into a sibling file purely for the
//! per-file line budget, same convention as `input_tests.rs`.
//!
//! These test the bookkeeping (`KeyState`/`Drop`/the reaper channel) in
//! isolation from the actual guest I/O, matching the rest of this crate's
//! test style: nothing here constructs a `Capture` or an `InputRouter` (see
//! `capture/mod.rs` -- no test in the tree does, because neither is cheaply
//! constructible without real QEMU/socket plumbing). What matters for THIS
//! gap -- a crashed tab's held keys must be released, exactly once, and
//! never another session's -- is entirely captured by what gets queued onto
//! the reaper channel, which is the seam these tests exercise directly.
use super::*;

fn channel() -> (
    mpsc::UnboundedSender<Vec<u16>>,
    mpsc::UnboundedReceiver<Vec<u16>>,
) {
    mpsc::unbounded_channel()
}

/// THE GAP, closed: a session that never sent its keyups (the crashed-tab
/// case) still releases everything it left down, the moment it ends.
#[test]
fn teardown_releases_keys_still_held() {
    let (tx, mut rx) = channel();
    {
        let session = new_session(tx);
        let mut st = session.blocking_lock();
        st.note_sent(0x1e, true); // 'A' down
        st.note_sent(0x30, true); // 'B' down
        drop(st);
        // `session` drops here -> KeyState::drop -> queued on `rx`.
    }
    let owed = rx.try_recv().expect("teardown must queue a release batch");
    let owed: std::collections::HashSet<u16> = owed.into_iter().collect();
    assert_eq!(owed, [0x1e, 0x30].into_iter().collect());
    assert!(rx.try_recv().is_err(), "exactly one batch, not one per key");
}

/// The normal path -- every press matched by a keyup before the session
/// ends -- leaves nothing owed. A teardown that fires anyway would spam the
/// guest with releases for keys it does not have down.
#[test]
fn normal_keyup_path_leaves_nothing_to_release_at_teardown() {
    let (tx, mut rx) = channel();
    {
        let session = new_session(tx);
        let mut st = session.blocking_lock();
        st.note_sent(0x1e, true);
        st.note_sent(0x1e, false); // matched keyup, in-session
        drop(st);
    }
    assert!(
        rx.try_recv().is_err(),
        "nothing was left held; teardown must not invent a release"
    );
}

/// IDEMPOTENT: a repeated press does not double-count, and a release of a
/// key that was never (or already) pressed is a silent no-op -- never a
/// release the guest did not ask to have undone.
#[test]
fn note_sent_is_idempotent() {
    let (tx, _rx) = channel();
    let session = new_session(tx);
    let mut st = session.blocking_lock();

    st.note_sent(0x1e, true);
    st.note_sent(0x1e, true); // repeat press: still just one held key
    assert_eq!(st.held_for_test().len(), 1);

    st.note_sent(0x1e, false);
    st.note_sent(0x1e, false); // repeat release: no panic, nothing held
    assert!(st.held_for_test().is_empty());

    st.note_sent(0x99, false); // release of a key never pressed: no-op
    assert!(st.held_for_test().is_empty());
}

/// PER SESSION, NOT GLOBAL: two sessions sharing one station (and, as in
/// production, one reaper channel) must never cross-release. Session B
/// holding nothing at teardown must not touch session A's still-held key,
/// and A's own batch must contain only what A held.
#[test]
fn a_sessions_teardown_never_releases_another_sessions_keys() {
    let (tx, mut rx) = channel();

    let session_a = new_session(tx.clone());
    session_a.blocking_lock().note_sent(0x1e, true); // A holds 'A' down

    let session_b = new_session(tx);
    session_b.blocking_lock().note_sent(0x30, true); // B holds 'B' down
    session_b.blocking_lock().note_sent(0x30, false); // ...then releases it itself

    drop(session_b); // nothing owed: must not queue anything, must not touch A
    assert!(
        rx.try_recv().is_err(),
        "session B held nothing at its own teardown"
    );

    assert_eq!(
        session_a.blocking_lock().held_for_test().len(),
        1,
        "session A's held key must be untouched by B's teardown"
    );

    drop(session_a);
    let owed = rx
        .try_recv()
        .expect("session A's own teardown must release its key");
    assert_eq!(owed, vec![0x1e]);
}

/// The probe is the whole point of this plane (docs/ANALYTICS.md §8): a
/// recurrence must be a number, not an anecdote. `count_forced_release` is
/// the entire counting surface `run_reaper` uses, one call per key actually
/// released -- prove it moves the SAME probe `run_reaper` calls, by exactly
/// the number of keys.
#[test]
fn probe_counts_exactly_the_keys_force_released() {
    let before = crate::probes::KEY_FORCE_RELEASE_TEARDOWN.hits();
    for _ in 0..3 {
        count_forced_release();
    }
    assert_eq!(crate::probes::KEY_FORCE_RELEASE_TEARDOWN.hits(), before + 3);
}
