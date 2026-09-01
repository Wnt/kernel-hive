//! Logs — the daemon's third signal, on the same carrier as its spans.
//!
//! WHY THIS EXISTS. The daemon printed 747 000 lines and 62 MB a day across 71
//! units into journald and nowhere else. None of it was queryable off the box,
//! none of it was joinable to a span, and `journalctl -u streamhost@<tile>` is
//! not an answer to "what did the daemon say *during* that slow
//! `guest.resume`" — you have to know which station, guess the window, and
//! read by eye. A log record carrying this process's own `trace_id`/`span_id`
//! turns that into one query, on our plane and in Instana alike.
//!
//! WHAT IT IS NOT. It is not a replacement for `eprintln!`. **Every line still
//! goes to stderr and therefore to journald, exactly as before** — see
//! `sh_log!`. journald keeps the full firehose with its own rotation and costs
//! us nothing; this lane carries the fraction worth storing for a week and
//! joining to a trace. So a failure of the spool, the shipper or the collector
//! costs queryability and never the line.
//!
//! THE DEFAULT IS WARN, and that is a disk decision, not a taste one. At the
//! measured 747k lines/day the fleet's INFO firehose would be ~90 MB/day in
//! sqlite and ~630 MB at the store's 7-day retention, on one box, to duplicate
//! what journald already holds. `SH_LOG_LEVEL=info|debug|trace` raises it for a
//! station under investigation, which is when you want it and the only time the
//! volume is worth paying for.
//!
//! CARRIER, NOT A SECOND TRANSPORT. Same spool directory idiom, same
//! tmp+rename, same lexical prune, same shipper (`trace-ship.py`) as the span
//! spool — for the three reasons `spool.rs` gives, which have not changed: the
//! exhibit outranks the telemetry, this binary has no HTTP client, and the file
//! IS the request body (`POST /logs`, verbatim).
//!
//! NEVER A SECRET IN A LOG (contract §7), the same rule spans are held to. The
//! ticket, the nonce, the signature and the HMAC key are never a body or an
//! attribute here, and `sh_log!` takes a formatted message from the call site —
//! so the rule is enforced at the call site, exactly as `eprintln!` already
//! required.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use super::types::Val;
use super::{env_u64, now_unix_ms, push_str_json, spool, Ctx};

/// OTel severity, the four levels the store promises plus the two ends. The
/// numbers are OTel `SeverityNumber`s and they are what `logs.py` stores and
/// what Instana falls back to when the text is unrecognised.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Trace = 1,
    Debug = 5,
    Info = 9,
    Warn = 13,
    Error = 17,
    Fatal = 21,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Trace => "TRACE",
            Level::Debug => "DEBUG",
            Level::Info => "INFO",
            Level::Warn => "WARN",
            Level::Error => "ERROR",
            Level::Fatal => "FATAL",
        }
    }
}

static MIN: OnceLock<Level> = OnceLock::new();
/// Rendered records awaiting a flush. Separate from the span buffer on purpose:
/// a log flood must not evict spans, which are per-session one-offs and cannot
/// be re-derived, while a dropped log line is still in journald.
static BUF: Mutex<Vec<String>> = Mutex::new(Vec::new());
static DROPPED: AtomicU64 = AtomicU64::new(0);
static SEQ: AtomicU64 = AtomicU64::new(0);

/// Buffered-record ceiling. Deliberately smaller than the span buffer's 4096:
/// records are longer (a body plus attributes rather than a fixed field set)
/// and, unlike a span, a dropped one is not lost — it is in journald.
const BUF_MAX: usize = 2048;
const BODY_MAX: usize = 8 * 1024;
const ATTR_MAX: usize = 24;
const ATTR_STR_MAX: usize = 512;

/// The floor, read once. `SH_LOG_LEVEL` unset means WARN — see the module
/// docstring for the disk arithmetic behind that default.
pub fn min_level() -> Level {
    *MIN.get_or_init(|| {
        match std::env::var("SH_LOG_LEVEL")
            .ok()
            .as_deref()
            .map(str::trim)
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("trace") => Level::Trace,
            Some("debug") => Level::Debug,
            Some("info") => Level::Info,
            Some("error") => Level::Error,
            Some("fatal") => Level::Fatal,
            _ => Level::Warn,
        }
    })
}

/// True when a record at this level would be stored. `sh_log!` checks it BEFORE
/// formatting, so a suppressed DEBUG costs one relaxed load and no allocation.
pub fn enabled_at(level: Level) -> bool {
    super::enabled() && level >= min_level()
}

/// Record one log line. `ctx` is the span in scope, and it is what makes this a
/// log *plane* rather than a log file: with it, the record joins to the span in
/// both stores; without it, the record is still stored, still searchable, and
/// honestly uncorrelated rather than carrying an invented id.
pub fn record(level: Level, ctx: Option<Ctx>, body: &str, attrs: &[(&'static str, Val)]) {
    if !enabled_at(level) {
        return;
    }
    push(render(level, ctx, body, attrs));
}

fn render(level: Level, ctx: Option<Ctx>, body: &str, attrs: &[(&'static str, Val)]) -> String {
    // Hand-rolled for the same measured reason the span renderer is: 8.3 us
    // through `serde_json::Value` against 0.6 us here, and this runs on paths a
    // frame budget shares.
    let mut out = String::with_capacity(160 + body.len());
    out.push_str("{\"t\":");
    out.push_str(&now_unix_ms().to_string());
    out.push_str(",\"sv\":\"");
    out.push_str(level.as_str());
    out.push_str("\",\"b\":");
    let trimmed: String = body.chars().take(BODY_MAX).collect();
    push_str_json(&mut out, &trimmed);
    if let Some(c) = ctx {
        out.push_str(",\"tr\":\"");
        out.push_str(&format!("{:032x}", c.trace));
        // A span id of 0 is this plane's spelling of "no parent span", and a
        // zero id in the store would render as a correlation that joins to
        // nothing. Trace-only is the honest record.
        if c.span != 0 {
            out.push_str("\",\"sp\":\"");
            out.push_str(&format!("{:016x}", c.span));
        }
        out.push('"');
    }
    if !attrs.is_empty() {
        out.push_str(",\"a\":{\"kh.station\":");
        push_str_json(&mut out, super::station());
        for (k, v) in attrs.iter().take(ATTR_MAX) {
            out.push(',');
            push_str_json(&mut out, k);
            out.push(':');
            match v {
                Val::S(s) => {
                    let t: String = s.chars().take(ATTR_STR_MAX).collect();
                    push_str_json(&mut out, &t);
                }
                Val::I(i) => out.push_str(&i.to_string()),
                Val::B(b) => out.push_str(if *b { "true" } else { "false" }),
                Val::F(f) => out.push_str(&format!("{f}")),
            }
        }
        out.push('}');
    } else {
        out.push_str(",\"a\":{\"kh.station\":");
        push_str_json(&mut out, super::station());
        out.push('}');
    }
    out.push('}');
    out
}

fn push(rendered: String) {
    let Ok(mut buf) = BUF.lock() else {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        return;
    };
    if buf.len() >= BUF_MAX {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        return;
    }
    buf.push(rendered);
}

/// Take everything buffered. Public for the tests and the shutdown flush.
pub fn drain() -> Vec<String> {
    match BUF.lock() {
        Ok(mut b) => std::mem::take(&mut *b),
        Err(_) => Vec::new(),
    }
}

/// Write whatever is buffered as one `POST /logs` body. Best effort, like the
/// span flush: a full disk loses records and returns, because the exhibit never
/// degrades over telemetry (contract §7) — and the lines are in journald.
pub fn flush_now(tile: &str) {
    let recs = drain();
    if recs.is_empty() {
        return;
    }
    let dir = spool::log_spool_dir(tile);
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    match spool::write_batch(&dir, seq, &spool::log_batch(tile, &recs)) {
        Ok(_) => spool::prune(&dir, env_u64("SH_LOG_SPOOL_MAX", 200) as usize),
        Err(e) => eprintln!("[log] spool write to {} failed: {e}", dir.display()),
    }
    let d = DROPPED.swap(0, Ordering::Relaxed);
    if d > 0 {
        eprintln!("[log] dropped {d} records (buffer full; they are still in journald)");
    }
}

/// One log line: to stderr ALWAYS (journald keeps the firehose), and to the
/// correlated store when the level passes `SH_LOG_LEVEL`.
///
/// ```ignore
/// sh_log!(Level::Warn, Some(ctx), "restore took {ms}ms");
/// sh_log!(Level::Error, Some(ctx), [("guest.state", state)], "resume refused");
/// sh_log!(Level::Info, None, "listening on {port}");
/// ```
///
/// The level test happens before the `format!`, so a suppressed record costs
/// one relaxed load and no allocation — but the `eprintln!` is outside it, so
/// stderr never loses a line to a level setting.
#[macro_export]
macro_rules! sh_log {
    ($level:expr, $ctx:expr, [$($attrs:tt)*], $($arg:tt)*) => {{
        let __msg = format!($($arg)*);
        eprintln!("[{}] {}", $crate::trace::logs::Level::as_str($level), __msg);
        if $crate::trace::logs::enabled_at($level) {
            $crate::trace::logs::record($level, $ctx, &__msg, &[$($attrs)*]);
        }
    }};
    ($level:expr, $ctx:expr, $($arg:tt)*) => {{
        let __msg = format!($($arg)*);
        eprintln!("[{}] {}", $crate::trace::logs::Level::as_str($level), __msg);
        if $crate::trace::logs::enabled_at($level) {
            $crate::trace::logs::record($level, $ctx, &__msg, &[]);
        }
    }};
}
