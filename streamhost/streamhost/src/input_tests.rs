//! Unit tests for `input` — split into a sibling file purely for the per-file
//! line budget; `#[path]` keeps them the same inline `mod tests`, with the same
//! access to the module's private items.
use super::{calibrated_abs, home_pin, newer, quantize, rel_chunks, rel_chunks_q, HOME_PIN};

// The pin is sent in guest DELTA UNITS but its invariant ("exceed the guest
// surface") is stated in PIXELS, so it has to scale with the guest's own
// units-to-pixels factor. Every gain>=1 station must keep sending EXACTLY
// the historical 2048 — this is fleet-visible behavior, not a free knob.
#[test]
fn home_pin_is_unchanged_for_every_gain_at_or_above_one() {
    for scale in [1.0, 0.783, 0.5, 0.0, -3.0] {
        assert_eq!(
            home_pin(scale),
            HOME_PIN,
            "scale {scale} must not shrink the pin"
        );
    }
}

// macos753: Mac OS 7.5.3 moves 0.36 px per unit, so cursor_scale is 1/0.36
// and the pin must grow enough to cross a 1152 px screen. At the bare 2048
// it would travel 737 px and strand the cursor mid-screen.
#[test]
fn home_pin_grows_enough_to_cross_a_scaling_guests_screen() {
    let scale = 1.0 / 0.36;
    let pin = home_pin(scale);
    assert!(pin > HOME_PIN, "a >1 scale must grow the pin");
    let travelled = f64::from(pin) * 0.36;
    assert!(
        travelled > 1152.0,
        "pin travels {travelled} px, short of the 1152 px screen"
    );
}

// A nonsense calibration must saturate, never wrap into a negative pin that
// throws the cursor away from the corner it is meant to clamp into.
#[test]
fn home_pin_saturates_instead_of_wrapping() {
    assert_eq!(home_pin(f64::MAX), i32::MAX);
    assert!(home_pin(1e9) > 0);
}

#[test]
fn absolute_calibration_scales_and_clamps_for_both_dbus_paths() {
    assert_eq!(calibrated_abs(640, 480, 0, 0, 0.5), (320, 240));
    assert_eq!(calibrated_abs(100, 200, 4, -10, 0.75), (79, 140));
    assert_eq!(calibrated_abs(2, 3, -20, -30, 1.0), (0, 0));
}

// Small deltas (within one step) are a SINGLE un-paced send == bare
// rel_motion, so the pointer-lock direct-rel path stays exactly 1:1.
#[test]
fn rel_chunks_small_is_single() {
    assert_eq!(rel_chunks(0, 0, 256), vec![]); // zero move: nothing sent
    assert_eq!(rel_chunks(5, -3, 256), vec![(5, -3)]);
    assert_eq!(rel_chunks(256, -256, 256), vec![(256, -256)]); // exactly at bound
}

// Large/fast deltas are chunked; every chunk stays within the per-axis clamp
// window and the chunks SUM EXACTLY to the original delta (no 1:1 drift).
#[test]
fn rel_chunks_large_bounded_and_exact() {
    for (dx, dy) in [
        (2000, 0),
        (0, -1500),
        (1920, 1200),
        (-8192, -8192),
        (1000, -37),
        (13, 4096),
    ] {
        // Both the default 256 and a small per-station cap (rhapsody: 24)
        // must sum exactly and never exceed the cap.
        for cap in [256, 24] {
            let chunks = rel_chunks(dx, dy, cap);
            let (mut sx, mut sy) = (0i32, 0i32);
            for (cx, cy) in &chunks {
                assert!(
                    cx.abs() <= cap && cy.abs() <= cap,
                    "chunk exceeds cap {cap}"
                );
                sx += cx;
                sy += cy;
            }
            assert_eq!((sx, sy), (dx, dy), "chunks must sum to the delta");
        }
    }
}

// Quantized chunking (A/UX): every chunk is a multiple of the quantum on
// both axes, no chunk exceeds the cap by more than one quantum, and the
// chunks still sum exactly to the (already-quantized) delta.
#[test]
fn rel_chunks_quantized_are_multiples_and_exact() {
    for (dx, dy) in [
        (400, 0),
        (0, -804),
        (1152, 868),
        (-2048, -2048),
        (36, -8),
        (32, 0),
    ] {
        let chunks = rel_chunks_q(dx, dy, 32, 4);
        let (mut sx, mut sy) = (0i32, 0i32);
        for (cx, cy) in &chunks {
            assert_eq!(cx % 4, 0, "chunk dx {cx} not a quantum multiple");
            assert_eq!(cy % 4, 0, "chunk dy {cy} not a quantum multiple");
            assert!(
                cx.abs() <= 36 && cy.abs() <= 36,
                "chunk ({cx},{cy}) exceeds cap+quantum"
            );
            sx += cx;
            sy += cy;
        }
        assert_eq!((sx, sy), (dx, dy));
    }
    // quantum 0/1 == the plain chunker, byte for byte
    for (dx, dy) in [(2000, 0), (1000, -37), (5, -3), (0, 0)] {
        assert_eq!(rel_chunks_q(dx, dy, 256, 0), rel_chunks(dx, dy, 256));
        assert_eq!(rel_chunks_q(dx, dy, 256, 1), rel_chunks(dx, dy, 256));
    }
}

// The quantizer rounds toward zero so the pending remainder always has the
// sign of the motion still owed.
#[test]
fn quantize_rounds_toward_zero() {
    assert_eq!(quantize(7, 4), 4);
    assert_eq!(quantize(-7, 4), -4);
    assert_eq!(quantize(8, 4), 8);
    assert_eq!(quantize(3, 4), 0);
    assert_eq!(quantize(9, 0), 9);
    assert_eq!(quantize(-9, 1), -9);
}

// ---- cseq: the client's statement of what it sent first ----------------
// Moves ride unreliable datagrams, buttons a reliable stream. The network is
// free to reorder the two against each other, and a press that lost the race
// to its own position used to press at the PREVIOUS point and then slide the
// cursor there under a held button — a drag, to every guest (IRIX, 2026-08-05).

#[test]
fn a_later_stamp_is_newer_and_an_earlier_one_is_not() {
    assert!(newer(2, 1));
    assert!(!newer(1, 2));
    assert!(!newer(7, 7)); // a REPLAYED stamp is not newer: idempotent
}

// The gate must not become a cliff every 2^32 records: a session that stays
// up long enough to wrap would otherwise drop every move forever after.
#[test]
fn the_stamp_wraps_without_stranding_the_pointer() {
    assert!(newer(1, u32::MAX));
    assert!(newer(0, u32::MAX));
    assert!(!newer(u32::MAX, 1));
}

// The distances are not symmetric on purpose: half the space is "newer".
#[test]
fn a_stamp_half_a_space_away_is_still_ordered() {
    let far = 1u32 << 31;
    assert!(newer(far - 1, 0));
    assert!(!newer(far + 1, 0)); // beyond the window, read as older
}
