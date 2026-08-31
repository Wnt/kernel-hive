//! The guest-lifecycle spans — the emulator layer, measured from outside it.
//!
//! CONTRACT §5: no span is ever emitted from INSIDE a guest. Most of these
//! machines could not speak OTLP if we asked them to, the ones that could would
//! need a network stack this lab keeps off them, and an agent phoning a 2026
//! observability backend out of a 1993 desktop is no longer the artefact the
//! museum is for. So "emulator spans" means spans the DAEMON emits ABOUT the
//! guest, and this module is that set:
//!
//! | span | what it settles |
//! |---|---|
//! | `guest.launch` | how long the emulator process had been alive before this daemon could see it — for the `-loadvm golden -S` stations, that window IS the checkpoint restore |
//! | `guest.attach` | the QMP handshake + dbus-display registration: the daemon's own cost of getting a picture |
//! | `guest.first_frame` | when a framebuffer with real geometry first existed. AGENTS.md rule 9 in span form: the framebuffer is the only proof |
//!
//! These are per DAEMON START, not per session, so they form their own small
//! root trace with no browser to join — there is no visitor present when a
//! station boots, and inventing a parent for them would be exactly the false
//! causal claim contract §7 forbids. The per-session view of the same question
//! is `trace_session.rs`.
//!
//! WHY THE PROCESS START TIME IS READ OUT OF `/proc` RATHER THAN GUESSED. The
//! daemon does not launch the emulator — the station's launcher does, with
//! `-loadvm golden -S` on the checkpointed stations — so the only honest source
//! for "when did the guest process begin" is the kernel's own accounting.
//! `/proc/<pid>/stat` field 22 is the start time in clock ticks since boot and
//! `/proc/stat`'s `btime` is boot's wall clock; together they give a real
//! timestamp. Every step of that can fail (no pidfile, a stale pid, a container
//! with no `/proc/stat`), and every failure simply omits the span rather than
//! substituting a number.

use std::time::Instant;

use crate::config::Config;
use crate::trace::{self, Ctx, Kind, Span, Val};

/// The daemon's startup trace.
pub struct Startup {
    ctx: Ctx,
    span: Option<Span>,
    t0: Instant,
    start_ms: u64,
}

/// Open the startup trace. Emits nothing until the phases below report.
pub fn begin() -> Startup {
    let span = Span::root("streamhost.start", Kind::Internal);
    Startup {
        ctx: span.ctx(),
        span: Some(span),
        t0: Instant::now(),
        start_ms: trace::now_unix_ms(),
    }
}

impl Startup {
    /// `guest.launch` — the emulator process's own life before we attached.
    /// Silent when the station names no pidfile or the pid cannot be resolved:
    /// a station with no pidfile is a fact about the station, not a gap to fill
    /// with a fabricated duration.
    pub fn guest_launch(&self, cfg: &Config) {
        let Some(pid) = guest_pid(cfg) else {
            return;
        };
        let Some(started_ms) = proc_start_ms(pid) else {
            return;
        };
        let now = trace::now_unix_ms();
        if started_ms > now {
            return;
        }
        trace::emit_at(
            "guest.launch",
            Kind::Internal,
            self.ctx,
            started_ms,
            now - started_ms,
            &[
                ("kh.guest.pid", Val::I(pid as i64)),
                (
                    "kh.capture.backend",
                    Val::S(cfg.capture_backend.as_str().into()),
                ),
            ],
            "ok",
        );
    }

    /// `guest.attach` — the QMP getfd/add_client handshake and the p2p
    /// dbus-display listener registration, i.e. everything between "a process
    /// exists" and "this daemon can be handed pixels".
    pub fn attached(&self, cfg: &Config, took: std::time::Duration, ok: bool) {
        trace::emit_at(
            "guest.attach",
            Kind::Client,
            self.ctx,
            trace::now_unix_ms().saturating_sub(took.as_millis() as u64),
            took.as_millis() as u64,
            &[(
                "kh.capture.backend",
                Val::S(cfg.capture_backend.as_str().into()),
            )],
            if ok { "ok" } else { "error" },
        );
    }

    /// `guest.first_frame` — a framebuffer with real geometry exists. Closes
    /// the startup trace, because after this the station is streamable and
    /// everything else that happens to it belongs to a visitor's trace.
    pub fn first_frame(&mut self, w: u32, h: u32, shm: bool) {
        trace::emit_at(
            "guest.first_frame",
            Kind::Internal,
            self.ctx,
            self.start_ms,
            self.t0.elapsed().as_millis() as u64,
            &[
                ("kh.frame.width", Val::I(w as i64)),
                ("kh.frame.height", Val::I(h as i64)),
                ("kh.capture.shm", Val::B(shm)),
            ],
            "ok",
        );
        if let Some(mut s) = self.span.take() {
            s.ok();
            s.end();
        }
    }
}

/// The emulator's pid, from whichever pidfile this station publishes.
///
/// Order matches the rest of the daemon: `SH_QEMU_PIDFILE` wins (the RSS guard
/// reads the same knob), then `qemu.pid` beside the QMP socket, then the
/// idle-pauser's pidfile — which is the ONLY one the x11/shm emulator stations
/// have, since they have no QMP socket at all.
fn guest_pid(cfg: &Config) -> Option<u32> {
    let candidates = [
        std::env::var("SH_QEMU_PIDFILE").ok(),
        std::path::Path::new(&cfg.qmp_sock)
            .parent()
            .map(|d| d.join("qemu.pid").to_string_lossy().into_owned()),
        cfg.idle_pause_pidfile.clone(),
    ];
    for c in candidates.into_iter().flatten() {
        if c.trim().is_empty() {
            continue;
        }
        if let Some(pid) = std::fs::read_to_string(&c)
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok())
            .filter(|p| *p > 0)
        {
            // Resolve through /proc, never through a cmdline grep (AGENTS.md
            // rule 5): if the pid has no /proc entry the pidfile is stale.
            if std::path::Path::new(&format!("/proc/{pid}")).exists() {
                return Some(pid);
            }
        }
    }
    None
}

/// Boot time in unix seconds, from `/proc/stat`'s `btime` line.
fn btime_secs() -> Option<u64> {
    std::fs::read_to_string("/proc/stat").ok().and_then(|s| {
        s.lines()
            .find_map(|l| l.strip_prefix("btime "))
            .and_then(|v| v.trim().parse().ok())
    })
}

/// Unix ms at which `pid` started.
///
/// `/proc/<pid>/stat` field 22 is `starttime`, in clock ticks since boot. The
/// second field is `comm`, which is an arbitrary program name wrapped in
/// parentheses and may itself contain spaces and parentheses — so the split is
/// taken after the LAST `)`, which is the only parse of this file that is not a
/// latent bug.
fn proc_start_ms(pid: u32) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = &stat[stat.rfind(')')? + 1..];
    // After `comm` the next field is `state`, so `starttime` (field 22) is the
    // 20th field of what remains.
    let ticks: u64 = rest.split_whitespace().nth(19)?.parse().ok()?;
    // SAFETY: sysconf(3) with a constant name; it reads no memory we own.
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if hz <= 0 {
        return None;
    }
    Some(btime_secs()? * 1000 + ticks * 1000 / hz as u64)
}
