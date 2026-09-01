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
//!
//! THE RETURN LEG (added 2026-08-31, `docs/lab/TRACE-CONTEXT.md` §3.2/§8.1).
//! `guest.frame.next` / `transport.frame.next` are the daemon's half of what a
//! sampled input caused; they do not say whether the visitor ever SAW it. The
//! browser cannot know which `frame_id` answered its own edge — that fact only
//! exists here, in `PendingEffect` — so `effect_sent` hands its `Ctx` back to
//! `transport/mod.rs`, which mints a tiny out-of-band WIRE message (KIND_PARAMS
//! subtype 3, `transport/egress.rs::spawn_frame_mark`) naming `frame_id` and
//! the trace/span to answer with. The browser
//! (`three/streamClient/frameTrace.ts`) matches that id against its OWN local
//! receive/decode/paint timestamps for the same `frame_id` — by EXPLICIT id,
//! never by "the next frame I happened to paint" — and closes the loop with
//! `client.frame.receive` / `client.frame.decode` / `client.frame.paint`,
//! siblings of `guest.frame.next` / `transport.frame.next` under the same
//! `input.dispatch`. `kh.encode.latency_us` on `guest.frame.next` (from
//! `Au::encode_us`) is the fourth stage the return leg's own span tree does not
//! need a dedicated span for — it was `worker.rs`'s journal-only "snap->AU"
//! number, now riding the AU into a span attribute instead.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::trace::{self, Ctx, Kind, Span, Val};

/// A SAMPLED input edge awaiting the effect it caused: the next frame the
/// guest produces after it was injected. Set by `note_sampled_input` (the
/// per-type reliable-input drain, once per ~1-in-N edge — see
/// `input_trace.rs`) and consumed by the encoder relay the next time it sees
/// an access unit (`effect_encoded` / `effect_sent` in `transport/mod.rs`).
/// `Copy`: cloning it out of the mutex is cheaper than holding the lock across
/// the span emission below.
#[derive(Clone, Copy)]
struct PendingEffect {
    /// Parent for the effect spans: NOT the browser's own root, but the
    /// daemon's `input.dispatch` span for this edge, so the chain in a flame
    /// graph reads input -> dispatch -> effect rather than three siblings
    /// under the browser root.
    ctx: Ctx,
    injected: Instant,
    injected_ms: u64,
    input_class: &'static str,
    key_class: Option<&'static str>,
}

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
    /// Relaxed-load gate so the 60 fps encoder relay pays one atomic read per
    /// frame when nothing is pending — the same shape as `once()` below, and
    /// necessary for the SAME reason: at 60 fps anything more on that path is
    /// a frame budget this daemon does not have to spend.
    effect_pending: AtomicBool,
    effect: Mutex<Option<PendingEffect>>,
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
        effect_pending: AtomicBool::new(false),
        effect: Mutex::new(None),
    });
    (st, span)
}

/// The entry span's name for one input class.
///
/// `&'static str` and an exhaustive match rather than a formatted string: a
/// span name is an endpoint identity in every consumer downstream, and an
/// allocated name is one typo away from an unbounded set of endpoints. An
/// unrecognised class falls back to the bare name rather than inventing a row.
/// The vocabulary matches the browser's `kh.input.class`
/// (`three/streamClient/inputWire.ts`) exactly, which is what keeps the two
/// ends from disagreeing about what a word means.
fn dispatch_span_name(input_class: &str) -> &'static str {
    match input_class {
        "key" => "input.dispatch.key",
        "click" => "input.dispatch.click",
        _ => "input.dispatch",
    }
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

    /// Open the daemon-side span for a SAMPLED input edge — the browser
    /// carried a context in the record (`input_trace.rs`), so this is a real
    /// child, not a root. Covers "the sink accepted the record" through "the
    /// guest write returned": `input.rs` cannot be instrumented internally
    /// without breaching its own file-size hard cap (it sits AT 800 lines, see
    /// this file's header), so the boundary this daemon can afford is the
    /// whole `input::handle` call, named for what happens either side of it.
    /// Ends the span and, if it emitted, arms the pending effect so the NEXT
    /// frame this session produces can be tied back to this edge.
    pub async fn dispatch_sampled_input<F: std::future::Future<Output = ()>>(
        &self,
        ctx: Ctx,
        input_class: &'static str,
        key_class: Option<&'static str>,
        f: F,
    ) {
        // Kind::Server, not Internal — this IS the daemon's receiving side of
        // the browser's `input.edge` CLIENT span (`three/streamClient/
        // inputTrace.ts`'s `startTrace(name, attrs, 'client')`), the same RPC
        // client/server pairing this codebase already uses for
        // `http.client.request` / `serve.signal`. Verified live 2026-08-31
        // (`scripts/observability/instana-forward.py --once` + the analyze/
        // traces API): every `serve.*` trace, which HAS a Server-kind entry
        // span, carries a real `service.name`; every `input.edge` trace,
        // whose only spans were Client (the browser root) and Internal (this
        // span and its children), came back service `"Unspecified"` — Instana
        // derives a trace's owning service from its ENTRY span, and a trace
        // with no Server-kind span anywhere in it has no entry. Internal
        // understated what this span actually is: it does not merely happen
        // during the session, it is the request/response boundary itself, so
        // marking it Server is a correction, not a vendor accommodation — the
        // same "do not relabel a UI span as a server span" rule this repo
        // already states cuts the other way here, since this span already
        // was the server side of a real client/server exchange.
        //
        // AND THE NAME CARRIES THE CLASS. Instana derives an OTLP trace's
        // ENDPOINT from its entry span's name — the `{otel.operation}` rule in
        // its predefined endpoint mapping (instana-docs/
        // 0251-monitoring-applications.md, "Endpoints -> Predefined rules"), so
        // one name means one endpoint row for every input a visitor ever makes.
        // A keyboard round trip and a mouse round trip have genuinely different
        // shapes — different guest work, different damage, different latency
        // distributions — and folding them into one row hides both. The class
        // stays an attribute as well, because a NAME cannot be grouped away
        // when somebody does want the whole input plane at once.
        let name = dispatch_span_name(input_class);
        let mut span = Span::child(name, Kind::Server, ctx);
        span.attr("kh.input.class", input_class);
        if let Some(kc) = key_class {
            span.attr("kh.key.class", kc);
        }
        let effect_ctx = span.ctx();
        f.await;
        span.ok();
        let injected = Instant::now();
        let injected_ms = trace::now_unix_ms();
        span.end();
        if !self.on {
            return;
        }
        *self.effect.lock().unwrap_or_else(|e| e.into_inner()) = Some(PendingEffect {
            ctx: effect_ctx,
            injected,
            injected_ms,
            input_class,
            key_class,
        });
        self.effect_pending.store(true, Ordering::Relaxed);
    }

    /// Called from the encoder relay for every access unit (`transport/mod.rs`,
    /// beside `mark_first_au`): the guest produced a frame — was it the EFFECT
    /// of a pending sampled input? One relaxed load when nothing is pending,
    /// which is every frame at the default N=10 sample rate unless a visitor
    /// is typing or clicking right now. PEEKS rather than takes: `effect_sent`
    /// below is what actually closes the window, so a burst of AUs between
    /// capture and this edge's own transport send does not re-open it.
    ///
    /// `encode_us` is `Au::encode_us` — the snapshot->AU-ready latency
    /// `worker.rs` used to leave only in a journal `[encode] enc latency`
    /// line. Attached HERE rather than as its own span: this fires once per
    /// sampled edge already (never per frame — `trace/mod.rs`'s cost rule),
    /// so promoting the number costs one more attribute on a span that was
    /// going to exist anyway, not a fourth span this pair never needed.
    pub fn effect_encoded(&self, frame_id: u32, is_key: bool, encode_us: u32) {
        if !self.effect_pending.load(Ordering::Relaxed) {
            return;
        }
        let Some(pe) = *self.effect.lock().unwrap_or_else(|e| e.into_inner()) else {
            return;
        };
        trace::emit_at(
            "guest.frame.next",
            Kind::Internal,
            pe.ctx,
            pe.injected_ms,
            pe.injected.elapsed().as_millis() as u64,
            &effect_attrs(
                &pe,
                &[
                    ("kh.frame.id", Val::I(frame_id as i64)),
                    ("kh.frame.key", Val::B(is_key)),
                    ("kh.encode.latency_us", Val::I(encode_us as i64)),
                ],
            ),
            "ok",
        );
    }

    /// The same edge's frame reaching the wire — closes the window. Two
    /// spans, not one, so a flame graph can show whether a slow effect was
    /// encode/capture-bound or transport-bound, mirroring the session-level
    /// `capture.first_frame` / `transport.first_frame` split above.
    ///
    /// Returns the closed effect's `Ctx` when this call actually consumed a
    /// pending edge — the caller (`transport/mod.rs`'s egress loop) uses it to
    /// tell the CLIENT which trace/span this frame_id answers (the KIND_PARAMS
    /// subtype-3 frame-trace mark, `transport/egress.rs::spawn_frame_mark`),
    /// closing the loop this module's doc comment describes as daemon-only.
    /// `None` on every unsampled frame (the load above still returns before
    /// the lock), so the 9-in-10 default case pays nothing more than before.
    pub fn effect_sent(&self, frame_id: u32, bytes: usize) -> Option<Ctx> {
        if !self.effect_pending.load(Ordering::Relaxed) {
            return None;
        }
        let taken = self.effect.lock().unwrap_or_else(|e| e.into_inner()).take();
        self.effect_pending.store(false, Ordering::Relaxed);
        let pe = taken?;
        trace::emit_at(
            "transport.frame.next",
            Kind::Internal,
            pe.ctx,
            pe.injected_ms,
            pe.injected.elapsed().as_millis() as u64,
            &effect_attrs(
                &pe,
                &[
                    ("kh.frame.id", Val::I(frame_id as i64)),
                    ("kh.frame.bytes", Val::I(bytes as i64)),
                ],
            ),
            "ok",
        );
        Some(pe.ctx)
    }
}

/// `kh.input.class` (+ `kh.key.class` when this was a key) beside whatever the
/// caller already has, so both effect spans carry the same "what caused this"
/// attributes without duplicating the plumbing.
fn effect_attrs(pe: &PendingEffect, extra: &[(&'static str, Val)]) -> Vec<(&'static str, Val)> {
    let mut attrs: Vec<(&'static str, Val)> =
        vec![("kh.input.class", Val::S(pe.input_class.into()))];
    if let Some(kc) = pe.key_class {
        attrs.push(("kh.key.class", Val::S(kc.into())));
    }
    attrs.extend(extra.iter().cloned());
    attrs
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
