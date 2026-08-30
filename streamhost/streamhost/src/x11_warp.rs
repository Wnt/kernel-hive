//! `x11warp` pointer sink: the guest's own X server as actuator AND sensor.
//!
//! `sunos414` (SunOS 4.1.4 / OpenWindows, QEMU sparc) draws on a cg3 — a dumb
//! framebuffer with NO hardware cursor, so neither closed-loop port (`mgactl`,
//! `mamesock`) has a register to read and no loop can converge on a
//! measurement. But the guest's X11R5 `xnews` server is reachable over a
//! loopback-only SLIRP forward (`SH_X11WARP_DISPLAY`, e.g. `127.0.0.1:47`),
//! and it IS both halves of a different loop:
//!
//! - `WarpPointer(dst=root, x, y)` moves the pointer to an ABSOLUTE root
//!   coordinate and the guest repaints immediately (framebuffer-proven).
//! - `QueryPointer(root)` reads the guest's own idea of the position back,
//!   exactly.
//!
//! The server has NO XTEST (verified via ListExtensions), so buttons and keys
//! CANNOT be injected through X — they keep riding the QEMU D-Bus PS/2 path.
//! That is why this sink declares `EdgeDischarge::VerifiedWarp` rather than
//! `RoutesEdges`: the edge travels on a DIFFERENT channel with independent
//! latency, and an unconfirmed sequence produces press-at-A / motion /
//! release-at-B — a spurious DRAG. Sequencing alone cannot fix that; only the
//! `QueryPointer` round-trip confirming the warp landed can.
//!
//! **Why confirm -> inject -> done cannot be interleaved by motion.** A
//! confirmation that is merely PRIOR to the injection is not enough: a move
//! drained between the confirming QueryPointer and the D-Bus edge landing
//! would make the confirmation true when taken and false when the edge
//! applies. So on a confirmed readback the worker ARMS an exclusion window
//! and stops draining the move slot entirely — moves keep arriving and keep
//! updating browser truth; they are simply not APPLIED. Under this backend
//! motion reaches the guest ONLY through this sink (the single-injector rule
//! below), so suspending the worker's own drain genuinely excludes a
//! concurrent motion from landing inside the window. THAT ARGUMENT STOPS
//! BEING TRUE THE MOMENT A SECOND MOTION PATH EXISTS (a relative fallback,
//! QMP `input-send-event`, a labctl pointer helper): the exclusion is exactly
//! as real as the single-injector rule. input.rs signals `edge_done()` after
//! the injection returns; if it never arrives the window expires after
//! `EDGE_HOLD_MAX`, counted `arm-expired` and logged — never silent.
//!
//! **What "success" for a button edge means here — HANDOFF, not
//! application.** This sink never carries the edge. When the gate releases,
//! what has actually been witnessed is: the warp to the edge's coordinates
//! was CONFIRMED by the guest's own QueryPointer, and the motion drain is
//! suspended while the edge is HANDED OFF to the D-Bus PS/2 path. Whether
//! the guest APPLIED the edge is not observed — the PS/2 channel has no ack
//! (contrast `mgactl`, whose DOWN/UP acks when the edge APPLIES, ~5.6-35 ms
//! measured, while MOVEA acks on acceptance in ~100-200 us). STAT therefore
//! says `edge-witness=warp-confirmed-then-handoff`, and no counter here is
//! named "delivered".
//!
//! **Fail closed, never silently.** The server may be down (guest at the
//! console, X restarted, `xhost` grant missing). Connect or request failures
//! mark `SinkHealth::Down`, log once per transition with the concrete error,
//! and reject offers with `Reject::BackendDown` — the pointer must never
//! silently do nothing. Health never claims Healthy on an unconfirmed
//! readback: a give-up tears the connection down and the reconnect must
//! re-prove the round trip before Healthy is restated.
//!
//! **Single injector (BINDING).** While this connection is up nothing else may
//! push MOTION at this guest's pointer — not `dbus-rel`, not QMP
//! `input-send-event`, not a `labctl` helper — or the warp/readback pair
//! races a second mover, the confirmation means nothing, and the armed
//! window excludes nothing.
//!
//! Field notes from the sandbox rig (2026-08-30), for the next person:
//!
//! - QEMU's Sun mouse keeps a dx/dy ACCUMULATOR that drains only ±127 per
//!   sync (`sunmouse_sync`, hw/char/escc.c: clamp to ±127, emit, subtract).
//!   A large relative injection leaves a residue that bleeds 127 px into
//!   EVERY subsequent event — including a button-only one. Measured: after
//!   big rel test injections, warp to (723,649) + press moved the pointer to
//!   (596,522) and the release to (469,395), −127,−127 per edge; on a fresh
//!   `loadvm golden` restore with no rel motion ever injected the same
//!   warp+press+release holds (723,649) throughout. x11warp injects no
//!   relative motion, so it cannot CREATE the residue — and there is no
//!   relative FALLBACK on this station either: `apply_move_abs` returns as
//!   soon as a router exists, so a `BackendDown` move is dropped and counted,
//!   never rerouted (the pointer stops until X is back; that is the true
//!   degraded mode, and it is worse than "falls back to relative"). The
//!   residue therefore only arrives from OUTSIDE the daemon — a `labctl`
//!   pointer helper, a QMP `mouse_move`, a rollback to `dbus-rel` — and it
//!   outlives whoever left it. Zero-valued rel events do NOT drain it (QEMU
//!   drops them); draining needs real ±1 events, one sync each, and this sink
//!   has no relative channel to send them on — so this note is the mitigation.
//! - The guest's Y axis is INVERTED relative to QEMU rel input (a positive
//!   dy moves the guest pointer UP), and OpenWindows ships acceleration 2/1
//!   threshold 15. Moot under x11warp; fatal to anything that injects relative
//!   motion here assuming otherwise.
//!
//! Shape is `MgaCtlSink`'s, proven: browser receive paths only `try_lock` and
//! offer; connect/warp/query/reconnect live in one background worker.
//! Move-only targets coalesce latest-wins; ordered targets ride a bounded
//! queue and flush the pending move ahead of themselves.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, TryLockError};
use std::time::{Duration, Instant};

use crate::realtime_input::{AcceptedSeq, PointerAbs, RealtimeInputSink, Reject, SinkHealth};

const ORDERED_CAPACITY: usize = 64;
/// Readback attempts per ordered target before the sink refuses to claim
/// success (counted `warp-gaveup`, connection torn down, health Down).
const VERIFY_TRIES: usize = 3;
/// One bound for both halves of the edge hold: how long input.rs waits for
/// the confirmation, and how long the armed exclusion window survives without
/// `edge_done()` — the same 600 ms the `dbus-rel` paced bridge uses. A
/// stalled X server or a lost caller delays a click; it never eats one, and
/// both expiries are counted.
const EDGE_HOLD_MAX: Duration = Duration::from_millis(600);
const HEALTH_STARTING: u8 = 0;
const HEALTH_HEALTHY: u8 = 1;
const HEALTH_DOWN: u8 = 2;
/// Last-readback verdict for the stat line: the health signal must be able to
/// say "I do not know".
const READBACK_NONE: u8 = 0;
const READBACK_CONFIRMED: u8 = 1;
const READBACK_UNCONFIRMED: u8 = 2;

/// `SH_X11WARP_TRACE=on|1`: per-event tracing — ingress, every warp, every
/// readback with its verdict. journald supplies the timestamps.
static TRACE: OnceLock<bool> = OnceLock::new();

fn trace_on() -> bool {
    *TRACE.get_or_init(|| {
        std::env::var("SH_X11WARP_TRACE")
            .map(|v| v == "on" || v == "1")
            .unwrap_or(false)
    })
}

/// `SH_X11WARP_DISPLAY` (e.g. `127.0.0.1:47`), REQUIRED when the backend is
/// selected: a guessed default could point WarpPointer at the wrong X server,
/// which moves somebody else's pointer. Read here rather than carried on
/// `Config` for the same reason as `mga_ctl::socket_from_env`: `config/mod.rs`
/// is at its hard file-size budget, and a sink owning its own knob is the
/// established shape.
pub fn display_from_env() -> String {
    std::env::var("SH_X11WARP_DISPLAY").unwrap_or_else(|_| {
        panic!(
            "SH_X11WARP_DISPLAY is required with SH_INPUT_BACKEND=x11warp \
             (the station launcher's loopback hostfwd, e.g. 127.0.0.1:47); \
             there is no display safe to guess"
        )
    })
}

/// Where the launcher's check drops a marker when it had to REPAIR the X access
/// state at runtime instead of finding it in the checkpoint. Optional: unset
/// means "this station has no such check", not "all is well".
///
/// It exists so the transitional state is QUERYABLE and not merely logged. A
/// station repaired on every restore otherwise looks perfectly healthy — the
/// pointer works — and the checkpoint debt the bake was meant to remove sits
/// there indefinitely with nothing but a log line to say so.
pub fn repair_marker_from_env() -> Option<std::path::PathBuf> {
    std::env::var("SH_X11WARP_REPAIR_MARKER")
        .ok()
        .filter(|v| !v.is_empty())
        .map(std::path::PathBuf::from)
}

/// `baked` (the checkpoint carries the X access state, as designed),
/// `REPAIRED-AT-RUNTIME` (it did not, and the launcher patched it in — the
/// checkpoint needs recapturing), or `unknown` (no marker configured).
fn golden_state(marker: Option<&std::path::Path>) -> &'static str {
    match marker {
        None => "unknown",
        Some(p) if p.exists() => "REPAIRED-AT-RUNTIME",
        Some(_) => "baked",
    }
}

#[derive(Default)]
struct Counters {
    accepted: AtomicU64,
    coalesced: AtomicU64,
    dropped: AtomicU64,
    overflow: AtomicU64,
    backend_down: AtomicU64,
    warps: AtomicU64,
    /// Ordered warps whose QueryPointer readback matched the target.
    confirmed: AtomicU64,
    retries: AtomicU64,
    /// Ordered warps the sink GAVE UP on after `VERIFY_TRIES` disagreeing
    /// readbacks (or a disconnect with edges still held). Kept apart from
    /// `confirmed` on purpose: an instrument that counts a give-up as a
    /// success cancels itself out.
    gaveup: AtomicU64,
    hold_timeout: AtomicU64,
    /// Armed windows that expired without `edge_done()` — a caller that
    /// panicked or bailed between the gate release and the injection.
    arm_expired: AtomicU64,
}

/// One warp target. `verify` marks an ordered record's restate: it must be
/// confirmed by QueryPointer before the edge held behind it is released.
struct Warp {
    x: u32,
    y: u32,
    verify: bool,
}

struct Pending {
    /// Latest-wins target; move-only events coalesce here.
    latest_move: Option<(u32, u32)>,
    ordered: VecDeque<Warp>,
    /// Browser-truth target, kept fresh even while the backend is down or an
    /// edge is armed: it seeds the reconnect restate.
    cur_x: u32,
    cur_y: u32,
}

struct Shared {
    pending: Mutex<Pending>,
    /// Wakes the worker (a blocking thread — x11rb's RustConnection is
    /// synchronous, so no async task can own it).
    cv: Condvar,
    health: AtomicU8,
    counters: Counters,
    closed: AtomicBool,
    /// Ordered targets enqueued but not yet confirmed/given-up: the edge gate.
    edge_pending: AtomicU64,
    /// Wakes `wait_settled_on` (async input.rs) when `edge_pending` drops.
    settled: tokio::sync::Notify,
    /// The confirm->inject->done exclusion window: set by the worker on a
    /// confirmed readback BEFORE the gate releases, cleared by `edge_done()`
    /// after the D-Bus injection (or by the counted expiry). While set, the
    /// worker applies NO motion.
    armed: AtomicBool,
    readback: AtomicU8,
    last_err: Mutex<String>,
    /// See `repair_marker_from_env`.
    repair_marker: Option<std::path::PathBuf>,
}

impl Shared {
    fn stat_line(&self) -> String {
        let c = &self.counters;
        let readback = match self.readback.load(Ordering::Relaxed) {
            READBACK_CONFIRMED => "confirmed",
            READBACK_UNCONFIRMED => "unconfirmed",
            _ => "none",
        };
        let err = self
            .last_err
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        // `edge-witness` is a fixed statement of scope, not a counter: what a
        // released edge gate has actually observed is the confirmed warp and
        // the handoff — never the guest applying the edge (module doc).
        //
        // `on-backend-down=motion-stops` is likewise a statement of scope, and
        // it is there so nobody has to infer the degraded mode from a rising
        // `backend-down` counter: there is NO fallback, deliberately (module
        // doc). `golden-state` makes the launcher's runtime repair queryable
        // rather than merely logged.
        format!(
            "accepted={} coalesced={} dropped={} overflow={} backend-down={} warps={} \
             warp-confirmed={} warp-retries={} warp-gaveup={} hold-timeout={} arm-expired={} \
             last-readback={} edge-witness=warp-confirmed-then-handoff \
             on-backend-down=motion-stops golden-state={} last-err={}",
            c.accepted.load(Ordering::Relaxed),
            c.coalesced.load(Ordering::Relaxed),
            c.dropped.load(Ordering::Relaxed),
            c.overflow.load(Ordering::Relaxed),
            c.backend_down.load(Ordering::Relaxed),
            c.warps.load(Ordering::Relaxed),
            c.confirmed.load(Ordering::Relaxed),
            c.retries.load(Ordering::Relaxed),
            c.gaveup.load(Ordering::Relaxed),
            c.hold_timeout.load(Ordering::Relaxed),
            c.arm_expired.load(Ordering::Relaxed),
            readback,
            golden_state(self.repair_marker.as_deref()),
            if err.is_empty() { "-" } else { &err },
        )
    }

    /// Release one held edge (confirmed or given up — the wait is what is
    /// bounded, the VERDICT is what is never faked).
    fn release_edge(&self, verdict: u8) {
        self.readback.store(verdict, Ordering::Release);
        if self.edge_pending.load(Ordering::Acquire) > 0 {
            self.edge_pending.fetch_sub(1, Ordering::AcqRel);
        }
        self.settled.notify_waiters();
    }

    /// The worker's next warp — `None` while an edge is ARMED: motion keeps
    /// updating the slot but must not be APPLIED, which is the entire
    /// confirm->inject->done exclusion (module doc).
    fn take_next(&self) -> Option<Warp> {
        if self.armed.load(Ordering::Acquire) {
            return None;
        }
        let mut p = self
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        p.ordered.pop_front().or_else(|| {
            p.latest_move.take().map(|(x, y)| Warp {
                x,
                y,
                verify: false,
            })
        })
    }

    /// True when the armed window has outlived `EDGE_HOLD_MAX`: disarm and
    /// count it LOUDLY — an expiry must never be silent, it means a caller
    /// left the injection path without signalling `edge_done()`.
    fn expire_arm_if_due(&self, since: Instant) -> bool {
        if since.elapsed() < EDGE_HOLD_MAX {
            return false;
        }
        self.counters.arm_expired.fetch_add(1, Ordering::Relaxed);
        self.armed.store(false, Ordering::Release);
        eprintln!(
            "[x11warp] armed edge window EXPIRED without edge_done ({} total); resuming motion",
            self.counters.arm_expired.load(Ordering::Relaxed)
        );
        true
    }

    fn set_err(&self, msg: &str) {
        let mut e = self
            .last_err
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // Log once per transition: only when the concrete error changes.
        if *e != msg {
            eprintln!("[x11warp] {msg}");
            *e = msg.to_string();
        }
    }
}

pub struct X11WarpSink {
    shared: Arc<Shared>,
}

/// The process-wide sink's shared state, for the edge gate in `input.rs`.
/// There is at most one input backend per process (`InputRouter::from_config`).
static GATE: OnceLock<Arc<Shared>> = OnceLock::new();

impl X11WarpSink {
    pub fn new(display: String) -> Arc<Self> {
        eprintln!("[input-router] x11warp sink display={display}");
        let shared = Arc::new(Shared {
            pending: Mutex::new(Pending {
                latest_move: None,
                ordered: VecDeque::with_capacity(ORDERED_CAPACITY),
                cur_x: 0,
                cur_y: 0,
            }),
            cv: Condvar::new(),
            health: AtomicU8::new(HEALTH_STARTING),
            counters: Counters::default(),
            closed: AtomicBool::new(false),
            edge_pending: AtomicU64::new(0),
            settled: tokio::sync::Notify::new(),
            armed: AtomicBool::new(false),
            readback: AtomicU8::new(READBACK_NONE),
            last_err: Mutex::new(String::new()),
            repair_marker: repair_marker_from_env(),
        });
        if golden_state(shared.repair_marker.as_deref()) == "REPAIRED-AT-RUNTIME" {
            eprintln!(
                "[x11warp] golden-state=REPAIRED-AT-RUNTIME: the checkpoint does NOT carry the \
                 X access state and the launcher patched it in. The pointer works, which is \
                 exactly why this is easy to leave forever -- recapture the checkpoint."
            );
        }
        let _ = GATE.set(shared.clone());
        let worker_shared = shared.clone();
        std::thread::spawn(move || worker(display, worker_shared));
        Arc::new(Self { shared })
    }

    /// Blocking take, for ordered events only — a dropped move is replaced by
    /// the next one; a dropped edge restate is a click at the wrong place.
    fn lock_pending_ordered(&self) -> std::sync::MutexGuard<'_, Pending> {
        self.shared
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn lock_pending(&self) -> Result<std::sync::MutexGuard<'_, Pending>, Reject> {
        match self.shared.pending.try_lock() {
            Ok(p) => Ok(p),
            Err(TryLockError::WouldBlock) => {
                self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
                Err(Reject::Busy)
            }
            Err(TryLockError::Poisoned(_)) => {
                self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
                Err(Reject::BackendDown)
            }
        }
    }
}

impl RealtimeInputSink for X11WarpSink {
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject> {
        let mut p = if event.ordered {
            self.lock_pending_ordered()
        } else {
            self.lock_pending()?
        };
        // Clamp to the surface AND to X's i16 coordinate space.
        let tx = event
            .x
            .min(event.width.saturating_sub(1))
            .min(i16::MAX as u32);
        let ty = event
            .y
            .min(event.height.saturating_sub(1))
            .min(i16::MAX as u32);
        if trace_on() {
            eprintln!(
                "[x11warp-trace] rx seq={} raw={},{} clamped={},{} ordered={}",
                event.seq, event.x, event.y, tx, ty, event.ordered
            );
        }
        p.cur_x = tx;
        p.cur_y = ty;
        if self.health() != SinkHealth::Healthy {
            self.shared
                .counters
                .backend_down
                .fetch_add(1, Ordering::Relaxed);
            return Err(Reject::BackendDown);
        }

        if !event.ordered {
            if p.latest_move.replace((tx, ty)).is_some() {
                self.shared
                    .counters
                    .coalesced
                    .fetch_add(1, Ordering::Relaxed);
            }
        } else {
            let needed = usize::from(p.latest_move.is_some()) + 1;
            if p.ordered.len() + needed > ORDERED_CAPACITY {
                self.shared
                    .counters
                    .overflow
                    .fetch_add(1, Ordering::Relaxed);
                self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
                return Err(Reject::Overflow);
            }
            // Flush the pending move ahead, then THIS event's target as the
            // verified restate the edge behind it will wait on.
            if let Some((mx, my)) = p.latest_move.take() {
                p.ordered.push_back(Warp {
                    x: mx,
                    y: my,
                    verify: false,
                });
            }
            p.ordered.push_back(Warp {
                x: tx,
                y: ty,
                verify: true,
            });
            self.shared.edge_pending.fetch_add(1, Ordering::AcqRel);
        }
        self.shared
            .counters
            .accepted
            .fetch_add(1, Ordering::Relaxed);
        drop(p);
        self.shared.cv.notify_one();
        Ok(AcceptedSeq(event.seq))
    }

    fn health(&self) -> SinkHealth {
        match self.shared.health.load(Ordering::Acquire) {
            HEALTH_HEALTHY => SinkHealth::Healthy,
            HEALTH_DOWN => SinkHealth::Down,
            _ => SinkHealth::Starting,
        }
    }

    fn backend_name(&self) -> &'static str {
        "x11warp"
    }
}

impl Drop for X11WarpSink {
    fn drop(&mut self) {
        self.shared.closed.store(true, Ordering::Release);
        self.shared.cv.notify_all();
        self.shared.settled.notify_waiters();
    }
}

/// input.rs button-edge hold for `SH_INPUT_BACKEND=x11warp`: offer the carried
/// position (and edge, which the sink IGNORES — no XTEST to inject it with) as
/// ONE ordered record, then hold the D-Bus PS/2 edge until the sink's
/// QueryPointer readback confirms the warp landed AND the exclusion window is
/// armed — bounded by `EDGE_HOLD_MAX`, so a dead X server delays a click but
/// never eats one. The caller MUST call `edge_done()` after the injection
/// returns (input.rs does, unconditionally); a caller that dies in between is
/// backstopped by the counted `arm-expired` expiry.
pub async fn ordered_warp_then_hold(
    router: Option<&Arc<crate::realtime_input::InputRouter>>,
    button: u8,
    down: bool,
    at: Option<(u32, u32, u32, u32)>,
) {
    let Some(router) = router else { return };
    if let Err(e) = router.try_button_at(button, down, at) {
        // BackendDown/Overflow: nothing was enqueued, nothing to wait for —
        // the edge falls straight through to PS/2, loudly.
        eprintln!("[x11warp] ordered warp REJECTED btn={button} down={down} err={e:?}");
        return;
    }
    if let Some(shared) = GATE.get() {
        wait_settled_on(shared, EDGE_HOLD_MAX).await;
    }
}

/// input.rs calls this AFTER the D-Bus edge injection returns (there is no
/// error branch that skips it): ends the armed exclusion window and lets the
/// worker resume applying motion. No-op for every other backend (the GATE is
/// only set when an x11warp sink exists) and when nothing is armed.
pub fn edge_done() {
    if let Some(shared) = GATE.get() {
        edge_done_on(shared);
    }
}

fn edge_done_on(shared: &Shared) {
    if shared.armed.swap(false, Ordering::AcqRel) {
        // Take the lock briefly so the notify cannot slip into the window
        // between the worker's armed-check and its cv wait.
        let _guard = shared
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        shared.cv.notify_all();
    }
}

/// Wait (bounded) until no ordered target is pending confirmation.
async fn wait_settled_on(shared: &Shared, timeout: Duration) {
    let deadline = tokio::time::Instant::now() + timeout;
    while shared.edge_pending.load(Ordering::Acquire) > 0 {
        let notified = shared.settled.notified();
        if shared.edge_pending.load(Ordering::Acquire) == 0 {
            return;
        }
        if tokio::time::timeout_at(deadline, notified).await.is_err() {
            shared.counters.hold_timeout.fetch_add(1, Ordering::Relaxed);
            return;
        }
    }
}

type X11Conn = x11rb::rust_connection::RustConnection;

/// Connect and PROVE the round trip (one QueryPointer) before anything is
/// allowed to believe in this server.
fn connect_x11(display: &str) -> anyhow::Result<(X11Conn, u32)> {
    use anyhow::Context as _;
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::ConnectionExt as _;
    let (conn, screen) = x11rb::connect(Some(display)).context("connect")?;
    let root = conn.setup().roots[screen].root;
    conn.query_pointer(root)
        .context("QueryPointer probe")?
        .reply()
        .context("QueryPointer probe reply")?;
    Ok((conn, root))
}

fn warp_to(conn: &X11Conn, root: u32, x: u32, y: u32) -> anyhow::Result<()> {
    use anyhow::Context as _;
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::ConnectionExt as _;
    conn.warp_pointer(x11rb::NONE, root, 0, 0, 0, 0, x as i16, y as i16)
        .context("WarpPointer")?;
    conn.flush().context("flush")?;
    Ok(())
}

fn worker(display: String, shared: Arc<Shared>) {
    let mut backoff_ms = 50u64;
    while !shared.closed.load(Ordering::Acquire) {
        shared.health.store(HEALTH_STARTING, Ordering::Release);
        match connect_x11(&display) {
            Ok((conn, root)) => {
                eprintln!("[x11warp] connected, round trip proven display={display} root={root}");
                shared
                    .last_err
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .clear();
                backoff_ms = 50;
                if let Err(e) = run_connection(&shared, &conn, root) {
                    shared.set_err(&format!("connection lost: {e:#}; reconnecting"));
                }
            }
            Err(e) => {
                shared.set_err(&format!(
                    "connect {display} failed: {e:#}; retry {backoff_ms}ms"
                ));
            }
        }
        // Down between connections; disarm, drop the queues and release any
        // held edges as GIVE-UPS — never as successes.
        shared.health.store(HEALTH_DOWN, Ordering::Release);
        shared.armed.store(false, Ordering::Release);
        {
            let mut p = shared
                .pending
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            p.ordered.clear();
            p.latest_move = None;
        }
        let held = shared.edge_pending.swap(0, Ordering::AcqRel);
        if held > 0 {
            shared.counters.gaveup.fetch_add(held, Ordering::Relaxed);
            shared
                .readback
                .store(READBACK_UNCONFIRMED, Ordering::Release);
        }
        shared.settled.notify_waiters();
        let guard = shared
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = shared
            .cv
            .wait_timeout(guard, Duration::from_millis(backoff_ms));
        backoff_ms = (backoff_ms * 2).min(1000);
    }
}

fn run_connection(shared: &Shared, conn: &X11Conn, root: u32) -> anyhow::Result<()> {
    use x11rb::protocol::xproto::ConnectionExt as _;
    // Restate the current browser-truth target once, then go Healthy.
    let (cx, cy) = {
        let p = shared
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        (p.cur_x, p.cur_y)
    };
    warp_to(conn, root, cx, cy)?;
    shared.health.store(HEALTH_HEALTHY, Ordering::Release);
    let mut last_stat = Instant::now();
    // When the worker itself armed the window (set on confirm, below).
    let mut armed_since: Option<Instant> = None;

    loop {
        if last_stat.elapsed() >= Duration::from_secs(10) {
            last_stat = Instant::now();
            eprintln!("[input-router] x11warp {}", shared.stat_line());
        }
        if shared.closed.load(Ordering::Acquire) {
            return Ok(());
        }
        // ARMED: apply nothing until edge_done() or the counted expiry.
        if shared.armed.load(Ordering::Acquire) {
            let since = *armed_since.get_or_insert_with(Instant::now);
            if shared.expire_arm_if_due(since) {
                armed_since = None;
                continue;
            }
            let remaining = EDGE_HOLD_MAX
                .saturating_sub(since.elapsed())
                .max(Duration::from_millis(1));
            let guard = shared
                .pending
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let _ = shared.cv.wait_timeout(guard, remaining);
            continue;
        }
        armed_since = None;

        let Some(w) = shared.take_next() else {
            let guard = shared
                .pending
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let _ = shared.cv.wait_timeout(guard, Duration::from_secs(1));
            continue;
        };

        let started = Instant::now();
        warp_to(conn, root, w.x, w.y)?;
        shared.counters.warps.fetch_add(1, Ordering::Relaxed);
        if trace_on() {
            eprintln!("[x11warp-trace] warp {},{} verify={}", w.x, w.y, w.verify);
        }
        if !w.verify {
            continue;
        }
        // VERIFIED RESTATE: the edge held behind this target is released only
        // once the guest's own server reports the pointer AT the target — and
        // the exclusion window is armed FIRST, so no motion can slip between
        // the confirmation and the injection.
        let mut ok = false;
        for _try in 0..VERIFY_TRIES {
            let r = conn.query_pointer(root)?.reply()?;
            if (r.root_x as i32, r.root_y as i32) == (w.x as i32, w.y as i32) {
                ok = true;
                break;
            }
            shared.counters.retries.fetch_add(1, Ordering::Relaxed);
            if trace_on() {
                eprintln!(
                    "[x11warp-trace] readback {},{} != target {},{}; re-warp",
                    r.root_x, r.root_y, w.x, w.y
                );
            }
            warp_to(conn, root, w.x, w.y)?;
            shared.counters.warps.fetch_add(1, Ordering::Relaxed);
        }
        if ok {
            shared.counters.confirmed.fetch_add(1, Ordering::Relaxed);
            shared.armed.store(true, Ordering::Release);
            armed_since = Some(Instant::now());
            shared.release_edge(READBACK_CONFIRMED);
            crate::input_telemetry::record_inject(
                "x11warp",
                1,
                started.elapsed().as_micros() as u64,
                None,
            );
        } else {
            // Do NOT claim success: count the give-up, release the held edge
            // as one, and go unhealthy — the reconnect must re-prove the
            // round trip before this sink is believed again.
            shared.counters.gaveup.fetch_add(1, Ordering::Relaxed);
            shared.release_edge(READBACK_UNCONFIRMED);
            anyhow::bail!(
                "readback disagrees after {VERIFY_TRIES} tries: target {},{}",
                w.x,
                w.y
            );
        }
    }
}

#[cfg(test)]
#[path = "x11_warp_tests.rs"]
mod tests;
