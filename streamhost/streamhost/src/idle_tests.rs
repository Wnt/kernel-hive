//! Unit tests for `idle` — split into a sibling file purely for the per-file
//! line budget; `#[path]` keeps them the same inline `mod tests`, with the same
//! access to the module's private items.
//!
//! These tests ARE the specification of the auto-pause policy: when a guest may
//! be frozen, when it must be woken, and what a driver's wake lease overrides.
use super::{
    lease_live, read_result, reconcile_action, signal_pidfile, Action, Snapshot, LEASE_TTL,
};
use std::time::Duration;

const G: Duration = Duration::from_secs(60);

/// A warm station with nobody on it and nothing unusual going on. Every test
/// below states only what it changes.
const IDLE: Snapshot = Snapshot {
    sessions: 0,
    paused: false,
    idle_for: Duration::ZERO,
    grace: G,
    heal_due: false,
    warmed_up: true,
    observed_stopped: false,
    wake_leased: false,
};

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

fn act(w: Snapshot) -> Action {
    reconcile_action(w)
}

#[test]
fn pauses_after_grace_when_idle() {
    assert_eq!(
        act(Snapshot {
            idle_for: secs(61),
            ..IDLE
        }),
        Action::Stop
    );
}

#[test]
fn no_pause_before_grace() {
    assert_eq!(
        act(Snapshot {
            idle_for: secs(59),
            ..IDLE
        }),
        Action::None
    );
}

#[test]
fn never_paused_under_active_session() {
    // Active session + stale pause belief (a cont failed): must resume.
    assert_eq!(
        act(Snapshot {
            sessions: 1,
            paused: true,
            idle_for: secs(999),
            heal_due: true,
            ..IDLE
        }),
        Action::Cont
    );
    // Active session, running: nothing to do, regardless of idle clock.
    assert_eq!(
        act(Snapshot {
            sessions: 2,
            idle_for: secs(999),
            heal_due: true,
            ..IDLE
        }),
        Action::None
    );
}

#[test]
fn resumes_a_guest_someone_else_stopped_under_a_live_session() {
    // vic20, 2026-08-16: the LAUNCHER's delayed standby freeze (it covers
    // the first grace period, which the daemon cannot) SIGSTOPped the
    // emulator ~8 s after launch — which on a cold station is exactly when
    // the first visitor arrives, because the visit is what starts it. We
    // never paused it, so the belief is false; only the OBSERVATION saves
    // the session. Without this the guest stays frozen: no frames, no keys.
    assert_eq!(
        act(Snapshot {
            sessions: 1,
            idle_for: secs(1),
            observed_stopped: true,
            ..IDLE
        }),
        Action::Cont
    );
    // Warmup must not withhold a resume, same as the belief path.
    assert_eq!(
        act(Snapshot {
            sessions: 1,
            idle_for: secs(1),
            warmed_up: false,
            observed_stopped: true,
            ..IDLE
        }),
        Action::Cont
    );
    // No session: an observed-stopped guest is stopped ON PURPOSE. Never
    // resume it — that would undo standby and burn a core forever.
    assert_eq!(
        act(Snapshot {
            paused: true,
            idle_for: secs(1),
            observed_stopped: true,
            ..IDLE
        }),
        Action::None
    );
}

#[test]
fn believed_pause_reasserted_only_on_heal_tick() {
    // Already paused: no per-tick QMP chatter...
    assert_eq!(
        act(Snapshot {
            paused: true,
            idle_for: secs(300),
            ..IDLE
        }),
        Action::None
    );
    // ...but the heal tick re-stops (self-heal after an external labctl cont).
    assert_eq!(
        act(Snapshot {
            paused: true,
            idle_for: secs(300),
            heal_due: true,
            ..IDLE
        }),
        Action::Stop
    );
}

/// Warmup withholds the FIRST pause so a station whose own health machinery
/// needs the guest running (irix's livewatch, whose probe is the only thing
/// that clears the instant-restore budget) gets its look.
#[test]
fn warmup_withholds_the_freeze_but_never_a_resume() {
    // Long past grace, but not warmed up: do not pause.
    assert_eq!(
        act(Snapshot {
            idle_for: secs(999),
            warmed_up: false,
            ..IDLE
        }),
        Action::None
    );
    // Not even the heal re-assert fires early.
    assert_eq!(
        act(Snapshot {
            paused: true,
            idle_for: secs(999),
            heal_due: true,
            warmed_up: false,
            ..IDLE
        }),
        Action::None
    );
    // A resume is never withheld: a session under a stale pause belief
    // must be thawed no matter where the warmup clock stands.
    assert_eq!(
        act(Snapshot {
            sessions: 1,
            paused: true,
            idle_for: secs(1),
            warmed_up: false,
            ..IDLE
        }),
        Action::Cont
    );
    // ...and once warm, the same idle state freezes as usual.
    assert_eq!(
        act(Snapshot {
            idle_for: secs(999),
            ..IDLE
        }),
        Action::Stop
    );
}

/// A driver's wake lease counts exactly like a session as far as the freeze
/// is concerned.
///
/// This is the folklore killer. Before it, an out-of-band driver typing into
/// a station with no visitor was re-frozen by the heal re-assert up to 60 s
/// in, and every keystroke after that point was accepted and discarded with
/// an OK on the wire — which is what "send `cont` and your input
/// back-to-back on ONE connection" was really working around.
#[test]
fn a_live_wake_lease_holds_the_guest_awake() {
    // Idle far past grace, no session — but a driver holds the lease.
    assert_eq!(
        act(Snapshot {
            idle_for: secs(999),
            wake_leased: true,
            ..IDLE
        }),
        Action::None
    );
    // ...and not even the heal re-assert, which is the exact tick that used
    // to land in the middle of a driver's sequence.
    assert_eq!(
        act(Snapshot {
            paused: true,
            idle_for: secs(999),
            heal_due: true,
            wake_leased: true,
            ..IDLE
        }),
        Action::Cont
    );
    // A guest we already paused is RESUMED for the driver, so a lease taken
    // against a sleeping station wakes it rather than just pinning it asleep.
    assert_eq!(
        act(Snapshot {
            paused: true,
            idle_for: secs(1),
            wake_leased: true,
            ..IDLE
        }),
        Action::Cont
    );
    // An observed-stopped emulator under a lease is resumed too — the signal
    // freezer's twin of the line above.
    assert_eq!(
        act(Snapshot {
            idle_for: secs(1),
            observed_stopped: true,
            wake_leased: true,
            ..IDLE
        }),
        Action::Cont
    );
}

/// The lease must never become "this station stops pausing". It expires, and
/// the moment it does the ordinary policy resumes — which is what preserves
/// the measured ~10%-of-a-core-per-station saving idle-pause exists for.
#[test]
fn an_expired_lease_pauses_exactly_as_before() {
    assert_eq!(
        act(Snapshot {
            idle_for: secs(999),
            ..IDLE
        }),
        Action::Stop
    );
}

/// `lease_live` is the whole lease protocol: an mtime, nothing parsed.
#[test]
fn lease_freshness_is_mtime_and_nothing_else() {
    let p = std::env::temp_dir().join(format!("sh-wake-lease-{}", std::process::id()));
    // No file at all is the common case: no driver has ever run here.
    std::fs::remove_file(&p).ok();
    assert!(!lease_live(&p.to_string_lossy(), LEASE_TTL));
    // A driver's touch.
    std::fs::write(&p, b"").unwrap();
    assert!(lease_live(&p.to_string_lossy(), LEASE_TTL));
    // The SAME file against a zero TTL is expired — the driver went away,
    // and the station goes back to pausing normally.
    assert!(!lease_live(&p.to_string_lossy(), Duration::ZERO));
    std::fs::remove_file(&p).ok();
}

#[test]
fn qmp_result_skips_events() {
    // `stop` emits a STOP event before its return — must be skipped.
    let mut r = std::io::Cursor::new(
        b"{\"timestamp\": {\"seconds\": 1}, \"event\": \"STOP\"}\n{\"return\": {}}\n".to_vec(),
    );
    assert!(read_result(&mut r).is_ok());
}

/// A pidfile path in the temp dir, unique to this process and `tag`.
fn tmp_pidfile(tag: &str, body: &str) -> String {
    let p = std::env::temp_dir().join(format!("sh-idle-test-{}-{tag}", std::process::id()));
    std::fs::write(&p, body).unwrap();
    p.to_string_lossy().into_owned()
}

/// SIGCONT on an already-running process is a no-op, so the happy path can
/// safely target the test process itself. (SIGSTOP obviously cannot.)
#[test]
fn signal_pidfile_signals_the_recorded_pid() {
    let pf = tmp_pidfile("ok", &format!("{}\n", std::process::id()));
    assert!(signal_pidfile(&pf, None, libc::SIGCONT).is_ok());
    std::fs::remove_file(&pf).ok();
}

/// The stale-pidfile guard: right pid, wrong process. This is the case that
/// would otherwise SIGSTOP an unrelated process after a pid recycle.
#[test]
fn signal_pidfile_refuses_on_cmdline_mismatch() {
    let pf = tmp_pidfile("mismatch", &format!("{}\n", std::process::id()));
    let e = signal_pidfile(&pf, Some("no-such-emulator-xyzzy"), libc::SIGCONT).unwrap_err();
    assert!(e.to_string().contains("stale pidfile"), "{e}");
    std::fs::remove_file(&pf).ok();
}

/// Every unusable pidfile is an Err the reconciler retries on, never a
/// signal sent somewhere else. Empty is the live case: the launcher's
/// kill_pidfile truncates the file on teardown.
#[test]
fn signal_pidfile_refuses_unusable_files() {
    for (tag, body) in [("empty", ""), ("garbage", "not-a-pid\n"), ("init", "1\n")] {
        let pf = tmp_pidfile(tag, body);
        assert!(
            signal_pidfile(&pf, None, libc::SIGCONT).is_err(),
            "pidfile body {body:?} must be refused"
        );
        std::fs::remove_file(&pf).ok();
    }
    let missing = std::env::temp_dir().join("sh-idle-test-does-not-exist");
    assert!(signal_pidfile(&missing.to_string_lossy(), None, libc::SIGCONT).is_err());
}

#[test]
fn qmp_error_and_eof_reported() {
    let mut r = std::io::Cursor::new(b"{\"error\": {\"class\": \"GenericError\"}}\n".to_vec());
    assert!(read_result(&mut r).is_err());
    let mut r = std::io::Cursor::new(Vec::new());
    assert!(read_result(&mut r).is_err());
}
