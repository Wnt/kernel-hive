// Per-SESSION held-key bookkeeping, dispatch of type=3 key records, and the
// release the daemon owes the guest when a session ends -- including an
// ABNORMAL end (client vanished, transport closed, task aborted), which is
// the entire point.
//
// THE GAP THIS CLOSES: a visitor's tab can crash mid-keystroke and never send
// the keyup it owes. Nothing upstream of this module tracked what a session
// had put DOWN, so a crashed tab left the guest holding whatever was down
// forever -- unlike `MouseState`'s buttons (input.rs), which at least reset
// on the NEXT session's `reset_for_session()`. The fix has to live in the
// DAEMON: it is the authority on what the guest believes, and a client that
// has crashed cannot clean up after itself.
//
// PER SESSION, NOT PER STATION. `MouseState` (input.rs) is deliberately
// DAEMON-WIDE -- the guest cursor is a property of the guest, and a
// reconnect must keep tracking it rather than corner-chase. Held keys are
// the opposite: a station can carry more than one client (two browser tabs
// open on the same exhibit), and releasing another session's keys on THIS
// session's teardown would be a new bug, worse than the one this module
// exists to fix -- a key vanishing out from under a visitor mid-chord because
// an unrelated tab reloaded. So `KeyState` is created fresh once per
// `handle_session` call (`transport::serve`) and shared only with the tasks
// that drain THAT session's input streams, never with another session's.
//
// TRACKS WHAT WAS ACTUALLY SENT, not what a client claims is held: `held`
// only ever gains a code from `key()` or the router dispatch below actually
// issuing the Press, and only ever loses one the same way for the matching
// Release. A client's own bookkeeping (or its absence, if it crashed) is
// never consulted.
//
// THE `Drop`/I-O CONSTRAINT, and why this is not `MouseState`'s shape
// verbatim. `Drop::drop` cannot `.await`, and the dbus keyboard Release is a
// zbus method call -- genuinely async. `MouseState`'s `Drop` (input.rs)
// answers the same constraint by doing no I/O itself: it only wakes an
// ALREADY-RUNNING task (the rel-bridge pacer) that does the real work. This
// module mirrors that shape exactly: `KeyState::drop` hands its held set to
// an unbounded channel -- `mpsc::UnboundedSender::send` is synchronous,
// never blocks, and cannot fail loudly (a closed receiver just means the
// reaper is already gone, i.e. the station is shutting down and nothing
// downstream cares) -- and a reaper task spawned ONCE per station in
// `transport::serve` (beside the rel-bridge pacer it mirrors) performs the
// actual release.

use std::collections::HashSet;
use std::sync::Arc;

use tokio::sync::{mpsc, Mutex};

use crate::capture::{Capture, CONSOLE, I_KBD};
use crate::config::Config;
use crate::key_quirks::{key_gate, key_qnum, remap_key};
use crate::realtime_input::InputRouter;

/// One session's held-key set: values already resolved to whatever was
/// actually handed to the sink (a router's own key numbering, or QEMU's dbus
/// `qnum`) -- teardown replays exactly that value, not the wire keycode.
pub struct KeyState {
    held: HashSet<u16>,
    reap: mpsc::UnboundedSender<Vec<u16>>,
}

pub type SharedKeys = Arc<Mutex<KeyState>>;

/// A fresh per-session tracker, paired with the station's reaper channel
/// (`run_reaper` below). Never reused across a reconnect -- unlike
/// `MouseState`, a new session owes nothing its predecessor held; the
/// predecessor's own teardown already queued that release.
pub fn new_session(reap: mpsc::UnboundedSender<Vec<u16>>) -> SharedKeys {
    Arc::new(Mutex::new(KeyState {
        held: HashSet::new(),
        reap,
    }))
}

impl KeyState {
    /// Record what was just actually sent. IDEMPOTENT and honest: a repeat
    /// `down` for a code already held, or an `up` for one not held, changes
    /// nothing -- so a double keyup (or a teardown racing a late real one)
    /// never queues a release for a key the guest does not have down.
    fn note_sent(&mut self, value: u16, down: bool) {
        if down {
            self.held.insert(value);
        } else {
            self.held.remove(&value);
        }
    }

    #[cfg(test)]
    pub(crate) fn held_for_test(&self) -> &HashSet<u16> {
        &self.held
    }
}

impl Drop for KeyState {
    /// Session end. No I/O here -- see the module doc. `drain()` empties
    /// `held` before handing it off, so a `KeyState` that somehow drops
    /// twice (it cannot, `Drop` runs once, but the invariant is what makes
    /// the design safe) or races its own last `note_sent` never double-queues.
    fn drop(&mut self) {
        if self.held.is_empty() {
            return;
        }
        let owed: Vec<u16> = self.held.drain().collect();
        let _ = self.reap.send(owed);
    }
}

/// Dispatch one type=3 record (moved out of `input::handle`'s match arm,
/// which is at its own file-size cap, and a natural seam: everything about a
/// key record's life -- routing, pacing/hold, per-session held-state, and
/// its eventual teardown release below -- now lives in one place instead of
/// being split across the dispatch table and a free function).
///
/// `code` is the WIRE keycode after the per-station `SH_KEY_REMAP` rewrite
/// (`remap_key`, still applied by the caller's context via `cfg.key_remap` --
/// done here so callers do not have to import `remap_key` themselves).
pub(crate) async fn handle_key(
    cap: &Capture,
    cfg: &Config,
    router: Option<&Arc<InputRouter>>,
    keys: &SharedKeys,
    raw_code: u16,
    down: bool,
) {
    // The per-station remap rewrites the WIRE code first, so every backend
    // below (and key_qnum's legacy-kbd quirk) sees the key the emulated
    // hardware actually has.
    let code = remap_key(raw_code as u32, &cfg.key_remap);
    // Keyboard-lag evidence chain, first daemon-side link: when this edge
    // ARRIVED, on the wall clock CTLTRACE and the sink tx/ack lines share
    // (SH_INPUT_TELEMETRY >= 1, else free). The backend named is where the
    // edge is ROUTED below: the matrix sinks by name, everything else lands
    // on the QEMU/dbus keyboard path.
    crate::input_telemetry::key_recv(
        router
            .filter(|r| r.routes_keys(cfg))
            .map(|r| r.backend())
            .unwrap_or("dbus"),
        code,
        down,
    );
    // mamecmd/mamesock (the IRIX station) have no D-Bus connection at all --
    // Capture.main_conn is None for every non-QEMU backend, which is exactly
    // why browser keys had never reached that guest. Route it to the key
    // matrix instead (the Lua agent's command file, or the same KEY verbs
    // over the ctlsock control socket); every other backend keeps the
    // classic path byte for byte.
    //
    // gallery-hid is NOT routed here even though its sink implements
    // try_key: it is scoped to Solaris/QNX pointer drivers and has no
    // keyboard minor, so keys stay on QEMU's normal keyboard path. The stock
    // guest keyboard driver consumes this D-Bus injection. x11test joins
    // only when SH_X11TEST_KEYS is set (routes_keys).
    if let Some(router) = router.filter(|r| r.routes_keys(cfg)) {
        let value = code as u16;
        let _ = router.try_key(value, down, false);
        keys.lock().await.note_sent(value, down);
        return;
    }
    key(cap, code, down, cfg, keys).await;
}

async fn send_key(conn: &zbus::Connection, code: u32, qnum: u32, down: bool) {
    let m = if down { "Press" } else { "Release" };
    if let Err(e) = conn
        .call_method(None::<&str>, CONSOLE, Some(I_KBD), m, &(qnum,))
        .await
    {
        eprintln!("[input] key {m} code=0x{code:x} qnum=0x{qnum:x} ERR: {e}");
    }
    crate::input_telemetry::key_sent(code, down);
}

/// The classic QEMU/dbus keyboard path (moved from `input.rs` verbatim,
/// plus the held-key bookkeeping: recorded right after the value that was
/// actually sent, on every exit -- gated or not -- so `held` always matches
/// what the guest was last told).
pub(crate) async fn key(cap: &Capture, code: u32, down: bool, cfg: &Config, keys: &SharedKeys) {
    let Some(conn) = cap.main_conn.as_ref() else {
        return;
    };
    let qnum = key_qnum(code, cfg.legacy_kbd);
    if cfg.key_min_hold_ms == 0 && cfg.key_min_gap_ms == 0 {
        send_key(conn, code, qnum, down).await;
        keys.lock().await.note_sent(qnum as u16, down);
        return;
    }
    // Both knobs share ONE gate, so a whole pasted line is paced in arrival
    // order: press -> (hold) -> release -> (gap) -> next press. Events queue
    // behind the mutex when the client types faster than the pacing allows;
    // nothing is reordered and nothing is dropped.
    let min_hold = std::time::Duration::from_millis(cfg.key_min_hold_ms);
    let min_gap = std::time::Duration::from_millis(cfg.key_min_gap_ms);
    let mut gate = key_gate().lock().await;
    if down {
        let wait = gate.press_delay(std::time::Instant::now(), min_gap);
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
        send_key(conn, code, qnum, true).await;
        keys.lock().await.note_sent(qnum as u16, true);
        gate.on_press(qnum, std::time::Instant::now());
    } else {
        let wait = gate.release_delay(qnum, std::time::Instant::now(), min_hold);
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
        send_key(conn, code, qnum, false).await;
        keys.lock().await.note_sent(qnum as u16, false);
        gate.on_release(std::time::Instant::now());
    }
}

/// Send a bare Release straight to the guest keyboard, bypassing BOTH the
/// `SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS` pacing gate (there is no longer a
/// session to pace fairly against; nothing queues behind one that no longer
/// exists) and the keyboard-lag CTLTRACE evidence chain
/// (`input_telemetry::key_sent`, docs/lab/keyboard-lag-investigation): this
/// is a synthetic release the daemon owes the guest at TEARDOWN, not a
/// keystroke a visitor made, and counting it as one would corrupt that
/// chain's "when did this edge arrive" story. For the same reason it never
/// goes near `input_trace.rs`'s sampled per-input spans -- this function is
/// reached only from the reaper below, never from `input::handle`'s dispatch
/// table, so a teardown release cannot be mistaken for a visitor action.
async fn force_release_dbus(cap: &Capture, qnum: u16) {
    let Some(conn) = cap.main_conn.as_ref() else {
        return;
    };
    if let Err(e) = conn
        .call_method(
            None::<&str>,
            CONSOLE,
            Some(I_KBD),
            "Release",
            &(qnum as u32,),
        )
        .await
    {
        eprintln!("[input] teardown release qnum=0x{qnum:x} ERR: {e}");
    }
}

/// Count one forced release. Split out of `run_reaper`'s loop body to the
/// smallest possible unit so the counting behaviour -- "the probe counts
/// what it claims" -- is testable without a live `Capture`/router (the
/// codebase's tests never construct either; see `capture/mod.rs`).
fn count_forced_release() {
    crate::probes::probe!(KEY_FORCE_RELEASE_TEARDOWN);
}

/// The reaper: one per station, spawned once in `transport::serve` beside the
/// rel-bridge pacer it mirrors. Drains every session's held-key batch as
/// sessions end and releases each value the same way it was sent -- through
/// the router when this station routes keys, otherwise straight down the
/// dbus path -- exactly as `handle_key` decided for the live keystroke.
/// Routing is a STATION-level fact (`cfg` + the router's own backend), fixed
/// for the process lifetime, so it is resolved once here rather than per
/// released key.
pub async fn run_reaper(
    cap: Capture,
    cfg: Arc<Config>,
    router: Option<Arc<InputRouter>>,
    mut rx: mpsc::UnboundedReceiver<Vec<u16>>,
) {
    let routed = router.as_ref().filter(|r| r.routes_keys(&cfg)).cloned();
    while let Some(owed) = rx.recv().await {
        for value in owed {
            count_forced_release();
            match &routed {
                Some(r) => {
                    let _ = r.try_key(value, false, false);
                }
                None => force_release_dbus(&cap, value).await,
            }
        }
    }
}

#[cfg(test)]
#[path = "key_state_tests.rs"]
mod tests;
