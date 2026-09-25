// Auto-reset: put a station back on its golden when its visitor is done with it.
//
// WHY. A shared exhibit accumulates the last visitor's state, and some guests rot
// under it. nokia9300 measured it (2026-09-25, agent U1): twelve apps piled up in
// one 23-minute session, EKA2L1's RSS grew 309 -> 565 MB, focus drifted away from
// the painted screen, and a dozen app switches later the emulator segfaulted in
// front of the visitor. The "Restore to golden" button fixes that for a visitor
// who knows to press it; this is the same reset, run by the daemon, for the next
// visitor who should not have to.
//
// TWO TRIGGERS, both armed only when the guest SAW INPUT since the last reset (a
// visitor who only watched left nothing behind, and a station nobody touched is
// never reset in a loop):
//   * SESSION END — SH_AUTO_RESET_AFTER_SESSION_SECS after the last session left.
//     The grace is what keeps a page reload, a Wi-Fi blip or a tab switch that
//     reconnects from wiping the visitor's work: a session that returns inside it
//     cancels the reset.
//   * INPUT IDLE — SH_AUTO_RESET_INPUT_IDLE_SECS with no input record at all,
//     sessions or not: the visitor who walked away from an open tab.
// A live WAKE LEASE (idle.rs) withholds both: an out-of-band driver (labctl, an
// agent's probe) is using the guest right now.
//
// THE RESET ITSELF is not the daemon's business: SH_AUTO_RESET_CMD names it
// (whitespace-split argv, no shell), and the fleet's one authoritative reset is
// `reset-tile.sh <station>` — the same script the gallery's Restore button runs,
// so a station's reset has exactly one definition. The daemon keeps streaming
// through it; a station whose reset is in-process (nokia9300: `ekactl quit`, the
// container's inner loop relaunches from the golden) never drops the visitor's
// stream. Unset SH_AUTO_RESET_CMD, or both triggers 0, = off (the default).
//
// SESSIONS AND INPUT come from the two places that already see them: idle.rs's
// session bookkeeping (`sessions_changed`) and its input funnel
// (`wake_for_input` -> `note_input`). A station with auto-reset but idle-pause 0
// still gets that bookkeeping — IdlePauser runs in track-only mode (no pause).
//
// Config (env-only, station.env):
//   SH_AUTO_RESET_CMD                  argv of the reset, e.g.
//                                      /bin/bash /data/vms/streamhost/serve/reset-tile.sh nokia9300
//   SH_AUTO_RESET_AFTER_SESSION_SECS   0 = off
//   SH_AUTO_RESET_INPUT_IDLE_SECS      0 = off

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

const TICK: Duration = Duration::from_secs(5);
/// A reset that has not finished in this long is abandoned (and logged); the
/// longest legitimate one is reset-tile.sh's cold service-restart fallback.
const RESET_TIMEOUT: Duration = Duration::from_secs(180);

#[derive(Debug, Clone)]
pub struct Cfg {
    pub cmd: Vec<String>,
    pub after_session: Duration,
    pub input_idle: Duration,
    pub lease: String,
}

static CFG: OnceLock<Cfg> = OnceLock::new();
static EPOCH: OnceLock<Instant> = OnceLock::new();
static SESSIONS: AtomicUsize = AtomicUsize::new(0);
/// Milliseconds since EPOCH, +1 so that 0 means "never".
static LAST_INPUT: AtomicU64 = AtomicU64::new(0);
static LAST_RESET: AtomicU64 = AtomicU64::new(0);
/// When the session count last dropped to zero (0 = daemon start).
static IDLE_SINCE: AtomicU64 = AtomicU64::new(0);
static RESETTING: AtomicBool = AtomicBool::new(false);

fn now_ms() -> u64 {
    EPOCH.get_or_init(Instant::now).elapsed().as_millis() as u64 + 1
}

fn secs_env(name: &str) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(0)
}

/// Read the three knobs. None = auto-reset off (no command, or no trigger).
pub fn cfg_from_env(lease: String) -> Option<Cfg> {
    let cmd: Vec<String> = std::env::var("SH_AUTO_RESET_CMD")
        .unwrap_or_default()
        .split_whitespace()
        .map(str::to_string)
        .collect();
    let after_session = secs_env("SH_AUTO_RESET_AFTER_SESSION_SECS");
    let input_idle = secs_env("SH_AUTO_RESET_INPUT_IDLE_SECS");
    if cmd.is_empty() || (after_session == 0 && input_idle == 0) {
        return None;
    }
    Some(Cfg {
        cmd,
        after_session: Duration::from_secs(after_session),
        input_idle: Duration::from_secs(input_idle),
        lease,
    })
}

/// Install from the environment and start the watcher. Logs one ON/OFF line.
/// Call once, from main, before the transports accept sessions.
pub fn install_from_env(station: &str) {
    let _ = EPOCH.get_or_init(Instant::now);
    let Some(cfg) = cfg_from_env(crate::idle::lease_path(station)) else {
        return;
    };
    eprintln!(
        "[streamhost] auto-reset ON (after last session {}s, after input idle {}s, only if the guest saw input; cmd: {})",
        cfg.after_session.as_secs(),
        cfg.input_idle.as_secs(),
        cfg.cmd.join(" ")
    );
    if CFG.set(cfg).is_ok() {
        tokio::spawn(watch_loop());
    }
}

pub fn enabled() -> bool {
    CFG.get().is_some()
}

/// Every input record that reaches the guest (idle.rs `wake_for_input`).
pub fn note_input() {
    if enabled() {
        LAST_INPUT.store(now_ms(), Ordering::Relaxed);
    }
}

/// The live session count changed (idle.rs session bookkeeping).
pub fn sessions_changed(n: usize) {
    if SESSIONS.swap(n, Ordering::Relaxed) > 0 && n == 0 {
        IDLE_SINCE.store(now_ms(), Ordering::Relaxed);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Why {
    SessionEnded,
    InputIdle,
}

/// One watcher tick, everything it knows (all times in ms since EPOCH, 0 = never).
#[derive(Debug, Clone, Copy)]
pub(crate) struct Snap {
    pub now: u64,
    pub sessions: usize,
    pub idle_since: u64,
    pub last_input: u64,
    pub last_reset: u64,
    pub leased: bool,
    pub resetting: bool,
    pub after_session: u64,
    pub input_idle: u64,
}

/// The whole policy, pure (unit-tested in auto_reset_tests.rs).
pub(crate) fn decide(s: Snap) -> Option<Why> {
    let dirty = s.last_input > s.last_reset;
    if !dirty || s.leased || s.resetting {
        return None;
    }
    if s.after_session > 0
        && s.sessions == 0
        && s.now.saturating_sub(s.idle_since.max(s.last_input)) >= s.after_session
    {
        return Some(Why::SessionEnded);
    }
    if s.input_idle > 0 && s.now.saturating_sub(s.last_input) >= s.input_idle {
        return Some(Why::InputIdle);
    }
    None
}

async fn watch_loop() {
    let Some(cfg) = CFG.get() else { return };
    loop {
        tokio::time::sleep(TICK).await;
        let snap = Snap {
            now: now_ms(),
            sessions: SESSIONS.load(Ordering::Relaxed),
            idle_since: IDLE_SINCE.load(Ordering::Relaxed),
            last_input: LAST_INPUT.load(Ordering::Relaxed),
            last_reset: LAST_RESET.load(Ordering::Relaxed),
            leased: crate::idle::lease_live(&cfg.lease, crate::idle::LEASE_TTL),
            resetting: RESETTING.load(Ordering::Relaxed),
            after_session: cfg.after_session.as_millis() as u64,
            input_idle: cfg.input_idle.as_millis() as u64,
        };
        let Some(why) = decide(snap) else { continue };
        let what = match why {
            Why::SessionEnded => format!(
                "last session left {}s ago",
                snap.now.saturating_sub(snap.idle_since) / 1000
            ),
            Why::InputIdle => format!(
                "no input for {}s ({} session(s) open)",
                snap.now.saturating_sub(snap.last_input) / 1000,
                snap.sessions
            ),
        };
        // Stamp BEFORE running: input that arrives during the reset re-arms it.
        LAST_RESET.store(snap.now, Ordering::Relaxed);
        RESETTING.store(true, Ordering::Relaxed);
        eprintln!("[auto-reset] {what} and the guest saw input -> resetting");
        tokio::spawn(run_reset(cfg.cmd.clone()));
    }
}

async fn run_reset(cmd: Vec<String>) {
    let t0 = Instant::now();
    let child = tokio::process::Command::new(&cmd[0])
        .args(&cmd[1..])
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(RESET_TIMEOUT, child).await {
        Ok(Ok(out)) => {
            let text = String::from_utf8_lossy(if out.stdout.is_empty() {
                &out.stderr
            } else {
                &out.stdout
            })
            .trim()
            .replace('\n', " | ");
            eprintln!(
                "[auto-reset] reset rc={} in {:.1}s: {text}",
                out.status.code().unwrap_or(-1),
                t0.elapsed().as_secs_f64()
            );
        }
        Ok(Err(e)) => eprintln!(
            "[auto-reset] reset could not start ({e}): {}",
            cmd.join(" ")
        ),
        Err(_) => eprintln!(
            "[auto-reset] reset timed out after {}s and was killed",
            RESET_TIMEOUT.as_secs()
        ),
    }
    RESETTING.store(false, Ordering::Relaxed);
}

#[cfg(test)]
#[path = "auto_reset_tests.rs"]
mod tests;
