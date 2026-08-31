// Idle auto-pause: pause the guest when NO WebTransport session has been
// connected for a grace period, and resume it the moment a new session is
// accepted — before priming/keyframe work, so the joiner sees the live screen
// sub-second.
//
// TWO PAUSE MECHANISMS, one reconciler. A QEMU station pauses its vCPUs with QMP
// `stop`/`cont`. The x11/shm emulator stations (irix: MAME on the bare-metal CPU)
// have no QMP socket at all, so there the equivalent is SIGSTOP/SIGCONT on the
// emulator process named by SH_IDLE_PAUSE_PIDFILE. Everything above the
// `Freezer` — the session lease, the grace clock, the reconciler and its
// self-heal — is shared, because the policy is identical and only the verb
// differs. Whichever mechanism is in play, a paused guest costs ~0 CPU and its
// RAM/state is untouched.
//
// WHY: measured 2026-07-12, unwatched guests were labhost's dominant idle load
// (~43% of the host: the emulator-bridge kiosks run linapple/VICE full-speed
// 24/7, sailfishos/templeos/kolibrios etc. churn at 6-56% of a core each). A
// paused guest costs ~0 CPU; `cont` is sub-second; and pause != loadvm — guest
// RAM/state is untouched, so cold-boot-only stations (serenityos/toaruos) are safe.
// The user-facing UX is intentional: a station "wakes up" live in front of the
// visitor (guest clocks pause while paused; clock-set is a load-time concern).
//
// QMP DISCIPLINE: streamhost does NOT hold the QMP socket (capture::connect
// drops it after the dbus-display handshake precisely so labctl/cdrv.py can
// use it). Every stop/cont here is a fresh short-lived QMP connection with 2 s
// timeouts — the same transient pattern labhost tooling uses. If another QMP
// client (cdrv.py) holds the socket at that instant, the command fails fast
// and the reconciler retries on its next tick.
//
// ROBUSTNESS INVARIANTS (reconciler, 5 s tick):
//   * A guest is NEVER left paused while a session is active: session-start
//     issues `cont` (idempotent) unconditionally, and the reconciler re-issues
//     it whenever sessions > 0 but the pause belief is still set (covers a
//     `cont` that failed on a transiently busy QMP socket).
//   * External `cont`s self-heal: labctl auto-resumes a paused guest before
//     driving it (screendump/exec would hang on paused vCPUs) and does not
//     tell the daemon. The reconciler re-asserts a believed pause every
//     HEAL_EVERY ticks (60 s), so a labctl-driven guest re-freezes within
//     <= grace + 60 s of the last visitor, instead of running forever.
//   * Zero sessions at daemon start counts as idle: a station nobody ever visits
//     pauses one grace period after boot (the visitor then watches it resume —
//     or finish booting — live).
//
// WARMUP (SH_IDLE_PAUSE_WARMUP_SECS, default 0 = off): the FIRST pause can be
// withheld for a while after daemon start. A station whose own health machinery
// needs the guest RUNNING to vet it is otherwise never vetted — irix's
// livewatch waits 600 s before its first pointer probe, and that probe is the
// only thing that clears the instant-ready budget, so a station paused at 60 s
// and never visited would ratchet that budget up until every launch fell back
// to the 390 s cold boot. Resumes are never withheld; only the pause waits.
//
// SIGNAL DISCIPLINE (the pidfile mechanism): the pidfile is re-read on EVERY
// stop/cont, so a watchdog that relaunched the emulator under us is followed
// rather than signalled at a dead pid, and SH_IDLE_PAUSE_PROC_MATCH must still
// appear in that pid's cmdline — a stale pidfile whose pid the kernel recycled
// must never SIGSTOP an unrelated process. Both signals are idempotent, so the
// reconciler's re-assert and the unconditional cont on connect stay free.
//
// INPUT IS A WAKE, AND THE WAKE IS VERIFIED (2026-08-24). A paused guest that
// is handed an input event does not react, and every plane that could hand it
// one used to say nothing about that: QEMU's own monitor acks `sendkey` on a
// guest whose vCPUs are stopped, so `qmp-type.py` typed a whole line into the
// void and then screendumped the unchanged screen as its "proof". Agents read
// that as a wedged guest and went debugging the emulator, repeatedly, during
// the 2026-08-23 wave. An interface that accepts what it discards manufactures
// false evidence, which in a lab whose first rule is "the framebuffer is the
// only proof" is worse than failing.
//
// The rule is now the one MAME's ctlsock already keeps: an ack means the event
// was delivered TO A RUNNING GUEST. Three parts enforce it, and none of them
// queues — a pointer move replayed seconds later lands at a coordinate the
// client has long since moved on from, which is the same false evidence one
// layer up:
//
//   1. `wake_for_input()` — the daemon's own input funnel (input::handle) calls
//      it before injecting. It is an atomic load and returns instantly unless
//      we believe we froze the guest; if we did, it CONTs and only then lets the
//      event through. This closes the window where the `cont` in
//      `session_started` failed on a busy QMP socket and the next ~5 s of a
//      visitor's clicks went into a stopped guest with nothing said.
//   2. If that wake fails, the record is dropped LOUDLY — one `[idle] INPUT
//      DROPPED` line naming the pause state and the running total — instead of
//      silently. The reconciler retries `cont` every tick while a session is
//      live, so this self-heals within ~5 s.
//   3. The WAKE LEASE (below) stops the reconciler re-freezing the guest under
//      an out-of-band driver that is still typing.
//
// WAKE LEASE (SH_WAKE_LEASE, default /run/streamhost/wake/<station>.lease):
// streamhost is not the only thing that drives a guest — labctl, qmp-type.py
// and the install-phase tooling inject over QMP with no browser session, so
// `sessions` is 0 and the reconciler's HEAL_EVERY re-assert (60 s) undoes their
// `cont` mid-sequence. That race is the whole reason for the folklore agents
// were passing around ("send `cont` and your input back-to-back on ONE
// connection") — which shrinks the window rather than closing it. A driver now
// touches the lease file for as long as it is driving; a lease whose mtime is
// within LEASE_TTL both withholds the pause and resumes a guest we already
// paused. It is mtime-based on purpose: a driver that dies leaves a lease that
// expires on its own, so the worst case is one station running LEASE_TTL longer
// than it had to, never a station that never pauses again.
//
// Config: SH_IDLE_PAUSE_SECS / --idle-pause-secs (default 60; 0 = disabled;
// per-station override via station.env), SH_IDLE_PAUSE_PIDFILE +
// SH_IDLE_PAUSE_PROC_MATCH (non-QEMU stations). See docs/IDLE-PAUSE.md.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant, SystemTime};

/// How long a driver's touch of the wake-lease file keeps the guest awake.
///
/// Sized to outlast the reconciler's own re-assert period (HEAL_EVERY = 60 s)
/// with margin, so a driver that refreshes its lease on any sane interval is
/// never re-frozen mid-sequence; and short enough that a lease abandoned by a
/// killed driver costs one station a single extra pause cycle.
const LEASE_TTL: Duration = Duration::from_secs(90);

/// DAEMON-WIDE pause belief, readable without a lock.
///
/// `IdlePauser.st.paused` is the authority; this mirrors it so the input funnel
/// can ask "is the guest frozen?" on every record for the price of one relaxed
/// load. Kept in sync by `set_paused` — never written anywhere else.
static PAUSE_BELIEF: AtomicBool = AtomicBool::new(false);

/// The process's pauser, for the free functions below. `IdlePauser::new`
/// installs it; a station with idle-pause disabled leaves it empty and every
/// wake becomes a no-op.
static PAUSER: OnceLock<Arc<IdlePauser>> = OnceLock::new();

/// Input records dropped because the guest was frozen and would not wake.
static INPUT_DROPPED: AtomicU64 = AtomicU64::new(0);

/// INPUT IS A WAKE. Call before injecting a record; `true` means "deliver it".
///
/// The fast path is one relaxed atomic load: a running guest — every guest with
/// a live visitor, essentially always — pays nothing. Only when we believe we
/// froze the guest does this take the pauser's lock and `cont` first, so the
/// event lands on a RUNNING guest or not at all.
///
/// Returning `false` is the honest half. The record is NOT queued for later:
/// a click replayed after the wake would land at a coordinate the client has
/// already moved on from, and a key replayed into a guest that has since
/// changed focus is worse than a key that never arrived. It is dropped, and
/// said out loud — which is the entire difference from the behaviour this
/// replaced, where the same record was dropped in silence and read as a hung
/// guest. The reconciler retries `cont` every tick while a session is live, so
/// the caller's next record (the client resends; a visitor clicks again) lands
/// within ~5 s.
/// Does the daemon believe it froze the guest right now?
///
/// One relaxed load of the same mirror `wake_for_input` reads. Exists for the
/// `guest.resume` span (`trace_session.rs`): a resume on a running guest is
/// idempotent and fast, so without this the span would fire on every session
/// and mean nothing. Read BEFORE `session_started`, which clears the belief.
pub fn guest_believed_paused() -> bool {
    PAUSE_BELIEF.load(Ordering::Relaxed)
}

pub async fn wake_for_input() -> bool {
    if !PAUSE_BELIEF.load(Ordering::Relaxed) {
        return true;
    }
    let Some(p) = PAUSER.get() else {
        // Belief set with no pauser installed is impossible; deliver rather
        // than invent a drop.
        return true;
    };
    match p.wake("input").await {
        Ok(()) => true,
        Err(e) => {
            let n = INPUT_DROPPED.fetch_add(1, Ordering::Relaxed) + 1;
            eprintln!(
                "[idle] INPUT DROPPED (#{n}): guest is idle-auto-paused and the wake failed ({e}). \
                 Not queued — a replayed event is false evidence. Reconciler retries every 5s."
            );
            false
        }
    }
}

/// Where an out-of-band driver knocks to hold this station's guest awake.
///
/// `SH_WAKE_LEASE` overrides; the default is derived from the STATION NAME so a
/// driver can compute it from the one identifier it always has, without reading
/// the station directory. Must stay in step with `LEASE_DIR` in
/// scripts/lib/guest_wake.py, which is the other end of this protocol.
fn lease_path(station: &str) -> String {
    std::env::var("SH_WAKE_LEASE")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| format!("/run/streamhost/wake/{station}.lease"))
}

/// Is a driver's wake lease live?
///
/// The lease is a file whose MTIME is the whole protocol: an out-of-band driver
/// (labctl, qmp-type.py) touches it while it is injecting, and this reads it.
/// Nothing is parsed, so there is no format to get wrong and no stale PID to
/// mis-resolve; an absent file, an unreadable one or an expired one all answer
/// "no lease", because a lease that cannot be seen must never become a station
/// that never pauses. An mtime in the FUTURE counts as live: clock skew between
/// a driver and the daemon should hold the guest awake, not drop it.
fn lease_live(path: &str, ttl: Duration) -> bool {
    let Ok(md) = std::fs::metadata(path) else {
        return false;
    };
    let Ok(mtime) = md.modified() else {
        return false;
    };
    match SystemTime::now().duration_since(mtime) {
        Ok(age) => age < ttl,
        Err(_) => true,
    }
}

/// How this station's guest is paused and resumed. The reconciler above only ever
/// asks for "stop" or "cont"; this is the whole of what differs between a QEMU
/// station and an emulator station.
pub enum Freezer {
    /// QEMU: `stop`/`cont` over the station's QMP socket.
    Qmp { sock: String },
    /// Non-QEMU emulator: SIGSTOP/SIGCONT the process recorded in `pidfile`,
    /// but only while `proc_match` (when set) appears in its cmdline.
    Signal {
        pidfile: String,
        proc_match: Option<String>,
    },
}

impl Freezer {
    /// Human-readable mechanism, for the one startup log line.
    fn describe(&self) -> String {
        match self {
            Freezer::Qmp { sock } => format!("QMP stop/cont on {sock}"),
            Freezer::Signal { pidfile, .. } => format!("SIGSTOP/SIGCONT on pid from {pidfile}"),
        }
    }

    fn apply(&self, cmd: Cmd) -> anyhow::Result<()> {
        match self {
            Freezer::Qmp { sock } => qmp_execute(sock, cmd.qmp_verb()),
            Freezer::Signal {
                pidfile,
                proc_match,
            } => signal_pidfile(pidfile, proc_match.as_deref(), cmd.signal()),
        }
    }
}

/// The reconciler's two verbs, resolved to a mechanism's own vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Cmd {
    Stop,
    Cont,
}

impl Cmd {
    fn qmp_verb(self) -> &'static str {
        match self {
            Cmd::Stop => "stop",
            Cmd::Cont => "cont",
        }
    }

    fn signal(self) -> libc::c_int {
        match self {
            Cmd::Stop => libc::SIGSTOP,
            Cmd::Cont => libc::SIGCONT,
        }
    }
}

/// Is the emulator this freezer owns OBSERVED to be in state `T` (stopped)?
///
/// Only meaningful for the signal freezer — a QMP-paused guest is a running
/// process, so `false` is the right answer for QEMU and the belief-based rule
/// covers it. Resolution goes through the same pidfile + `proc_match` gate as
/// `signal_pidfile`: an unreadable pidfile, a dead pid or a cmdline that no
/// longer carries the marker all answer `false`, because "I cannot see it" must
/// never become "it is stopped, resume it" — that is how an unrelated process
/// gets signalled.
///
/// `/proc/<pid>/stat` field 3 is the state character. The comm field (2) can
/// contain spaces and parentheses, so parse after the LAST `)`.
fn pid_is_stopped(pidfile: &str, proc_match: Option<&str>) -> bool {
    let Ok(raw) = std::fs::read_to_string(pidfile) else {
        return false;
    };
    let Ok(pid) = raw.trim().parse::<i32>() else {
        return false;
    };
    if pid <= 1 {
        return false;
    }
    if let Some(want) = proc_match {
        let Ok(cmdline) = std::fs::read(format!("/proc/{pid}/cmdline")) else {
            return false;
        };
        if !String::from_utf8_lossy(&cmdline)
            .replace('\0', " ")
            .contains(want)
        {
            return false;
        }
    }
    let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
        return false;
    };
    let Some(after_comm) = stat.rsplit_once(')') else {
        return false;
    };
    matches!(after_comm.1.split_whitespace().next(), Some("T"))
}

/// Read `pidfile`, verify the pid is the process we meant, and signal it.
///
/// Every failure is an Err the reconciler retries on its next tick: a pidfile
/// that is missing (the launcher has not written it yet), empty (the launcher
/// truncates it on teardown), unparseable, dead, or whose cmdline no longer
/// carries `proc_match`. Refusing is always right — the cost of a skipped
/// pause is one station idling for 5 more seconds, the cost of a wrong signal is
/// an unrelated process on labhost paused with no one to resume it.
fn signal_pidfile(pidfile: &str, proc_match: Option<&str>, sig: libc::c_int) -> anyhow::Result<()> {
    let raw =
        std::fs::read_to_string(pidfile).map_err(|e| anyhow::anyhow!("pidfile {pidfile}: {e}"))?;
    let pid: i32 = raw
        .trim()
        .parse()
        .map_err(|_| anyhow::anyhow!("pidfile {pidfile}: not a pid ({:?})", raw.trim()))?;
    if pid <= 1 {
        anyhow::bail!("pidfile {pidfile}: refusing to signal pid {pid}");
    }
    if let Some(want) = proc_match {
        // NUL-separated argv; a plain substring test spans the whole line, which
        // is what the caller's marker (e.g. a MAME machine name) is chosen for.
        let cmdline = std::fs::read(format!("/proc/{pid}/cmdline"))
            .map_err(|e| anyhow::anyhow!("pid {pid} cmdline: {e}"))?;
        let cmdline = String::from_utf8_lossy(&cmdline).replace('\0', " ");
        if !cmdline.contains(want) {
            anyhow::bail!("pid {pid} cmdline does not contain {want:?} — stale pidfile, refusing");
        }
    }
    // SAFETY: kill(2) with a pid we have just resolved through /proc and a
    // constant signal. The only effect is on that pid.
    if unsafe { libc::kill(pid, sig) } != 0 {
        let e = std::io::Error::last_os_error();
        anyhow::bail!("kill({pid}, {sig}): {e}");
    }
    Ok(())
}

/// What the reconciler should do this tick (pure decision, unit-tested).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Action {
    /// Pause the guest (QMP stop). Idempotent on an already-stopped guest.
    Stop,
    /// Resume the guest (QMP cont) — a session is active but the pause belief
    /// is still set (an earlier cont failed / raced).
    Cont,
    None,
}

/// Reconciler decision:
///   * a live WAKE LEASE counts exactly like a session (see `lease_live`): an
///     out-of-band driver is injecting input right now, so the guest must be
///     running and must not be re-frozen under it. This is the race the folklore
///     ("send `cont` and your input back-to-back on ONE connection") was
///     dodging: with sessions == 0 the heal re-assert below re-froze the guest
///     up to 60 s into a driver's sequence, and every remaining keystroke
///     vanished with an OK on the wire.
///   * sessions active + still believed paused  -> Cont (never leave a guest
///     paused under a live session; a resume is NEVER withheld, warmup or not).
///   * sessions active + OBSERVED stopped, whatever we believe -> Cont. Belief
///     is not enough: on the non-QEMU path the LAUNCHER also freezes the
///     emulator (it covers the first grace period, which the daemon cannot),
///     and its delayed SIGSTOP lands ~8 s after launch — i.e. exactly when the
///     first visitor of a cold station arrives, since the visit is what starts
///     the station. The daemon never stopped it, so `paused` is false, so the
///     old belief-only rule did nothing and the guest stayed frozen under a
///     live session: no frames, no keys, and a reconnect storm on the control
///     socket. Observed on vic20 2026-08-16. See `pid_is_stopped`.
///   * still inside the warmup window -> never Stop (see `warmed_up`).
///   * zero sessions, idle past grace, not yet paused -> Stop.
///   * zero sessions, idle past grace, believed paused + heal window elapsed
///     -> Stop again (re-assert; heals an external `cont`, e.g. labctl).
///
/// `warmed_up` is false only during SH_IDLE_PAUSE_WARMUP_SECS after daemon
/// start, for a station whose own health machinery needs the guest RUNNING to vet
/// it and would otherwise never get a look (irix's livewatch — see the field
/// doc on Config::idle_pause_warmup_secs).
fn reconcile_action(w: Snapshot) -> Action {
    if w.sessions > 0 || w.wake_leased {
        if w.paused || w.observed_stopped {
            Action::Cont
        } else {
            Action::None
        }
    } else if w.warmed_up && w.idle_for >= w.grace && (!w.paused || w.heal_due) {
        Action::Stop
    } else {
        Action::None
    }
}

/// Everything one reconciler tick knows, named.
///
/// These used to be eight positional arguments, three of them booleans that all
/// default to "no" — unreadable at the call site and, worse, unreadable in the
/// tests, which are the actual specification of this policy.
#[derive(Debug, Clone, Copy)]
struct Snapshot {
    /// Live WebTransport sessions (visitors).
    sessions: usize,
    /// We believe WE stopped the guest and have not resumed it.
    paused: bool,
    /// How long since the last session left.
    idle_for: Duration,
    grace: Duration,
    /// The 60 s re-assert tick is due (heals an external `cont`).
    heal_due: bool,
    /// Past SH_IDLE_PAUSE_WARMUP_SECS since daemon start.
    warmed_up: bool,
    /// The emulator process is OBSERVED in state T (signal freezer only).
    observed_stopped: bool,
    /// An out-of-band driver holds a fresh wake lease.
    wake_leased: bool,
}

struct St {
    sessions: usize,
    /// Instant the session count last dropped to zero (or process start).
    idle_since: Instant,
    /// Our belief that WE stopped the guest and have not successfully resumed
    /// it. Only cleared by a SUCCESSFUL cont.
    paused: bool,
    heal_ticks: u32,
}

pub struct IdlePauser {
    freezer: Arc<Freezer>,
    grace: Duration,
    /// Path an out-of-band driver touches to hold the guest awake (see the
    /// WAKE LEASE section in the header).
    lease: String,
    /// Daemon start; `warmup` is measured from here (never restarted, so a
    /// long-lived daemon is warm and stays warm).
    started: Instant,
    warmup: Duration,
    st: tokio::sync::Mutex<St>,
}

const TICK: Duration = Duration::from_secs(5);
const HEAL_EVERY: u32 = 12; // re-assert a believed pause every 12 ticks = 60 s

impl IdlePauser {
    /// Returns None when disabled (grace 0). Spawns the reconciler task.
    pub fn new(
        freezer: Freezer,
        grace_secs: u64,
        warmup_secs: u64,
        station: &str,
    ) -> Option<Arc<IdlePauser>> {
        if grace_secs == 0 {
            return None;
        }
        let lease = lease_path(station);
        // The lease is a door other processes knock on, so it has to exist as a
        // path they can create. Failing to make the directory is not fatal — a
        // station simply has no out-of-band wake lease, which is where we were
        // before — but it is worth one line, because the symptom otherwise is a
        // driver whose touch silently goes nowhere.
        if let Some(dir) = std::path::Path::new(&lease).parent() {
            if let Err(e) = std::fs::create_dir_all(dir) {
                eprintln!("[idle] wake-lease dir {} unusable ({e})", dir.display());
            }
        }
        eprintln!(
            "[streamhost] idle auto-pause ON (grace {grace_secs}s, warmup {warmup_secs}s; all platform transports; {}; wake lease {lease} ttl {}s)",
            freezer.describe(),
            LEASE_TTL.as_secs()
        );
        let p = Arc::new(IdlePauser {
            freezer: Arc::new(freezer),
            grace: Duration::from_secs(grace_secs),
            lease,
            started: Instant::now(),
            warmup: Duration::from_secs(warmup_secs),
            st: tokio::sync::Mutex::new(St {
                sessions: 0,
                idle_since: Instant::now(),
                paused: false,
                heal_ticks: 0,
            }),
        });
        // Ignore a second install: `new` is called once per process, and a test
        // that builds two must not have the first one's wake door hijacked.
        let _ = PAUSER.set(p.clone());
        tokio::spawn(p.clone().reconcile_loop());
        Some(p)
    }

    /// Record the pause belief in both places at once, so `guest_believed_paused`
    /// can never disagree with the state the reconciler acts on. Every write to
    /// `st.paused` goes through here.
    fn set_paused(st: &mut St, paused: bool) {
        st.paused = paused;
        PAUSE_BELIEF.store(paused, Ordering::Relaxed);
    }

    /// Resume NOW because something wants to reach the guest, and report whether
    /// it worked. Used by `wake_for_input`; `why` names the caller in the log.
    ///
    /// A guest we do not believe we paused is already the caller's to use — that
    /// includes the case where a concurrent record won the race and resumed it,
    /// which is why the belief is re-checked under the lock rather than trusted
    /// from the atomic.
    async fn wake(&self, why: &str) -> anyhow::Result<()> {
        let mut st = self.st.lock().await;
        if !st.paused {
            return Ok(());
        }
        self.exec(Cmd::Cont).await?;
        Self::set_paused(&mut st, false);
        crate::rel_bridge::note_guest_resumed();
        eprintln!("[idle] {why} arrived on a paused guest -> resumed before delivery");
        Ok(())
    }

    /// Call on every accepted WebTransport session, BEFORE priming video.
    /// Issues `cont` unconditionally (idempotent on a running guest, a few ms)
    /// so the guest is live no matter who paused it or what state we believe.
    pub async fn session_started(&self) {
        let mut st = self.st.lock().await;
        st.sessions += 1;
        let was_paused = st.paused;
        match self.exec(Cmd::Cont).await {
            Ok(()) => {
                if was_paused {
                    eprintln!("[idle] session connected -> guest resumed");
                    crate::rel_bridge::note_guest_resumed();
                }
                Self::set_paused(&mut st, false);
            }
            // Keep paused=true: the reconciler retries cont while sessions > 0.
            Err(e) => eprintln!("[idle] resume on connect failed ({e}); reconciler will retry"),
        }
    }

    /// Call when a session ends (SessionGuard drop). Starts the idle clock
    /// when the LAST session leaves; the reconciler pauses after `grace`.
    pub async fn session_ended(&self) {
        let mut st = self.st.lock().await;
        st.sessions = st.sessions.saturating_sub(1);
        if st.sessions == 0 {
            st.idle_since = Instant::now();
        }
    }

    async fn reconcile_loop(self: Arc<Self>) {
        loop {
            tokio::time::sleep(TICK).await;
            let mut st = self.st.lock().await;
            st.heal_ticks = st.heal_ticks.saturating_add(1);
            let heal_due = st.heal_ticks >= HEAL_EVERY;
            // Blocking metadata read of a path in /run; cheap enough for a 5 s
            // tick that it is not worth a spawn_blocking hop.
            let wake_leased = lease_live(&self.lease, LEASE_TTL);
            // Only probed while the guest is SUPPOSED to be awake (a session or
            // a driver lease) and we do not already believe we paused it — the
            // belief path already resolves to Cont, and a station with neither
            // is stopped on purpose.
            let observed_stopped = (st.sessions > 0 || wake_leased)
                && !st.paused
                && match &*self.freezer {
                    Freezer::Signal {
                        pidfile,
                        proc_match,
                    } => pid_is_stopped(pidfile, proc_match.as_deref()),
                    _ => false,
                };
            let act = reconcile_action(Snapshot {
                sessions: st.sessions,
                paused: st.paused,
                idle_for: st.idle_since.elapsed(),
                grace: self.grace,
                heal_due,
                warmed_up: self.started.elapsed() >= self.warmup,
                observed_stopped,
                wake_leased,
            });
            match act {
                Action::Stop => {
                    st.heal_ticks = 0;
                    let first = !st.paused;
                    match self.exec(Cmd::Stop).await {
                        Ok(()) => {
                            Self::set_paused(&mut st, true);
                            if first {
                                eprintln!(
                                    "[idle] no sessions for {}s -> guest paused (resumes on next visit)",
                                    self.grace.as_secs()
                                );
                            }
                        }
                        Err(e) => eprintln!("[idle] pause failed ({e}); will retry"),
                    }
                }
                Action::Cont => match self.exec(Cmd::Cont).await {
                    Ok(()) => {
                        Self::set_paused(&mut st, false);
                        crate::rel_bridge::note_guest_resumed();
                        let who = if st.sessions > 0 { "session" } else { "driver" };
                        eprintln!("[idle] {who} active but guest paused -> resumed");
                    }
                    Err(e) => eprintln!("[idle] resume retry failed ({e}); will retry"),
                },
                Action::None => {}
            }
        }
    }

    /// Apply one pause/resume verb (blocking I/O — a transient QMP connection or
    /// a /proc read — off the runtime). Held under the state lock by callers,
    /// which serializes stop/cont ordering.
    async fn exec(&self, cmd: Cmd) -> anyhow::Result<()> {
        let freezer = self.freezer.clone();
        tokio::task::spawn_blocking(move || freezer.apply(cmd)).await?
    }
}

/// RAII session marker: created after a session is accepted; its Drop reports
/// the session end on EVERY exit path of handle_session (clean end, transport
/// error, task abort at cert rotation).
pub struct SessionGuard {
    p: Arc<IdlePauser>,
}

impl SessionGuard {
    pub fn new(p: Arc<IdlePauser>) -> Self {
        SessionGuard { p }
    }
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        let p = self.p.clone();
        if let Ok(h) = tokio::runtime::Handle::try_current() {
            h.spawn(async move { p.session_ended().await });
        }
    }
}

/// One-shot QMP command over a fresh connection: connect, greeting,
/// qmp_capabilities, execute, await the result. 2 s read/write timeouts so a
/// busy socket (another transient QMP client) fails fast instead of wedging
/// the pauser.
fn qmp_execute(qmp_path: &str, cmd: &str) -> anyhow::Result<()> {
    let sock = UnixStream::connect(qmp_path)?;
    sock.set_read_timeout(Some(Duration::from_secs(2)))?;
    sock.set_write_timeout(Some(Duration::from_secs(2)))?;
    let mut r = BufReader::new(sock.try_clone()?);
    let mut w = sock;
    let mut greeting = String::new();
    r.read_line(&mut greeting)?; // {"QMP": {...}}
    writeln!(w, "{{\"execute\":\"qmp_capabilities\"}}")?;
    read_result(&mut r)?;
    writeln!(w, "{{\"execute\":\"{cmd}\"}}")?;
    read_result(&mut r)?;
    Ok(())
}

/// Read QMP lines until a command RESULT arrives: `"return"` = ok, `"error"` =
/// err. Skips interleaved async event lines — `stop`/`cont` themselves emit
/// STOP/RESUME events that can land before the return. Bounded so a chatty or
/// broken peer can't loop us forever.
fn read_result(r: &mut impl BufRead) -> anyhow::Result<()> {
    for _ in 0..32 {
        let mut line = String::new();
        if r.read_line(&mut line)? == 0 {
            anyhow::bail!("QMP EOF before command result");
        }
        if line.contains("\"event\"") {
            continue;
        }
        if line.contains("\"return\"") {
            return Ok(());
        }
        if line.contains("\"error\"") {
            anyhow::bail!("QMP error: {}", line.trim());
        }
    }
    anyhow::bail!("QMP: no result within 32 lines")
}

#[cfg(test)]
#[path = "idle_tests.rs"]
mod tests;
