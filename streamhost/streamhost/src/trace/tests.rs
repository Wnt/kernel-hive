//! The trace plane's gates and its measured cost.
//!
//! Two kinds of test live here, and the split is deliberate. The PARSER tests
//! are the contract (`docs/lab/TRACE-CONTEXT.md` §1) restated as assertions, so
//! this parser and `scripts/serve/tracecontext.py` cannot drift into two
//! opinions about what a valid `traceparent` is. The SHAPE tests hold the
//! rendered span to exactly what `scripts/serve/traces.py` accepts, so a field
//! rename on either side fails here rather than being silently dropped at
//! intake — a span the collector discards looks identical to a span that never
//! fired, which is the same ambiguity `probes.rs` built its drift gate against.

use super::context::{from_wt_path, new_span_id, new_trace_id, parse_traceparent};
use super::*;

/// The span buffer is process-global and `cargo test` runs tests in parallel,
/// so the two tests that touch it take this first. Without it the cost bench
/// and the overflow test drain each other's spans and both flake.
static BUF_TEST: std::sync::Mutex<()> = std::sync::Mutex::new(());

const TP: &str = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";

#[test]
fn parses_the_spec_example() {
    let c = parse_traceparent(TP).expect("valid");
    assert_eq!(c.trace, 0x4bf92f3577b34da6a3ce929d0e0e4736);
    assert_eq!(c.span, 0x00f067aa0ba902b7);
    assert!(c.sampled);
}

#[test]
fn unsampled_flag_is_carried_not_dropped() {
    let c = parse_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00").unwrap();
    assert!(!c.sampled);
}

/// Every one of these means START A NEW TRACE. None of them may panic, and none
/// of them may yield a context — a wrong parent draws a causal claim that is
/// false, which contract §7 rates worse than no parent at all.
#[test]
fn refuses_everything_that_is_not_a_traceparent() {
    for bad in [
        "",
        "  ",
        "garbage",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra",
        // version ff is forbidden by the spec
        "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        // all-zero ids are the spec's own spelling of "invalid"
        "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
        // uppercase: lowercase-only, so this parser and the Python one agree
        "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",
        // wrong widths
        "00-4bf92f3577b34da6a3ce929d0e0e47-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902-01",
        "0-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1",
        // non-hex
        "00-zzf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    ] {
        assert!(parse_traceparent(bad).is_none(), "accepted {bad:?}");
    }
}

#[test]
fn takes_the_context_off_a_ticketed_session_path() {
    let p = format!("/wt/1800000100.abc123.SIGNATURE?traceparent={TP}");
    let c = from_wt_path(&p).expect("joined");
    assert_eq!(c.trace, 0x4bf92f3577b34da6a3ce929d0e0e4736);
}

/// A stray flag or an unrelated cache-buster ahead of the context must not hide
/// it, and a path with no query at all must simply yield no parent.
#[test]
fn survives_the_company_it_keeps_in_a_query_string() {
    let p = format!("/wt/1.a.b?cb=1&flag&traceparent={TP}&x=2");
    assert!(from_wt_path(&p).is_some());
    assert!(from_wt_path("/wt/1.a.b").is_none());
    assert!(from_wt_path("/wt/1.a.b?cb=1").is_none());
    assert!(from_wt_path("/wt/1.a.b?traceparent=nonsense").is_none());
}

#[test]
fn ids_are_never_zero_and_do_not_repeat() {
    let mut traces = std::collections::HashSet::new();
    let mut spans = std::collections::HashSet::new();
    for _ in 0..10_000 {
        let t = new_trace_id();
        let s = new_span_id();
        assert_ne!(t, 0);
        assert_ne!(s, 0);
        assert!(traces.insert(t));
        assert!(spans.insert(s));
    }
}

/// THE SHAPE GATE. `traces.py` reads `t/s/p/n/kd/st/d/h/k/a`; anything else it
/// ignores, and a span it cannot read is indistinguishable from one that never
/// fired.
#[test]
fn renders_exactly_what_the_collector_accepts() {
    let parent = parse_traceparent(TP).unwrap();
    let json = render(
        parent.trace,
        0x1122334455667788,
        parent.as_parent(),
        "streamhost.session",
        Kind::Server,
        1_800_000_000_000,
        42,
        &[("kh.transport", Val::S("webtransport".into()))],
        "ok",
        None,
    );
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(v["t"], "4bf92f3577b34da6a3ce929d0e0e4736");
    assert_eq!(v["s"], "1122334455667788");
    assert_eq!(v["p"], "00f067aa0ba902b7");
    assert_eq!(v["n"], "streamhost.session");
    assert_eq!(v["kd"], "server");
    assert_eq!(v["st"], 1_800_000_000_000u64);
    assert_eq!(v["d"], 42);
    assert_eq!(v["h"], 0);
    assert_eq!(v["k"], "ok");
    assert_eq!(v["a"]["kh.transport"], "webtransport");
    // Every span names its station: `traces.py` has no resource column for it
    // and a flame graph that cannot say WHICH of 61 machines was asleep is not
    // an answer.
    assert!(v["a"]["kh.station"].is_string());
}

/// A root span carries no `p`. `_resummarise` finds the trace's root by looking
/// for exactly that, so emitting `"p": null` or a zero id would make every
/// daemon trace rootless.
#[test]
fn a_root_span_has_no_parent_field() {
    let json = render(
        Ctx::root().trace,
        new_span_id(),
        Ctx::root().as_parent(),
        "streamhost.start",
        Kind::Internal,
        1,
        0,
        &[],
        "unset",
        None,
    );
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert!(v.get("p").is_none());
}

/// The bug this test exists for: folding "my id" and "my parent's id" into one
/// `Ctx` made every span its own parent, which renders as a trace with no root
/// and no edges — and looks perfectly well-formed until you open the flame
/// graph.
#[test]
fn a_child_span_points_at_its_parent_not_at_itself() {
    let parent = parse_traceparent(TP).unwrap();
    let s = Span::child("guest.resume", Kind::Internal, parent);
    let child = Span::child("input.first_edge", Kind::Internal, s.ctx());
    assert_eq!(s.parent, Some(parent.span));
    assert_ne!(s.parent, Some(s.id));
    assert_eq!(child.parent, Some(s.id));
    assert_eq!(child.trace, parent.trace);
    let _g = BUF_TEST.lock().unwrap_or_else(|e| e.into_inner());
    s.end();
    child.end();
    drain();
}

/// Names must satisfy `traces.py::NAME_RE`. Checked for the literal set this
/// daemon emits, so a rename that the collector would silently refuse fails
/// here instead.
#[test]
fn every_span_name_is_one_the_collector_will_store() {
    for n in [
        "streamhost.start",
        "streamhost.session",
        "guest.launch",
        "guest.attach",
        "guest.first_frame",
        "guest.resume",
        "capture.first_frame",
        "encode.first_key",
        "transport.first_frame",
        "transport.webrtc_fallback",
        "input.first_edge",
    ] {
        let b = n.as_bytes();
        assert!(b[0].is_ascii_alphabetic(), "{n}");
        assert!(n.len() <= 80, "{n}");
        assert!(
            b.iter()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-')),
            "{n}"
        );
    }
}

/// The renderer is hand-written (see `render`), so the escaping it does is
/// load-bearing in a way `serde_json`'s was not: one unescaped quote makes the
/// whole BATCH unparseable and loses every span in it, not just the bad one.
#[test]
fn a_hostile_attribute_value_cannot_break_the_json() {
    let mut sp = Span::start_on(true, "guest.resume", Kind::Internal, Ctx::root());
    sp.attr("kh.input.class", "a\"b\\c\nd\te\u{1}f\u{e9}g");
    let json = render(
        1,
        2,
        None,
        "guest.resume",
        Kind::Internal,
        1,
        0,
        &sp.attrs,
        "ok",
        Some("quote\" and backslash\\"),
    );
    let v: serde_json::Value = serde_json::from_str(&json).expect("parseable");
    assert_eq!(v["a"]["kh.input.class"], "a\"b\\c\nd\te\u{1}f\u{e9}g");
    assert_eq!(v["m"], "quote\" and backslash\\");
}

/// Attributes are capped at the emitter, not at the collector. A span truncated
/// server-side loses the attribute the caller thought it sent, silently.
#[test]
fn attributes_are_capped_and_strings_truncated() {
    let mut s = Span::root("guest.resume", Kind::Internal);
    for _ in 0..40 {
        s.attr("kh.x", 1u64);
    }
    assert!(s.attrs.len() <= ATTR_MAX);
    let mut s2 = Span::root("guest.resume", Kind::Internal);
    s2.attr("kh.long", "x".repeat(500));
    match &s2.attrs[0].1 {
        Val::S(v) => assert_eq!(v.len(), ATTR_STR_MAX),
        other => panic!("{other:?}"),
    }
}

/// The batch file IS the `POST /traces` request body — that is the whole
/// argument for spooling files instead of adding an HTTP+TLS client to a daemon
/// that carries neither. If this shape drifts the shipper becomes a translator.
#[test]
fn a_batch_is_a_post_traces_body() {
    let body = super::spool::batch(&[r#"{"n":"a"}"#.to_string(), r#"{"n":"b"}"#.to_string()]);
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["resource"]["session.id"], "unknown");
    assert_eq!(v["resource"]["kh.class"], "unknown");
    assert_eq!(v["spans"].as_array().unwrap().len(), 2);
}

/// The spool is the whole collection path, so its two failure behaviours are
/// worth a test each: a reader must never see a half-written file, and a
/// station whose collector never runs must lose its OLDEST spans rather than
/// fill `/data` (contract §7 — the exhibit outranks the telemetry).
#[test]
fn the_spool_writes_whole_files_and_bounds_itself() {
    let dir = std::env::temp_dir().join(format!("kh-trace-spool-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    for i in 0..5u64 {
        let p = super::spool::write_batch(&dir, i, &super::spool::batch(&[r#"{"n":"a"}"#.into()]))
            .expect("write");
        // Renamed into place, never left as a .tmp a reader could pick up.
        assert_eq!(p.extension().unwrap(), "json");
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(v["spans"].as_array().unwrap().len(), 1);
    }
    super::spool::prune(&dir, 2);
    let left: Vec<_> = std::fs::read_dir(&dir).unwrap().flatten().collect();
    assert_eq!(left.len(), 2, "prune should keep exactly the newest 2");
    let _ = std::fs::remove_dir_all(&dir);
}

/// COST, measured rather than asserted — the precedent `probes.rs` set.
///
/// Prints both arms and asserts only a loose ceiling: this runs on a shared
/// build box, and a test that fails when a neighbour is compiling teaches
/// people to skip the gate.
///
/// WHAT THIS DOES NOT MEASURE, stated rather than glossed: the flush (a
/// `serde_json` join plus one `rename(2)`, off every request path and once
/// every 30 s), and the CONTENDED cost of the buffer mutex. Neither needs
/// measuring for the reason `probes.rs` gave about its own contention: every
/// span here is per session or per daemon start, never per frame and never per
/// input record, so two hot tasks queueing on this lock is not a regime any
/// station runs in.
#[test]
fn span_cost_is_small() {
    let _g = BUF_TEST.lock().unwrap_or_else(|e| e.into_inner());
    const N: u32 = 20_000;
    // Disabled arm: a Span that is never emitted. Constructed directly rather
    // than through `enabled()`, which is a process-wide OnceLock the enabled
    // arm below has to win.
    let parent = parse_traceparent(TP).unwrap();
    let t = std::time::Instant::now();
    for _ in 0..N {
        let mut s = Span::start_on(false, "guest.resume", Kind::Internal, parent);
        s.attr("kh.guest.was_paused", true);
        s.end();
    }
    let off = t.elapsed().as_nanos() as f64 / N as f64;

    let t = std::time::Instant::now();
    for i in 0..N {
        let mut s = Span::start_on(true, "guest.resume", Kind::Internal, parent);
        s.attr("kh.guest.was_paused", true);
        s.end();
        // Drain inside the loop, not after: buffering 20 000 spans would measure
        // `Vec` growth, which no station will ever do (one session emits seven,
        // and the flush empties the buffer every 30 s).
        if i % 512 == 0 {
            drain();
        }
    }
    let on = t.elapsed().as_nanos() as f64 / N as f64;
    drain();
    println!("span cost: enabled {on:.0} ns/span, disabled {off:.0} ns/span ({N} spans each)");
    // ~3x the measured DEBUG number, the same rule `probes_tests` uses: loose
    // enough that a loaded shared build box cannot flake it, tight enough that
    // a span that grew a syscall or a lock would still be caught. The number
    // that matters is the RELEASE one, quoted in docs/ANALYTICS.md.
    assert!(
        on < 30_000.0,
        "enabled span cost {on:.0} ns/span is out of budget — did a span grow a \
         syscall, a file write or a contended lock?"
    );
}

/// The buffer is bounded, and overflow is COUNTED rather than silent. A station
/// whose collector stopped must lose spans and keep streaming (contract §7) —
/// but it must not do so quietly, or "no spans" reads as "no visitors".
#[test]
fn the_buffer_is_bounded_and_says_when_it_drops() {
    let _g = BUF_TEST.lock().unwrap_or_else(|e| e.into_inner());
    drain();
    DROPPED.store(0, Ordering::Relaxed);
    for _ in 0..(BUF_MAX + 16) {
        push("{}".to_string());
    }
    assert_eq!(drain().len(), BUF_MAX);
    assert!(DROPPED.swap(0, Ordering::Relaxed) >= 16);
}
