//! The modifier lead (`SH_KEY_MOD_LEAD_MS`) on the QEMU/dbus key gate --
//! a sibling file for the per-file line budget, like `key_state_tests.rs`.
//!
//! The defect: `typeText()` sends a shifted character as Shift↓ key↓ key↑
//! Shift↑ back to back, and the gate forwarded Shift↓ and key↓ microseconds
//! apart, so a guest that scans its keyboard once a frame read both in one
//! scan. amstradcpc (cap32 in a QEMU kiosk) then typed `)` as `9`:
//! `IF INKEY(71)` arrived as `IF INKEY(719`. The pure tests pin the
//! arithmetic; the paused-clock ones run the real `pace_edge` sequence.
use super::{is_modifier_qnum, key_qnum, pace_edge, KeyHold, KeyPacing};
use std::cell::RefCell;
use std::time::{Duration, Instant};

const SHIFT_L: u32 = 0x2a;
const CTRL_L: u32 = 0x1d;
const KEY_0: u32 = 0x0b;
const KEY_A: u32 = 0x1e;

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

/// THE FIX: the key of a Shift chord waits until Shift has been on the wire
/// for the lead -- and no longer than that.
#[test]
fn mod_lead_holds_the_key_behind_its_shift() {
    let mut hold = KeyHold::default();
    let t0 = Instant::now();
    hold.on_press(SHIFT_L, t0);
    assert_eq!(hold.press_delay(KEY_0, t0 + ms(1), ms(40), ms(20)), ms(19));
    assert!(hold
        .press_delay(KEY_0, t0 + ms(20), ms(40), ms(20))
        .is_zero());
}

/// A Shift RELEASE starts the lead too: the next unshifted key must not
/// share a scan with Shift going up, or `)a` reads as `)A`. It owes
/// max(gap, lead) -- the validator's HOLD + max(GAP, LEAD) + LEAD.
#[test]
fn mod_lead_also_follows_a_shift_release() {
    let mut hold = KeyHold::default();
    let t0 = Instant::now();
    hold.on_press(SHIFT_L, t0);
    hold.on_press(KEY_0, t0 + ms(20));
    hold.on_release(KEY_0, t0 + ms(60));
    hold.on_release(SHIFT_L, t0 + ms(60));
    assert_eq!(hold.press_delay(KEY_A, t0 + ms(60), ms(10), ms(20)), ms(20));
    assert_eq!(hold.press_delay(KEY_A, t0 + ms(60), ms(40), ms(20)), ms(40));
}

/// Unset or 0 is today's gate, number for number: the key of a chord goes
/// straight after its Shift, and only a press after a release owes the gap.
#[test]
fn mod_lead_zero_is_the_old_gate() {
    let mut hold = KeyHold::default();
    let t0 = Instant::now();
    hold.on_press(SHIFT_L, t0);
    assert!(hold
        .press_delay(KEY_0, t0, ms(40), Duration::ZERO)
        .is_zero());
    hold.on_press(KEY_0, t0);
    hold.on_release(KEY_0, t0 + ms(40));
    hold.on_release(SHIFT_L, t0 + ms(40));
    assert_eq!(
        hold.press_delay(KEY_A, t0 + ms(42), ms(40), Duration::ZERO),
        ms(38)
    );
}

/// The lead gates only a NON-modifier press: Shift then Ctrl stays a chord
/// built at the old pace, and a release never waits it.
#[test]
fn mod_lead_never_delays_a_modifier_or_a_release() {
    let mut hold = KeyHold::default();
    let t0 = Instant::now();
    hold.on_press(SHIFT_L, t0);
    assert!(hold
        .press_delay(CTRL_L, t0 + ms(1), ms(40), ms(20))
        .is_zero());
    hold.on_press(KEY_0, t0 + ms(20));
    // A modifier edge 1 ms before does not hold back a release that owes nothing.
    hold.on_press(CTRL_L, t0 + ms(60));
    assert!(hold.release_delay(KEY_0, t0 + ms(61), ms(40)).is_zero());
}

/// Shift, Ctrl and Alt on either side are modifiers, the right-hand ones in
/// the folded form `key_qnum` hands QEMU; letters, digits, Enter and the
/// Windows keys are not.
#[test]
fn modifiers_are_shift_ctrl_alt_either_side() {
    for wire in [0x2a, 0x36, 0x1d, 0xe01d, 0x38, 0xe038] {
        assert!(is_modifier_qnum(key_qnum(wire, false)), "{wire:#x}");
    }
    for wire in [0x1e, 0x0b, 0x1c, 0x39, 0xe05b, 0xe048] {
        assert!(!is_modifier_qnum(key_qnum(wire, false)), "{wire:#x}");
    }
}

/// `typeText()`'s `)` then `a`, all six edges arriving at once, through the
/// real gate: returns when each edge went out, relative to the first.
async fn type_paren_then_a(pacing: KeyPacing) -> Vec<(u32, bool, Duration)> {
    let gate = tokio::sync::Mutex::new(KeyHold::default());
    let sent = RefCell::new(Vec::new());
    let t0 = tokio::time::Instant::now();
    let edges = [
        (SHIFT_L, true),
        (KEY_0, true),
        (KEY_0, false),
        (SHIFT_L, false),
        (KEY_A, true),
        (KEY_A, false),
    ];
    for (qnum, down) in edges {
        pace_edge(&gate, pacing, qnum, down, async {
            sent.borrow_mut().push((qnum, down, t0.elapsed()));
        })
        .await;
    }
    sent.into_inner()
}

/// Through `pace_edge`: every edge goes out, in arrival order, and the `0`
/// press trails its Shift by the lead (amstradcpc's lost `)`).
#[tokio::test(start_paused = true)]
async fn pacer_sends_the_key_a_lead_after_its_shift() {
    let sent = type_paren_then_a(KeyPacing::from_ms(40, 40, 20)).await;
    let order: Vec<(u32, bool)> = sent.iter().map(|&(q, d, _)| (q, d)).collect();
    assert_eq!(
        order,
        [
            (SHIFT_L, true),
            (KEY_0, true),
            (KEY_0, false),
            (SHIFT_L, false),
            (KEY_A, true),
            (KEY_A, false)
        ]
    );
    let at = |i: usize| sent[i].2;
    assert_eq!(at(1) - at(0), ms(20), "0↓ trails Shift↓ by the lead");
    assert_eq!(at(2) - at(1), ms(40), "the hold is unchanged");
    assert_eq!(at(4) - at(3), ms(40), "a↓ owes max(gap, lead) after Shift↑");
}

/// Lead 0 through `pace_edge`: Shift and its key go out back to back, exactly
/// as before the knob existed.
#[tokio::test(start_paused = true)]
async fn pacer_with_lead_zero_is_unchanged() {
    let sent = type_paren_then_a(KeyPacing::from_ms(40, 40, 0)).await;
    assert_eq!(sent.len(), 6);
    assert_eq!(sent[1].2, sent[0].2, "0↓ goes straight after Shift↓");
    assert_eq!(sent[4].2 - sent[3].2, ms(40), "a↓ owes only the gap");
}
