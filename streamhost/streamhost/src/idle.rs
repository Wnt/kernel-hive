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
// Config: SH_IDLE_PAUSE_SECS / --idle-pause-secs (default 60; 0 = disabled;
// per-station override via tile.env), SH_IDLE_PAUSE_PIDFILE +
// SH_IDLE_PAUSE_PROC_MATCH (non-QEMU stations). See docs/IDLE-PAUSE.md.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

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
///   * sessions active + still believed paused  -> Cont (never leave a guest
///     paused under a live session; a resume is NEVER withheld, warmup or not).
///   * still inside the warmup window -> never Stop (see `warmed_up`).
///   * zero sessions, idle past grace, not yet paused -> Stop.
///   * zero sessions, idle past grace, believed paused + heal window elapsed
///     -> Stop again (re-assert; heals an external `cont`, e.g. labctl).
///
/// `warmed_up` is false only during SH_IDLE_PAUSE_WARMUP_SECS after daemon
/// start, for a station whose own health machinery needs the guest RUNNING to vet
/// it and would otherwise never get a look (irix's livewatch — see the field
/// doc on Config::idle_pause_warmup_secs).
fn reconcile_action(
    sessions: usize,
    paused: bool,
    idle_for: Duration,
    grace: Duration,
    heal_due: bool,
    warmed_up: bool,
) -> Action {
    if sessions > 0 {
        if paused {
            Action::Cont
        } else {
            Action::None
        }
    } else if warmed_up && idle_for >= grace && (!paused || heal_due) {
        Action::Stop
    } else {
        Action::None
    }
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
    pub fn new(freezer: Freezer, grace_secs: u64, warmup_secs: u64) -> Option<Arc<IdlePauser>> {
        if grace_secs == 0 {
            return None;
        }
        eprintln!(
            "[streamhost] idle auto-pause ON (grace {grace_secs}s, warmup {warmup_secs}s; all platform transports; {})",
            freezer.describe()
        );
        let p = Arc::new(IdlePauser {
            freezer: Arc::new(freezer),
            grace: Duration::from_secs(grace_secs),
            started: Instant::now(),
            warmup: Duration::from_secs(warmup_secs),
            st: tokio::sync::Mutex::new(St {
                sessions: 0,
                idle_since: Instant::now(),
                paused: false,
                heal_ticks: 0,
            }),
        });
        tokio::spawn(p.clone().reconcile_loop());
        Some(p)
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
                }
                st.paused = false;
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
            let act = reconcile_action(
                st.sessions,
                st.paused,
                st.idle_since.elapsed(),
                self.grace,
                heal_due,
                self.started.elapsed() >= self.warmup,
            );
            match act {
                Action::Stop => {
                    st.heal_ticks = 0;
                    let first = !st.paused;
                    match self.exec(Cmd::Stop).await {
                        Ok(()) => {
                            st.paused = true;
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
                        st.paused = false;
                        eprintln!("[idle] session active but guest paused -> resumed");
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
mod tests {
    use super::{read_result, reconcile_action, signal_pidfile, Action};
    use std::time::Duration;

    const G: Duration = Duration::from_secs(60);

    #[test]
    fn pauses_after_grace_when_idle() {
        assert_eq!(
            reconcile_action(0, false, Duration::from_secs(61), G, false, true),
            Action::Stop
        );
    }

    #[test]
    fn no_pause_before_grace() {
        assert_eq!(
            reconcile_action(0, false, Duration::from_secs(59), G, false, true),
            Action::None
        );
    }

    #[test]
    fn never_paused_under_active_session() {
        // Active session + stale pause belief (a cont failed): must resume.
        assert_eq!(
            reconcile_action(1, true, Duration::from_secs(999), G, true, true),
            Action::Cont
        );
        // Active session, running: nothing to do, regardless of idle clock.
        assert_eq!(
            reconcile_action(2, false, Duration::from_secs(999), G, true, true),
            Action::None
        );
    }

    #[test]
    fn believed_pause_reasserted_only_on_heal_tick() {
        // Already paused: no per-tick QMP chatter...
        assert_eq!(
            reconcile_action(0, true, Duration::from_secs(300), G, false, true),
            Action::None
        );
        // ...but the heal tick re-stops (self-heal after an external labctl cont).
        assert_eq!(
            reconcile_action(0, true, Duration::from_secs(300), G, true, true),
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
            reconcile_action(0, false, Duration::from_secs(999), G, false, false),
            Action::None
        );
        // Not even the heal re-assert fires early.
        assert_eq!(
            reconcile_action(0, true, Duration::from_secs(999), G, true, false),
            Action::None
        );
        // A resume is never withheld: a session under a stale pause belief
        // must be thawed no matter where the warmup clock stands.
        assert_eq!(
            reconcile_action(1, true, Duration::from_secs(1), G, false, false),
            Action::Cont
        );
        // ...and once warm, the same idle state freezes as usual.
        assert_eq!(
            reconcile_action(0, false, Duration::from_secs(999), G, false, true),
            Action::Stop
        );
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
}
