//! `input_trace.rs`'s contract, restated as assertions, plus the measured cost
//! of the unsampled path (§D of the brief this module implements).

use super::*;

fn ctx(trace: u128, span: u64) -> Ctx {
    Ctx {
        trace,
        span,
        sampled: true,
    }
}

#[test]
fn round_trips_a_sampled_key_record() {
    let mut rec = vec![3u8, 1, 0x1C, 0x00]; // key, down, qemu_keycode=0x001C (Enter)
    let c = ctx(
        0x4bf9_2f35_77b3_4da6_a3ce_929d_0e0e_4736,
        0x00f0_67aa_0ba9_02b7,
    );
    rec.extend_from_slice(&encode(c));
    let (body, parsed) = strip(&rec);
    assert_eq!(body, &[3u8, 1, 0x1C, 0x00]);
    assert_eq!(parsed, Some(c));
}

#[test]
fn round_trips_both_button_shapes() {
    for base in [vec![2u8, 0, 1], {
        let mut b = vec![2u8, 0, 1];
        b.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0]); // x,y,cseq
        b
    }] {
        let mut rec = base.clone();
        let c = ctx(1, 1);
        rec.extend_from_slice(&encode(c));
        let (body, parsed) = strip(&rec);
        assert_eq!(body, base.as_slice());
        assert_eq!(parsed, Some(c));
    }
}

/// OLD BROWSER -> NEW DAEMON: a record at its historic exact length carries no
/// suffix. `strip` must return it byte-for-byte unchanged and find nothing —
/// this is the whole backward-compatibility guarantee, so it is asserted for
/// every base length either record type has ever shipped.
#[test]
fn old_browser_record_is_untouched() {
    for rec in [
        vec![3u8, 1, 0x1C, 0x00],                // key
        vec![2u8, 0, 1],                         // bare button edge
        vec![2u8, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0], // carried-position button
    ] {
        let (body, ctx) = strip(&rec);
        assert_eq!(body, rec.as_slice());
        assert!(ctx.is_none());
    }
}

/// NEW BROWSER -> OLD DAEMON is the mirror case and cannot be exercised by
/// calling THIS module (the old daemon never runs it) — it is exercised
/// instead where `input::handle`'s match arms are proven to ignore trailing
/// bytes: see `input_tests.rs`. What this module owns is the other half of
/// that claim: a suffixed record, once stripped, is IDENTICAL to what an old
/// browser would have sent, so whatever `input::handle` does with the
/// stripped body is exactly what it always did.
#[test]
fn stripped_body_matches_the_pre_suffix_wire_shape() {
    let mut rec = vec![3u8, 0, 0x2A, 0x00]; // key up, LShift
    rec.extend_from_slice(&encode(ctx(9, 9)));
    let (body, _) = strip(&rec);
    assert_eq!(body, vec![3u8, 0, 0x2A, 0x00].as_slice());
}

/// A marker mismatch or a zero id is "no context", never a panic and never a
/// rejected record — the same rule `trace/context.rs::parse_traceparent`
/// holds for the header form (contract §1).
#[test]
fn malformed_suffix_yields_no_context_not_an_error() {
    // Right length, wrong marker byte: coincidence, not a suffix.
    let mut rec = vec![3u8, 1, 0x1C, 0x00];
    rec.push(0xFF); // not SUFFIX_MARKER
    rec.extend_from_slice(&[0u8; CTX_LEN]);
    let (body, c) = strip(&rec);
    assert!(c.is_none());
    assert_eq!(body.len(), rec.len(), "unrecognised tail is left in place");

    // Right marker, all-zero ids: the spec's own "invalid".
    let mut rec = vec![3u8, 1, 0x1C, 0x00];
    rec.push(SUFFIX_MARKER);
    rec.extend_from_slice(&[0u8; CTX_LEN]);
    let (body, c) = strip(&rec);
    assert!(c.is_none());
    assert_eq!(body, &[3u8, 1, 0x1C, 0x00]);

    // Empty and unknown-type records never panic.
    assert_eq!(strip(&[]), (&[][..], None));
    let odd = vec![99u8, 1, 2, 3];
    assert_eq!(strip(&odd), (odd.as_slice(), None));
}

#[test]
fn key_class_buckets_are_sensible() {
    assert_eq!(key_class(0x001C), "enter");
    assert_eq!(key_class(0xE01C), "enter"); // numpad Enter
    assert_eq!(key_class(0x002A), "modifier"); // LShift
    assert_eq!(key_class(0xE05B), "modifier"); // LWin
    assert_eq!(key_class(0x0048), "navigation"); // bare-keypad Up (legacy kbd)
    assert_eq!(key_class(0xE048), "navigation"); // enhanced Up
    assert_eq!(key_class(0x000F), "navigation"); // Tab
    assert_eq!(key_class(0x003B), "function"); // F1
    assert_eq!(key_class(0x0058), "function"); // F12
    assert_eq!(key_class(0x001E), "printable"); // 'A'
    assert_eq!(key_class(0x0039), "printable"); // Space
}

#[test]
fn input_class_names_are_wire_class_only() {
    assert_eq!(input_class(2), "click");
    assert_eq!(input_class(3), "key");
    assert_eq!(input_class(1), "other");
}

/// The budget this whole design exists to protect: 9 records in 10 (default
/// N=10) take the UNSAMPLED path through `strip`, which must cost next to
/// nothing — no allocation, no formatting, comparable to `probes.rs`'s
/// measured 8.5 ns/hit. Printed, not asserted tight, for the same reason
/// `probes_tests.rs` and `trace/tests.rs` print rather than pin a shared
/// build box to a hard nanosecond figure.
#[test]
fn unsampled_strip_cost_is_negligible() {
    const N: u32 = 200_000;
    let unsampled_key = [3u8, 1, 0x1C, 0x00];
    let unsampled_button = [2u8, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0];

    let t = std::time::Instant::now();
    let mut sink = 0usize;
    for i in 0..N {
        let rec: &[u8] = if i % 2 == 0 {
            &unsampled_key
        } else {
            &unsampled_button
        };
        let (body, c) = strip(rec);
        sink ^= body.len();
        sink ^= c.is_some() as usize;
    }
    let unsampled_ns = t.elapsed().as_nanos() as f64 / N as f64;
    std::hint::black_box(sink);

    let mut sampled_key = unsampled_key.to_vec();
    sampled_key.extend_from_slice(&encode(ctx(1, 1)));
    let t = std::time::Instant::now();
    let mut sink = 0usize;
    for _ in 0..N {
        let (body, c) = strip(&sampled_key);
        sink ^= body.len();
        sink ^= c.is_some() as usize;
    }
    let sampled_ns = t.elapsed().as_nanos() as f64 / N as f64;
    std::hint::black_box(sink);

    println!(
        "input_trace::strip cost: unsampled {unsampled_ns:.1} ns/record, sampled (parses ctx) {sampled_ns:.1} ns/record ({N} records each)"
    );
    // Loose ceiling for a shared, possibly loaded build box — see the same
    // rule stated in `probes.rs` and `trace/tests.rs`. What matters is that
    // this is comparisons-and-a-slice, not an allocation or a lock.
    assert!(
        unsampled_ns < 500.0,
        "unsampled strip cost {unsampled_ns:.1} ns is out of budget — did it start allocating?"
    );
}
