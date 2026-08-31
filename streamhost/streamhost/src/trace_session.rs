//! The per-session spans: one visitor's arrival, told as transitions.
//!
//! WHY THIS IS A SEPARATE MODULE. `transport/mod.rs` is the session core and is
//! close to its 800-line hard cap; `input.rs` and `config/mod.rs` are AT it.
//! Instrumentation that needed to grow those files would either breach
//! `check-file-size` or be silenced with a `size-exclusions.json` entry, which
//! AGENTS.md rule 10 forbids. So the state machine lives here and the call sites
//! are one line each.
//!
//! THE MARKS ARE ONE-SHOT, AND THAT IS THE DESIGN. Every `mark_*` below is an
//! `AtomicBool::swap` guarded by the plane's enable flag: the FIRST frame, the
//! FIRST keyframe, the FIRST byte on the wire, the FIRST input edge. A second
//! frame costs one relaxed load and returns. This is the rule from
//! `trace/mod.rs` made mechanical — at 60 fps a per-frame span would be 3600
//! spans a minute per station, and per-frame data is already counted in
//! `probes.rs` and the ABR reports.
//!
//! WHAT EACH SPAN DECIDES, because a span nobody would act on is a span not
//! worth its bytes:
//!
//! | span | the question it settles |
//! |---|---|
//! | `streamhost.session` | how long this visitor's session lasted, on which transport, and whether the daemon's half joined the browser's trace at all |
//! | `guest.resume` | *was it slow because the machine was asleep* — the whole reason the emulator layer is traced from outside (contract §5) |
//! | `capture.first_frame` | how long after the session opened the guest produced a frame this daemon could see |
//! | `encode.first_key` | how much of that wait was the forced IDR the join gate needs, rather than the guest |
//! | `transport.first_frame` | when a byte of video actually reached the wire — the daemon's twin of the browser's `station.open.toFirstFrameMs` |
//! | `input.first_edge` | when the visitor's first click or key reached the guest, on which backend |
//!
//! All six are measured from the session's own start, so they nest and can be
//! read side by side in one flame graph: `capture.first_frame` shorter than
//! `transport.first_frame` is egress; `guest.resume` dominating both is a guest
//! that was idle-paused, and no other layer can say that.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use crate::trace::{self, Ctx, Kind, Span, Val};

/// A live session's tracing state. Cheap to clone (it is held behind an `Arc`
/// by every task in the session) and inert when the plane is off.
pub struct SessionTrace {
    on: bool,
    ctx: Ctx,
    start: Instant,
    start_ms: u64,
    first_au: AtomicBool,
    first_key: AtomicBool,
    first_send: AtomicBool,
    first_input: AtomicBool,
}

/// Open a session's root span.
///
/// `parent` is whatever `trace::context::from_wt_path` made of the session's
/// `:path` — `Some` when the serving plane appended a `traceparent`, `None`
/// otherwise, in which case this is a ROOT and the daemon's half of the visit
/// is a trace of its own. `kh.trace.joined` records which happened, so a
/// disconnected trace is a fact in the data rather than something to infer from
/// a missing edge.
pub fn begin(
    parent: Option<Ctx>,
    transport: &'static str,
    capture_backend: &'static str,
    input_backend: &'static str,
) -> (Arc<SessionTrace>, Span) {
    let joined = parent.is_some();
    let mut span = match parent {
        Some(p) => Span::child("streamhost.session", Kind::Server, p),
        None => Span::root("streamhost.session", Kind::Server),
    };
    span.attr("kh.transport", transport)
        .attr("kh.capture.backend", capture_backend)
        .attr("kh.input.backend", input_backend)
        .attr("kh.trace.joined", joined);
    let st = Arc::new(SessionTrace {
        on: trace::enabled(),
        ctx: span.ctx(),
        start: Instant::now(),
        start_ms: trace::now_unix_ms(),
        first_au: AtomicBool::new(false),
        first_key: AtomicBool::new(false),
        first_send: AtomicBool::new(false),
        first_input: AtomicBool::new(false),
    });
    (st, span)
}

impl SessionTrace {
    pub fn ctx(&self) -> Ctx {
        self.ctx
    }

    /// Emit a child span running from the session's start to now. Every mark
    /// below is "how long after this visitor arrived did X first happen", which
    /// is the only framing in which the four stages are comparable.
    fn since_start(&self, name: &'static str, attrs: &[(&'static str, Val)]) {
        trace::emit_at(
            name,
            Kind::Internal,
            self.ctx,
            self.start_ms,
            self.start.elapsed().as_millis() as u64,
            attrs,
            "ok",
        );
    }

    /// A one-shot gate. One relaxed load on the second and every later call —
    /// this is what makes it safe to put on the encoder relay and the datagram
    /// loop.
    fn once(&self, flag: &AtomicBool) -> bool {
        self.on && !flag.swap(true, Ordering::Relaxed)
    }

    /// The first access unit this session saw from the encoder: the guest
    /// painted and the daemon captured and encoded it.
    pub fn mark_first_au(&self, frame_id: u32, is_key: bool) {
        if self.once(&self.first_au) {
            self.since_start(
                "capture.first_frame",
                &[
                    ("kh.frame.id", Val::I(frame_id as i64)),
                    ("kh.frame.key", Val::B(is_key)),
                ],
            );
        }
        if is_key && self.once(&self.first_key) {
            self.since_start(
                "encode.first_key",
                &[("kh.frame.id", Val::I(frame_id as i64))],
            );
        }
    }

    /// The first access unit successfully handed to a QUIC uni-stream.
    pub fn mark_first_send(&self, bytes: usize) {
        if self.once(&self.first_send) {
            self.since_start(
                "transport.first_frame",
                &[("kh.frame.bytes", Val::I(bytes as i64))],
            );
        }
    }

    /// The first input record dispatched at the guest on this session.
    ///
    /// `class` names the wire class (`datagram`, `keyboard`, `mouse-button`,
    /// `wheel`, `urgent-control`), never the payload: no keycode, no
    /// coordinate, no typed text (contract §7).
    pub fn mark_first_input(&self, class: &'static str) {
        if self.once(&self.first_input) {
            self.since_start(
                "input.first_edge",
                &[("kh.input.class", Val::S(class.into()))],
            );
        }
    }
}

/// `guest.resume` — the emulator span that matters most.
///
/// Wraps the `cont` (QEMU QMP) or `SIGCONT` (emulator-process stations) that
/// `IdlePauser::session_started` issues on every accepted session. `was_paused`
/// is the daemon's own belief read before the call, which is the only honest
/// source: the guest cannot be asked, and a resume on a running guest is
/// idempotent and fast, so without this attribute every session would show a
/// `guest.resume` and none of them would mean anything.
pub async fn guest_resume<F: std::future::Future<Output = ()>>(
    parent: Ctx,
    was_paused: bool,
    freezer: &'static str,
    f: F,
) {
    let mut span = Span::child("guest.resume", Kind::Internal, parent);
    span.attr("kh.guest.was_paused", was_paused)
        .attr("kh.guest.freezer", freezer)
        .ok();
    f.await;
    span.end();
}
