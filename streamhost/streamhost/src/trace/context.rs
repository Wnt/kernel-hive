//! W3C trace context, and where it enters the daemon.
//!
//! THE CONTRACT is `docs/lab/TRACE-CONTEXT.md`. §1 fixes the wire format as
//! `traceparent`; §3 explains why the daemon cannot receive it in a header and
//! must take it off the thing the browser already exchanges. This module is the
//! Rust half of `scripts/serve/tracecontext.py` and follows its one behavioural
//! rule exactly: **a malformed context starts a NEW trace and never fails the
//! work**. Every function here returns `Option` and none of them can panic on
//! input from the open internet.
//!
//! HOW THE ID REACHES US. The input plane is raw WebTransport straight to this
//! daemon's QUIC listener: no headers, no cookies, nothing but the `:path` the
//! browser opened the session with. That path is already carrying per-session
//! material — the HMAC ticket `session_ticket.rs` verifies — and it is already
//! specified to tolerate a query string ("a cache-buster appended by some
//! middlebox must not invalidate the session": `verify()` splits on `?` before
//! it touches the ticket). So the trace id rides there:
//!
//! ```text
//!   /wt/<exp>.<nonce>.<sig>?traceparent=00-<32 hex>-<16 hex>-01
//! ```
//!
//! The signature covers `v1|<tile>|<exp>|<nonce>` and NOT the query, so adding
//! this neither invalidates a ticket nor lets the query forge one — the worst a
//! tamperer achieves is attaching their own session to a trace id they chose,
//! which is a telemetry lie, not an authorisation one. And the reverse holds,
//! which is the rule that matters: the ticket carries the trace id, the trace
//! never carries the ticket (contract §7). Nothing in this module ever copies
//! the path, the nonce or the signature into a span.
//!
//! WHEN IT IS ABSENT — today, on every station, because the serving plane does
//! not append it yet — `from_wt_path` returns `None` and the session's span
//! becomes a ROOT. An unjoined trace is useful; a fabricated parent is not.
//! There is deliberately no fallback that invents a parent from a timestamp or
//! from the station id.

use std::sync::atomic::{AtomicU64, Ordering};

/// The query parameter that carries `traceparent` on the WebTransport path.
/// Spelled exactly like the header so a reader of either plane recognises it.
pub const QUERY_KEY: &str = "traceparent";

/// An inbound parent. Immutable; there is nothing to mutate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ctx {
    pub trace: u128,
    pub span: u64,
    pub sampled: bool,
}

impl Ctx {
    /// A fresh root context — a trace id nobody handed us, and no parent.
    pub fn root() -> Self {
        Self {
            trace: new_trace_id(),
            span: 0,
            sampled: true,
        }
    }

    /// The span id to record as a child's `p`. `0` is "no parent" (a root),
    /// which must be OMITTED rather than sent as null or as a zero id:
    /// `traces.py::_resummarise` finds a trace's root by looking for exactly
    /// the absence of this field.
    pub fn as_parent(self) -> Option<u64> {
        (self.span != 0).then_some(self.span)
    }
}

/// Parse a `traceparent` value. `None` means START A NEW TRACE — it never means
/// refuse the work, and no input to this function panics.
///
/// Mirrors `tracecontext.py::parse` including its two spec rules: version `ff`
/// is forbidden, and an all-zero id is the spec's own spelling of "invalid".
/// The version field is parsed permissively (a future version must still yield
/// its first two fields) and only `ff` is rejected.
pub fn parse_traceparent(raw: &str) -> Option<Ctx> {
    let s = raw.trim();
    let mut it = s.split('-');
    let (ver, trace, span, flags) = match (it.next(), it.next(), it.next(), it.next(), it.next()) {
        (Some(v), Some(t), Some(s), Some(f), None) => (v, t, s, f),
        _ => return None,
    };
    if ver.len() != 2 || trace.len() != 32 || span.len() != 16 || flags.len() != 2 {
        return None;
    }
    if !s.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-') {
        return None;
    }
    // Lowercase only: the spec says so, and accepting mixed case here would make
    // this parser disagree with the Python one about what a valid header is.
    if s.bytes().any(|c| c.is_ascii_uppercase()) {
        return None;
    }
    if ver == "ff" {
        return None;
    }
    let trace = u128::from_str_radix(trace, 16).ok()?;
    let span = u64::from_str_radix(span, 16).ok()?;
    let flags = u8::from_str_radix(flags, 16).ok()?;
    if trace == 0 || span == 0 {
        return None;
    }
    Some(Ctx {
        trace,
        span,
        sampled: flags & 0x01 != 0,
    })
}

/// The parent carried on a WebTransport session's `:path`, if any.
///
/// Takes only the query; the ticket half of the path is never read here and is
/// never returned. A repeated key takes the FIRST value, matching how every
/// query parser this lab talks to behaves.
pub fn from_wt_path(path: &str) -> Option<Ctx> {
    let query = path.split_once('?')?.1;
    for pair in query.split('&') {
        // A pair with no `=` is not ours; skip it rather than abandoning the
        // scan, or one stray flag ahead of us hides the context behind it.
        let Some((k, v)) = pair.split_once('=') else {
            continue;
        };
        if k == QUERY_KEY {
            return parse_traceparent(v);
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Id minting
// ---------------------------------------------------------------------------

/// Ids need to be UNIQUE, not unpredictable — they identify a span, they do not
/// authorise anything, and contract §7 keeps every secret out of a span in the
/// first place. So this is a SplitMix64 over (monotonic-ish nanos, pid, a
/// process counter) rather than a CSPRNG dependency: no new crate, no syscall
/// beyond the clock read, and no `/dev/urandom` open on a path that must not
/// block. Collision risk across 61 stations emitting a few spans a session is
/// not a number worth writing down.
static SEQ: AtomicU64 = AtomicU64::new(0);

fn splitmix64(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

fn rand64() -> u64 {
    let n = SEQ.fetch_add(1, Ordering::Relaxed);
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    splitmix64(t ^ n.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ ((std::process::id() as u64) << 32))
}

/// 128-bit, never zero (an all-zero trace id is "invalid" to every consumer).
pub fn new_trace_id() -> u128 {
    let v = ((rand64() as u128) << 64) | rand64() as u128;
    if v == 0 {
        1
    } else {
        v
    }
}

/// 64-bit, never zero (same reason, and `Ctx::as_parent` reads 0 as "no parent").
pub fn new_span_id() -> u64 {
    let v = rand64();
    if v == 0 {
        1
    } else {
        v
    }
}
