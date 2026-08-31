//! Spans — the daemon's half of the trace plane (`docs/lab/TRACE-CONTEXT.md`,
//! `docs/ANALYTICS.md`).
//!
//! WHAT THIS IS FOR, AND HOW IT DIFFERS FROM `probes.rs`. The probe plane
//! answers "which code has ever run" with hit counts and no time axis at all.
//! It cannot answer the question a visitor actually asks — *why was that slow* —
//! because a count has no start, no end and no parent. Spans do: one visit
//! becomes one flame graph across four processes, and the station's
//! `guest.resume` sits next to the browser's own `station.open.toFirstFrameMs`
//! so "was it slow because the machine was asleep" stops being a correlation
//! exercise (contract §6). The two planes are complementary and BOTH stay: a
//! per-frame number belongs in a counter, a transition belongs in a span.
//!
//! **SPANS MARK TRANSITIONS AND ONE-OFFS. NEVER A SPAN PER FRAME OR PER INPUT
//! EDGE.** At 60 fps a per-frame span is 3600 spans a minute per station and
//! 219 600 a minute across the fleet, which is not observability, it is a
//! second video stream made of JSON. Everything emitted here fires at most once
//! per session or once per daemon start; the per-frame and per-record data is
//! already in `probes.rs` and in the ABR/telemetry counters. `trace_session.rs`
//! enforces the once-per-session half with an `AtomicBool` swap per mark, so
//! the hot paths pay one relaxed load and nothing else.
//!
//! COST, measured rather than asserted. `span_cost_is_small` in `trace/tests.rs`
//! prints both arms; on the lab build box, 20 000 spans back to back:
//!
//! | profile | disabled | enabled (1 attribute) |
//! |---|---|---|
//! | `--release` (opt-level 2 — what ships) | **50-70 ns** | **3.2 us** |
//! | default `cargo test` (debug) | 214 ns | 9.3 us |
//!
//! A session emits at most seven spans, so a visitor costs about **22 us** of
//! daemon time — a thousandth of one frame's budget. The hot paths pay none of
//! it: `SessionTrace`'s marks are an `AtomicBool` swap, so the encoder relay and
//! the datagram loop see one relaxed load per frame and per record.
//!
//! WHAT IS NOT MEASURED, stated rather than glossed — `probes.rs` set that
//! precedent by refusing to claim a contended number it had not taken:
//!   * The FLUSH. It is a string join plus one `rename(2)`, off every request
//!     path, once every 30 s, on a task of its own.
//!   * CONTENTION on the span buffer's `Mutex`. Every span here is per session
//!     or per daemon start, so the regime where two hot tasks queue on that lock
//!     does not exist; measuring it would describe a station this lab does not
//!     run.
//!   * The sub-breakdown of the 3.2 us. It was attempted and the shared build
//!     box was too noisy to attribute it (the parts summed to more than the
//!     whole), so no number is claimed for the split.
//!
//! WHY THERE IS AN OFF SWITCH WHEN `probes.rs` ARGUED AGAINST ONE. A probe hit
//! is a `fetch_add`, so a branch to skip it would have cost more than it saved
//! and would have made every dumped zero ambiguous. A span allocates, formats
//! and writes files; the branch pays for itself, and a disabled station is not
//! ambiguous — it publishes no spool directory at all, which reads as "off"
//! rather than as "nothing happened". `SH_TRACE=off` is the switch; the default
//! is on.
//!
//! NEVER A SECRET IN A SPAN (contract §7). The session ticket, the nonce, the
//! signature, the HMAC key and the peer address are never attributes here, and
//! nothing in this module can reach them: `SessionTrace::begin` takes the parsed
//! context, not the path.

pub mod context;
mod spool;
mod types;

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

pub use context::Ctx;
pub use types::{Kind, Val};

// ---------------------------------------------------------------------------
// Process state
// ---------------------------------------------------------------------------

static ENABLED: OnceLock<bool> = OnceLock::new();
static STATION: OnceLock<String> = OnceLock::new();
/// Rendered spans awaiting a flush. Rendered at `end()` rather than at flush so
/// the flush task holds the lock for a `Vec` swap and nothing else.
static BUF: Mutex<Vec<String>> = Mutex::new(Vec::new());
/// Spans dropped because the buffer was full. Reported in the log, so a station
/// that is silently losing telemetry says so instead of looking healthy.
static DROPPED: AtomicU64 = AtomicU64::new(0);
static SEQ: AtomicU64 = AtomicU64::new(0);

/// Buffered-span ceiling. One session emits at most seven spans, so this is
/// hundreds of concurrent sessions' worth between flushes — far past anything a
/// single station sees, and small enough that a wedged flush cannot grow the
/// daemon's heap.
const BUF_MAX: usize = 4096;
/// Attribute-count ceiling, matching `traces.py::ATTR_MAX`. Enforced here so a
/// span is never truncated at the collector without the emitter knowing.
const ATTR_MAX: usize = 24;
const ATTR_STR_MAX: usize = 120;

/// `SH_TRACE=off|0` disables the plane; anything else (including unset) leaves
/// it on. Read once — a station does not change its mind mid-run, and a
/// `OnceLock` load is cheaper than an env lookup on any path that might be hot.
pub fn enabled() -> bool {
    *ENABLED.get_or_init(|| {
        !matches!(
            std::env::var("SH_TRACE").ok().as_deref().map(str::trim),
            Some("off") | Some("0") | Some("false")
        )
    })
}

fn station() -> &'static str {
    STATION.get().map(String::as_str).unwrap_or("unknown")
}

pub fn now_unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(default)
}

// ---------------------------------------------------------------------------
// Span
// ---------------------------------------------------------------------------

/// An open span. Ended explicitly with `end()`; a span that is dropped without
/// ending is NOT emitted, on purpose — a span whose end time is "wherever the
/// stack unwound to" is a duration nobody can reason about, and an early
/// `return` on an error path would otherwise publish a fictional one.
pub struct Span {
    on: bool,
    /// The trace this span belongs to — inherited from the inbound context, or
    /// minted here when there was none.
    trace: u128,
    sampled: bool,
    /// This span's OWN id.
    id: u64,
    /// The id of the span this one is nested in, if any. Kept separate from
    /// `id` on purpose: folding both into one `Ctx` made a span its own parent,
    /// which renders as a trace with no root and no edges.
    parent: Option<u64>,
    name: &'static str,
    kind: Kind,
    start: Instant,
    start_ms: u64,
    attrs: Vec<(&'static str, Val)>,
    status: &'static str,
    msg: Option<String>,
}

impl Span {
    /// A span with no parent — a new trace. Used when the browser handed us no
    /// context (contract §7: never invent a parent) and for the daemon's own
    /// startup trace, which no browser is present for.
    pub fn root(name: &'static str, kind: Kind) -> Self {
        Self::start_on(enabled(), name, kind, Ctx::root())
    }

    /// A span under `parent`. `parent.span == 0` (a root context) simply yields
    /// a span with no parent id on the same trace.
    pub fn child(name: &'static str, kind: Kind, parent: Ctx) -> Self {
        Self::start_on(enabled(), name, kind, parent)
    }

    /// `on` is a parameter rather than a call to `enabled()` so the cost test
    /// can measure the DISABLED arm for real. The plane's on/off state is a
    /// process-wide `OnceLock`, so a test cannot have it both ways otherwise —
    /// and a "disabled" benchmark that still mints ids measures nothing.
    fn start_on(on: bool, name: &'static str, kind: Kind, inbound: Ctx) -> Self {
        Self {
            on,
            trace: inbound.trace,
            sampled: inbound.sampled,
            id: if on { context::new_span_id() } else { 0 },
            parent: inbound.as_parent(),
            name,
            kind,
            start: Instant::now(),
            start_ms: if on { now_unix_ms() } else { 0 },
            attrs: Vec::new(),
            status: "unset",
            msg: None,
        }
    }

    /// The context children of this span should be parented on: same trace,
    /// with THIS span as the parent.
    pub fn ctx(&self) -> Ctx {
        Ctx {
            trace: self.trace,
            span: self.id,
            sampled: self.sampled,
        }
    }

    pub fn attr(&mut self, key: &'static str, val: impl Into<Val>) -> &mut Self {
        if self.on && self.attrs.len() < ATTR_MAX {
            let mut v = val.into();
            if let Val::S(s) = &mut v {
                s.truncate(ATTR_STR_MAX);
            }
            self.attrs.push((key, v));
        }
        self
    }

    /// Mark the span failed. `msg` is a short static reason, never a payload:
    /// no stack, no typed text, no credential handle (contract §7, and
    /// `traces.py` refuses `exception.stacktrace` at intake anyway).
    pub fn error(&mut self, msg: &'static str) -> &mut Self {
        self.status = "error";
        self.msg = Some(msg.to_string());
        self
    }

    pub fn ok(&mut self) -> &mut Self {
        if self.status == "unset" {
            self.status = "ok";
        }
        self
    }

    /// Close the span and hand it to the buffer.
    pub fn end(self) {
        if !self.on {
            return;
        }
        let dur = self.start.elapsed().as_millis() as u64;
        push(render(
            self.trace,
            self.id,
            self.parent,
            self.name,
            self.kind,
            self.start_ms,
            dur,
            &self.attrs,
            self.status,
            self.msg.as_deref(),
        ));
    }
}

/// Emit a span whose start and duration are KNOWN rather than measured from
/// here — the guest-lifecycle spans, whose start is the emulator process's own
/// start time read out of `/proc` and therefore predates this process.
#[allow(clippy::too_many_arguments)]
pub fn emit_at(
    name: &'static str,
    kind: Kind,
    parent: Ctx,
    start_ms: u64,
    dur_ms: u64,
    attrs: &[(&'static str, Val)],
    status: &'static str,
) {
    if enabled() {
        push(render(
            parent.trace,
            context::new_span_id(),
            parent.as_parent(),
            name,
            kind,
            start_ms,
            dur_ms,
            attrs,
            status,
            None,
        ));
    }
}

/// Render one span exactly as `traces.py` reads it: `t/s/p/n/kd/st/d/h/k/a`.
///
/// WRITTEN BY HAND rather than through `serde_json::Value`, and the reason is
/// measured: the `Value` version cost **8.3 us** per span in the release
/// profile — a `BTreeMap` of eleven `String` keys, built and then walked again
/// by the serializer — against 0.6 us for this. Neither number would hurt a
/// station (spans are per session, never per frame), but a telemetry plane that
/// is fourteen times more expensive than it needs to be is the kind of thing
/// that later gets used as the argument for turning telemetry off.
///
/// The schema is fixed and every key is a literal, so there is no map to build;
/// only string VALUES can contain anything surprising, and `push_str_json`
/// escapes them.
#[allow(clippy::too_many_arguments)]
fn render(
    trace: u128,
    id: u64,
    parent: Option<u64>,
    name: &'static str,
    kind: Kind,
    start_ms: u64,
    dur_ms: u64,
    attrs: &[(&'static str, Val)],
    status: &'static str,
    msg: Option<&str>,
) -> String {
    use std::fmt::Write as _;
    let mut o = String::with_capacity(256);
    let _ = write!(o, "{{\"t\":\"{trace:032x}\",\"s\":\"{id:016x}\"");
    if let Some(p) = parent {
        let _ = write!(o, ",\"p\":\"{p:016x}\"");
    }
    o.push_str(",\"n\":\"");
    o.push_str(name);
    o.push_str("\",\"kd\":\"");
    o.push_str(kind.as_str());
    let _ = write!(
        o,
        "\",\"st\":{start_ms},\"d\":{dur_ms},\"h\":0,\"k\":\"{status}\""
    );
    if let Some(m) = msg {
        o.push_str(",\"m\":");
        push_str_json(&mut o, m);
    }
    // Every span carries its station. `traces.py` has no per-resource column
    // for it, and a flame graph that cannot say WHICH of 61 machines was asleep
    // is not an answer.
    o.push_str(",\"a\":{\"kh.station\":");
    push_str_json(&mut o, station());
    for (k, v) in attrs.iter().take(ATTR_MAX) {
        o.push(',');
        push_str_json(&mut o, k);
        o.push(':');
        match v {
            Val::S(x) => push_str_json(&mut o, x),
            Val::I(x) => {
                let _ = write!(o, "{x}");
            }
            Val::B(x) => o.push_str(if *x { "true" } else { "false" }),
            // A non-finite float is not JSON. Emitting `null` would be a
            // silently-dropped attribute at intake, so it becomes 0 and the
            // caller's own units say what that means.
            Val::F(x) => {
                let _ = write!(o, "{}", if x.is_finite() { *x } else { 0.0 });
            }
        }
    }
    o.push_str("}}");
    o
}

/// A JSON string literal. Escapes what RFC 8259 requires and nothing else;
/// non-ASCII passes through as UTF-8, which every JSON parser accepts.
fn push_str_json(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn push(rendered: String) {
    let Ok(mut buf) = BUF.lock() else {
        // A poisoned buffer means a panic while holding it. Losing spans is the
        // correct response; taking the station down over telemetry is not.
        DROPPED.fetch_add(1, Ordering::Relaxed);
        return;
    };
    if buf.len() >= BUF_MAX {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        return;
    }
    buf.push(rendered);
}

/// Take everything buffered. Public for the tests and for the shutdown flush.
pub fn drain() -> Vec<String> {
    match BUF.lock() {
        Ok(mut b) => std::mem::take(&mut *b),
        Err(_) => Vec::new(),
    }
}

// ---------------------------------------------------------------------------
// Flush
// ---------------------------------------------------------------------------

/// Write whatever is buffered as one `POST /traces` body. Best effort by
/// design: a full disk, a read-only mount or a missing directory loses spans
/// and returns — the exhibit never degrades because telemetry could not be
/// written (contract §7).
pub fn flush_now(tile: &str) {
    let spans = drain();
    if spans.is_empty() {
        return;
    }
    let dir = spool::spool_dir(tile);
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    match spool::write_batch(&dir, seq, &spool::batch(&spans)) {
        Ok(_) => spool::prune(&dir, env_u64("SH_TRACE_SPOOL_MAX", 200) as usize),
        Err(e) => eprintln!("[trace] spool write to {} failed: {e}", dir.display()),
    }
}

/// Install the plane: remember the station name and start the periodic flush.
///
/// Called from `main` next to `probes::spawn`. The SHUTDOWN flush is NOT a
/// second signal handler — `probes::spawn` already owns SIGTERM/SIGINT and the
/// exit disposition that `streamhost@.service`'s `Restart=on-failure` depends
/// on, and a second handler racing it would sometimes lose the last batch and
/// sometimes change how systemd reads the stop. It calls `flush_now` for us.
pub fn init(tile: &str) {
    let _ = STATION.set(tile.to_string());
    if !enabled() {
        eprintln!("[trace] spans OFF (SH_TRACE=off)");
        return;
    }
    let dir = spool::spool_dir(tile);
    let every = env_u64("SH_TRACE_FLUSH_SECS", 30).max(1);
    eprintln!(
        "[trace] spans -> {}/ every {every}s (+ on SIGTERM/SIGINT)",
        dir.display()
    );
    let tile = tile.to_string();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(every));
        loop {
            tick.tick().await;
            flush_now(&tile);
            let d = DROPPED.swap(0, Ordering::Relaxed);
            if d > 0 {
                eprintln!("[trace] dropped {d} spans (buffer full)");
            }
        }
    });
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
