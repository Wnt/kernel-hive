// Relative-pointer bridge: auto re-home + paced sends.
//
// The abs->rel homing bridge in `input.rs` (FIX 2 / FIX 4) tracks the guest
// cursor by DEAD RECKONING: it pins the guest cursor into the 0,0 corner once,
// then sends every absolute client target as a delta from where it believes
// the cursor is. Two things break that belief, and this module owns both fixes
// (docs/lab/research/rel-pointer-rehome-and-rate-cap.md):
//
//   * something moves the guest cursor behind the model's back — a `loadvm`
//     reset teleports it to the checkpoint's position, an idle-pause resume
//     lands mid-motion, the browser pointer re-enters far away after a Cmd-Tab.
//     Until now only the visitor's manual "chase it into a corner" re-synced
//     model and guest (an edge clamp is the one event where both agree by
//     construction). RE-HOME makes the daemon do that itself: `RelHomeOn`
//     lists the triggers, each of which just raises `home_pending`; the next
//     motion (or, for `idle`, the pacer while the pointer rests) runs the
//     existing pin -> settle -> walk sequence.
//   * a big jump is pushed into the guest's PS/2 / ADB accumulator faster than
//     the guest drains it, so counts are lost while the model advances to the
//     target regardless. PACING (SH_REL_PACED=1) turns motion into ONE bounded
//     step per pace tick across ALL samples of a session; anything beyond the
//     step stays PENDING against the newest target ("latest target wins": the
//     cursor lags and converges, never overshoots or rubber-bands). `lx/ly` in
//     the model are what was SENT, never the target — the same rule the aux
//     quantum introduced.
//
// Defaults keep every station byte-identical: `session` (the once-per-session
// seed, i.e. today's behaviour) is the only trigger on, and pacing is off.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::{Mutex, Notify};

use crate::capture::Capture;
use crate::config::Config;
use crate::input::{
    home_pin, rel_max_step, rel_motion, rel_quantum, rel_step_pace_ms, MouseState, SharedMouse,
    HOME_SETTLE_MS,
};

/// Daemon-wide "the guest's cursor was replaced" counters. Bumped by SIGUSR2
/// (`scripts/serve/reset-tile.sh` after a `loadvm`) and by an idle-pause
/// `cont` under a live session; every session's model remembers the value it
/// last homed against and re-homes when it moved.
pub static RESET_EPOCH: AtomicU64 = AtomicU64::new(0);
pub static RESUME_EPOCH: AtomicU64 = AtomicU64::new(0);

pub fn note_guest_reset() {
    RESET_EPOCH.fetch_add(1, Ordering::Relaxed);
}
pub fn note_guest_resumed() {
    RESUME_EPOCH.fetch_add(1, Ordering::Relaxed);
}

/// Install the SIGUSR2 "guest state replaced" listener. tokio fans a signal
/// out to every registered stream, so this coexists with gallery-hid's own
/// SIGUSR1/2 restore handshake on the one station that has it.
pub fn spawn_reset_signal() {
    tokio::spawn(async {
        use tokio::signal::unix::{signal, SignalKind};
        let Ok(mut s) = signal(SignalKind::user_defined2()) else {
            eprintln!("[rel-bridge] could not install SIGUSR2 re-home listener");
            return;
        };
        while s.recv().await.is_some() {
            note_guest_reset();
            eprintln!("[rel-bridge] SIGUSR2: guest state replaced -> re-home on next motion");
        }
    });
}

/// Which screen edges the client target sits on (x then y): -1 = low edge,
/// +1 = high edge, 0 = interior. Guests whose cursor cannot reach the last
/// pixel (some X servers clamp at W-2) still trip the high edge at W-2.
pub fn edge_of(x: u32, y: u32, w: u32, h: u32) -> (i8, i8) {
    let ex = if x == 0 {
        -1
    } else if x + 2 >= w.max(2) {
        1
    } else {
        0
    };
    let ey = if y == 0 {
        -1
    } else if y + 2 >= h.max(2) {
        1
    } else {
        0
    };
    (ex, ey)
}

/// One bounded, quantized step from `sent` toward `target` on one axis.
/// `quantum <= 1` is plain clamping; with a quantum the step is a multiple of
/// it, rounded toward zero (the sub-quantum remainder stays pending).
pub fn axis_step(sent: i32, target: i32, max_step: i32, quantum: i32) -> i32 {
    let d = (target - sent).clamp(-max_step.max(1), max_step.max(1));
    if quantum <= 1 {
        d
    } else {
        d - d % quantum
    }
}

/// The pending-motion model of one session: `sent` is where the guest cursor
/// IS (as far as the daemon knows), `target` where the client wants it. Pure,
/// unit-tested; the async pacer below drives it.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct RelModel {
    pub sent: (i32, i32),
    pub target: (i32, i32),
    /// A target has been set at least once (nothing to walk to before that).
    pub have_target: bool,
    /// The next motion must pin -> settle -> walk (re-home). Set by every
    /// trigger; the once-per-session seed is `!homed`.
    pub home_pending: bool,
    pub homed: bool,
    /// Edge the CURRENT target sits on (edge trigger) and whether its
    /// over-clamp has been sent. Re-armed whenever the edge changes.
    pub edge: (i8, i8),
    pub edge_done: (bool, bool),
}

impl RelModel {
    /// Aim at a new target (guest delta units). Only the newest target ever
    /// matters — pending motion is re-aimed, never queued.
    pub fn set_target(&mut self, tx: i32, ty: i32, edge: (i8, i8)) {
        self.target = (tx, ty);
        self.have_target = true;
        if edge.0 != self.edge.0 {
            self.edge_done.0 = false;
        }
        if edge.1 != self.edge.1 {
            self.edge_done.1 = false;
        }
        self.edge = edge;
    }
    pub fn needs_home(&self) -> bool {
        self.home_pending || !self.homed
    }
    /// The pin landed: the guest cursor is at the origin, by construction.
    pub fn homed_at_origin(&mut self) {
        self.sent = (0, 0);
        self.homed = true;
        self.home_pending = false;
        self.edge_done = (false, false);
    }
    /// Next bounded step toward the target, or (0,0) when settled.
    pub fn next_step(&self, max_step: i32, quantum: i32) -> (i32, i32) {
        (
            axis_step(self.sent.0, self.target.0, max_step, quantum),
            axis_step(self.sent.1, self.target.1, max_step, quantum),
        )
    }
    pub fn commit(&mut self, dx: i32, dy: i32) {
        self.sent.0 += dx;
        self.sent.1 += dy;
    }
    pub fn settled(&self, quantum: i32) -> bool {
        self.next_step(i32::MAX / 4, quantum) == (0, 0)
    }
    /// The whole distance still owed (for telemetry).
    pub fn pending(&self) -> (i32, i32) {
        (self.target.0 - self.sent.0, self.target.1 - self.sent.1)
    }
    /// The edge over-clamp still owed for the current (settled) target, per
    /// axis, as the SIGN of the pin to send. Marks them sent.
    pub fn take_edge_pins(&mut self) -> (i8, i8) {
        let mut out = (0i8, 0i8);
        if self.edge.0 != 0 && !self.edge_done.0 {
            self.edge_done.0 = true;
            out.0 = self.edge.0;
        }
        if self.edge.1 != 0 && !self.edge_done.1 {
            self.edge_done.1 = true;
            out.1 = self.edge.1;
        }
        out
    }
}

/// Wake-ups shared between the input handlers and the pacer task.
#[derive(Default)]
pub struct PacerSignals {
    /// New target / re-home request: the pacer has work.
    pub wake: Notify,
    /// The pacer reached the target (or has nothing to do): buttons that carry
    /// a position wait on this so a press never lands mid-walk.
    pub settled: Notify,
}

pub type SharedSignals = Arc<PacerSignals>;

/// SH_REL_HOME_IDLE_S: seconds of no pointer input (and no held button)
/// after which the `idle` trigger re-homes (the guest cursor visibly flicks to
/// the corner and back, once per rest). Default 15.
pub fn idle_secs() -> u64 {
    static V: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
    *V.get_or_init(|| {
        std::env::var("SH_REL_HOME_IDLE_S")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(15u64)
            .max(1)
    })
}

/// Fold the daemon-wide guest epochs (reset via SIGUSR2, resume via the idle
/// pauser) into this session's re-home flag, per the station's trigger list.
pub(crate) fn note_guest_epochs(st: &mut MouseState, cfg: &Config) {
    let reset = RESET_EPOCH.load(Ordering::Relaxed);
    let resume = RESUME_EPOCH.load(Ordering::Relaxed);
    if reset != st.reset_epoch {
        st.reset_epoch = reset;
        if cfg.rel_home_on.reset {
            st.rel.home_pending = true;
        }
    }
    if resume != st.resume_epoch {
        st.resume_epoch = resume;
        if cfg.rel_home_on.resume {
            st.rel.home_pending = true;
        }
    }
}

/// A client re-home HINT (type 7, no payload): the SPA sends it when the tab
/// becomes visible again, the window regains focus or the pointer re-enters
/// the surface — the Cmd-Tab case, where the browser pointer comes back far
/// from where it left and the guest may have moved its own cursor meanwhile.
pub(crate) fn focus_hint(st: &mut MouseState, cfg: &Config) {
    if cfg.rel_home_on.focus && cfg.input_backend == crate::config::InputBackend::DbusRel {
        st.rel.home_pending = true;
    }
}

/// The homing corner-pin: a deliberate over-clamp into the top-left corner (a
/// merge/clamp is the goal, not a truncation hazard) that establishes a known
/// 0,0 origin, then `HOME_SETTLE_MS` so pin and walk are OBSERVED as two
/// movements. The model is set to the origin; the walk to the target is the
/// caller's next step, never sent from inside the same handler: sending it
/// here is what broke the Xerox Star station — pointer MOVES ride unreliable
/// datagrams and were handled concurrently, so the pin, the seed walk and the
/// next few deltas raced through the PS/2 queue and the guest observed only
/// their merged, hugely negative sum. The cursor parked in the corner while the
/// model believed it was at the target — a fixed offset for the rest of the
/// session, i.e. exactly what the pin exists to prevent. Held under the mouse
/// lock by every caller so no sample can interleave.
pub(crate) async fn pin_home(cap: &Capture, cfg: &Config, st: &mut MouseState) {
    let pin = home_pin(cfg.cursor_scale);
    rel_motion(cap, -pin, -pin).await;
    tokio::time::sleep(Duration::from_millis(HOME_SETTLE_MS)).await;
    st.rel.homed_at_origin();
    if crate::input_telemetry::enabled() {
        eprintln!(
            "[input-tel rel] rehome pin={pin} target=({},{})",
            st.rel.target.0, st.rel.target.1
        );
    }
}

/// Block until the session's pacer has reached its target (or `max` elapsed).
/// Polling with a short notified() timeout closes the check-then-wait race
/// without a permit-carrying primitive; the poll interval is one pace tick.
pub async fn wait_settled(mouse: &SharedMouse, max: Duration) {
    let deadline = Instant::now() + max;
    loop {
        let (sig, done) = {
            let st = mouse.lock().await;
            (
                st.sig.clone(),
                !st.rel.have_target || (!st.rel.needs_home() && st.rel.settled(rel_quantum())),
            )
        };
        if done || Instant::now() >= deadline {
            return;
        }
        let _ = tokio::time::timeout(Duration::from_millis(20), sig.settled.notified()).await;
    }
}

/// The per-session PACED SENDER (SH_REL_PACED=1). Owns every RelMotion of the
/// bridge: pin -> settle -> walk on a re-home, then one bounded step per pace
/// tick toward the newest target, edge over-clamps once the target is reached,
/// and the `idle` trigger while the pointer rests. Spawned by the transport
/// next to the move coalescer; ends when the session's MouseState is dropped.
pub async fn run_pacer(cap: Capture, cfg: Arc<Config>, mouse: std::sync::Weak<Mutex<MouseState>>) {
    let sig = match mouse.upgrade() {
        Some(m) => m.lock().await.sig.clone(),
        None => return,
    };
    let (max_step, quantum) = (rel_max_step(), rel_quantum());
    let pace = Duration::from_millis(rel_step_pace_ms());
    let idle = Duration::from_secs(idle_secs());
    let mut last_send: Option<Instant> = None;
    loop {
        let Some(m) = mouse.upgrade() else { return };
        // The idle clock only runs while a homed session rests with no button
        // held; it fires once per rest (`idle_homed`).
        let idle_at = {
            let st = m.lock().await;
            (cfg.rel_home_on.idle
                && st.rel.have_target
                && st.rel.homed
                && st.buttons == 0
                && !st.idle_homed)
                .then_some(())
                .and(st.last_sample)
                .map(|t| t + idle)
        };
        drop(m);
        match idle_at {
            Some(at) => tokio::select! {
                _ = sig.wake.notified() => {}
                _ = tokio::time::sleep_until(at.into()) => {
                    if let Some(m) = mouse.upgrade() {
                        let mut st = m.lock().await;
                        if st.buttons == 0 && !st.idle_homed && st.last_sample.is_some_and(|t| t.elapsed() >= idle) {
                            st.idle_homed = true;
                            st.rel.home_pending = true;
                            if crate::input_telemetry::enabled() {
                                eprintln!("[input-tel rel] idle re-home");
                            }
                        }
                    }
                }
            },
            None => sig.wake.notified().await,
        }
        // Drain: steps until settled. The mouse lock is held across a pin +
        // settle (as the legacy path always did) so a sample cannot interleave
        // with the homing sequence — the Xerox Star lesson.
        loop {
            let Some(m) = mouse.upgrade() else { return };
            let step = {
                let mut st = m.lock().await;
                if !st.rel.have_target {
                    break;
                }
                if st.rel.needs_home() {
                    pin_home(&cap, &cfg, &mut st).await;
                    last_send = Some(Instant::now());
                }
                let step = st.rel.next_step(max_step, quantum);
                if step == (0, 0) {
                    let pins = st.rel.take_edge_pins();
                    if pins != (0, 0) {
                        let pin = home_pin(cfg.cursor_scale);
                        rel_motion(&cap, i32::from(pins.0) * pin, i32::from(pins.1) * pin).await;
                    }
                    sig.settled.notify_waiters();
                    break;
                }
                // ONE step per pace tick, across all samples: never faster than
                // the guest drains its accumulator. Ordinary motion (one step per
                // sample, samples further apart than the pace) never waits here.
                if let Some(t) = last_send {
                    let due = t + pace;
                    let now = Instant::now();
                    if due > now {
                        drop(st);
                        tokio::time::sleep(due - now).await;
                        continue;
                    }
                }
                st.rel.commit(step.0, step.1);
                last_send = Some(Instant::now());
                if crate::input_telemetry::level() >= 2 {
                    let (px, py) = st.rel.pending();
                    eprintln!(
                        "[input-tel rel] cseq={} step=({},{}) sent=({},{}) pending=({},{})",
                        st.applied_cseq(),
                        step.0,
                        step.1,
                        st.rel.sent.0,
                        st.rel.sent.1,
                        px,
                        py
                    );
                }
                step
            };
            rel_motion(&cap, step.0, step.1).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::RelHomeOn;

    #[test]
    fn triggers_parse_and_default_off() {
        assert_eq!(RelHomeOn::parse(""), RelHomeOn::default());
        assert!(!RelHomeOn::parse("session").any());
        let on = RelHomeOn::parse("session, reset,FOCUS ,bogus");
        assert!(on.reset && on.focus && !on.idle && !on.edge && !on.resume);
        assert!(RelHomeOn::parse("all").idle);
    }

    #[test]
    fn edges_are_detected_including_the_w_minus_2_clamp() {
        assert_eq!(edge_of(0, 5, 640, 480), (-1, 0));
        assert_eq!(edge_of(639, 5, 640, 480), (1, 0));
        assert_eq!(edge_of(638, 479, 640, 480), (1, 1));
        assert_eq!(edge_of(637, 0, 640, 480), (0, -1));
        assert_eq!(edge_of(300, 200, 640, 480), (0, 0));
    }

    #[test]
    fn a_step_is_bounded_and_quantized_toward_zero() {
        assert_eq!(axis_step(0, 1000, 63, 0), 63);
        assert_eq!(axis_step(0, -1000, 63, 0), -63);
        assert_eq!(axis_step(10, 40, 63, 0), 30);
        assert_eq!(axis_step(0, 30, 32, 4), 28);
        assert_eq!(axis_step(0, -30, 32, 4), -28);
        assert_eq!(axis_step(0, 3, 32, 4), 0);
    }

    #[test]
    fn pending_model_converges_monotonically_and_latest_target_wins() {
        let mut m = RelModel::default();
        m.homed_at_origin();
        m.set_target(200, -100, (0, 0));
        let mut steps = 0;
        while !m.settled(0) {
            let (dx, dy) = m.next_step(63, 0);
            assert!(dx.abs() <= 63 && dy.abs() <= 63);
            m.commit(dx, dy);
            steps += 1;
            if steps == 2 {
                // Re-aim mid-walk: no waypoint at the old target is ever visited.
                m.set_target(50, 50, (0, 0));
            }
        }
        assert_eq!(m.sent, (50, 50));
        assert_eq!(m.pending(), (0, 0));
        assert!(steps <= 4 + 2);
    }

    #[test]
    fn quantized_model_leaves_the_remainder_pending() {
        let mut m = RelModel::default();
        m.homed_at_origin();
        m.set_target(30, 0, (0, 0));
        m.commit(m.next_step(32, 4).0, 0);
        assert_eq!(m.sent, (28, 0));
        assert!(m.settled(4));
        assert_eq!(m.pending(), (2, 0));
        m.set_target(34, 0, (0, 0));
        assert_eq!(m.next_step(32, 4), (4, 0));
    }

    #[test]
    fn rehome_flags_and_edge_pins_fire_once_per_edge() {
        let mut m = RelModel::default();
        assert!(m.needs_home());
        m.homed_at_origin();
        assert!(!m.needs_home());
        m.home_pending = true;
        assert!(m.needs_home());
        m.homed_at_origin();
        m.set_target(0, 100, (-1, 0));
        assert_eq!(m.take_edge_pins(), (-1, 0));
        assert_eq!(m.take_edge_pins(), (0, 0));
        m.set_target(0, 120, (-1, 0));
        assert_eq!(m.take_edge_pins(), (0, 0));
        m.set_target(5, 120, (0, 0));
        m.set_target(0, 0, (-1, -1));
        assert_eq!(m.take_edge_pins(), (-1, -1));
    }
}
