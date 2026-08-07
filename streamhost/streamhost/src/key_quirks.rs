// Keyboard QUIRKS: the small, per-tile corrections between what a browser
// keyboard emits and what a given emulated machine can actually receive.
//
// Three concerns live here, all reached from `input.rs`'s type=3 record path:
//   * `key_qnum`      — wire scancode -> QEMU dbus qnum, incl. the SH_LEGACY_KBD
//                       pre-1986 cursor-cluster quirk;
//   * `remap_key`     — the registry-declared SH_KEY_REMAP table;
//   * `KeyHold`/`gate`— the SH_KEY_MIN_HOLD_MS minimum hold and its serializer.

use tokio::sync::Mutex;

/// Map a browser wire keycode to the QEMU dbus `qnum` (XT set1 make code).
///
/// FIX 1: the client sends extended keys as 0xE0xx on the wire (ArrowUp=0xe048,
/// ArrowDown=0xe050, Left=0xe04b, Right=0xe04d, Home/End/PgUp/PgDn/Ins/Del,
/// RCtrl=0xe01d, RAlt=0xe038, KP-Enter=0xe01c, ...). QEMU's dbus
/// qemu_input_key_number_to_qcode expects the qnum set with the 0xE0 escape FOLDED
/// into bit 7 (Up=0xC8, Down=0xD0, Left=0xCB, Right=0xCD, RCtrl=0x9D, RAlt=0xB8,
/// KP-Enter=0x9C). Any value >= 0x100 is UNMAPPED and the key drops. Non-extended
/// keys (Esc=0x01, Enter=0x1c, letters, F-keys) pass straight through.
///
/// LEGACY-KBD quirk (SH_LEGACY_KBD, Win 1.x/2.x): those pre-1986 drivers do not
/// decode 0xE0-prefixed enhanced scancodes at all — only the bare numeric-keypad
/// cursor codes (0x47..0x53, NumLock off). For the dedicated cursor/navigation
/// cluster (0xE047..=0xE053: Home/Up/PgUp/Left/Right/End/Down/PgDn/Ins/Del) send
/// the BARE keypad qnum (code & 0x7f) instead of the enhanced 0x80| form so the
/// guest's own INT 09h driver navigates. Other extended keys (RCtrl/RAlt/KP-Enter)
/// keep the enhanced form — remapping those would collide with distinct keys.
pub(crate) fn key_qnum(code: u32, legacy_kbd: bool) -> u32 {
    if code & 0xff00 == 0xe000 {
        if legacy_kbd && (0xe047..=0xe053).contains(&code) {
            code & 0x7f
        } else {
            0x80 | (code & 0x7f)
        }
    } else {
        code
    }
}

/// Apply the tile's `SH_KEY_REMAP` table to a browser WIRE code, before any
/// other keyboard handling. Both input surfaces — the physical keyboard and the
/// SPA's on-screen keyboard — converge on the same type=3 record, so remapping
/// here covers both. First match wins; an empty table is the identity.
///
/// Motivating case: the MPF-II's 8x8 matrix has no Backspace key at all (MAME
/// `src/mame/apple/tk2000.cpp`, which `mpf2` clones, declares only KEYCODE_LEFT
/// and KEYCODE_RIGHT of the whole edit cluster). On that machine, as on the
/// Apple II, LEFT ARROW is the rubout key: `0x0e:0xe04b`.
pub fn remap_key(code: u32, map: &[(u32, u32)]) -> u32 {
    map.iter()
        .find(|(from, _)| *from == code)
        .map_or(code, |(_, to)| *to)
}

/// Minimum-hold bookkeeping for `SH_KEY_MIN_HOLD_MS` (see the config field doc).
/// Pure and time-injected so the frame arithmetic is unit-testable.
#[derive(Default)]
pub struct KeyHold {
    pressed: std::collections::HashMap<u32, std::time::Instant>,
    last_release: Option<std::time::Instant>,
}

impl KeyHold {
    pub fn on_press(&mut self, qnum: u32, now: std::time::Instant) {
        self.pressed.insert(qnum, now);
    }

    /// How much longer the caller must wait before sending this Press, so the
    /// emulator gets to sample an all-keys-up frame between two characters
    /// (SH_KEY_MIN_GAP_MS). Only a Press that follows a Release is delayed: with
    /// no previous Release — the first key, or a modifier still held down from
    /// the chord typeText builds for an uppercase character — the wait is zero,
    /// so chords are never pulled apart.
    pub fn press_delay(
        &self,
        now: std::time::Instant,
        min_gap: std::time::Duration,
    ) -> std::time::Duration {
        match self.last_release {
            Some(at) => min_gap.saturating_sub(now.saturating_duration_since(at)),
            None => std::time::Duration::ZERO,
        }
    }

    /// Record that a Release has just gone out on the wire; starts the gap clock.
    pub fn on_release(&mut self, now: std::time::Instant) {
        self.last_release = Some(now);
    }

    /// How much longer this key must stay down before its Release may be sent.
    /// Zero for a key we never saw pressed (idempotent release) or one already
    /// held long enough.
    pub fn release_delay(
        &mut self,
        qnum: u32,
        now: std::time::Instant,
        min_hold: std::time::Duration,
    ) -> std::time::Duration {
        match self.pressed.remove(&qnum) {
            Some(at) => min_hold.saturating_sub(now.saturating_duration_since(at)),
            None => std::time::Duration::ZERO,
        }
    }
}

/// The tile-wide key gate. One streamhost process serves ONE tile, so a single
/// mutex serializes every key event for it: while a deferred Release is pending
/// the next key's Press waits its turn instead of racing ahead. Nothing is
/// dropped when the user types faster than the hold or the gap — the events
/// queue in arrival order (tokio's mutex is FIFO-fair), which is also what makes
/// a stuck-key interleave (A-down, B-down, A-up, B-up collapsing) impossible.
/// A whole pasted line therefore arrives complete and in order, just paced.
pub(crate) fn key_gate() -> &'static Mutex<KeyHold> {
    static GATE: std::sync::OnceLock<Mutex<KeyHold>> = std::sync::OnceLock::new();
    GATE.get_or_init(Mutex::default)
}

#[cfg(test)]
mod tests {
    use super::{key_qnum, remap_key, KeyHold};
    use std::time::{Duration, Instant};

    // MPF-II: the browser's Backspace (0x0e) must arrive as LEFT ARROW
    // (0xe04b) — the only rubout key that exists in the machine's matrix.
    #[test]
    fn key_remap_rewrites_declared_codes_only() {
        let map = [(0x0eu32, 0xe04bu32)];
        assert_eq!(remap_key(0x0e, &map), 0xe04b);
        assert_eq!(remap_key(0x1c, &map), 0x1c); // Enter untouched
        assert_eq!(remap_key(0x0e, &[]), 0x0e); // empty table is the identity
    }

    // …and the remap composes with the legacy-kbd quirk rather than bypassing
    // it: the remapped extended code still goes through key_qnum.
    #[test]
    fn key_remap_composes_with_key_qnum() {
        let out = remap_key(0x0e, &[(0x0e, 0xe04b)]);
        assert_eq!(key_qnum(out, false), 0xcb); // enhanced Left
        assert_eq!(key_qnum(out, true), 0x4b); // bare keypad Left (legacy kbd)
    }

    // A press+release inside one emulated frame is invisible to an emulator that
    // samples its ports once per frame, so the release owes the rest of the hold.
    #[test]
    fn key_hold_defers_a_release_that_is_too_fast() {
        let mut hold = KeyHold::default();
        let min = Duration::from_millis(32);
        let t0 = Instant::now();
        hold.on_press(0x1e, t0);
        assert_eq!(
            hold.release_delay(0x1e, t0 + Duration::from_millis(2), min),
            Duration::from_millis(30)
        );
    }

    // A key already held long enough is released immediately — the knob adds no
    // latency to normal typing.
    #[test]
    fn key_hold_does_not_delay_a_slow_keypress() {
        let mut hold = KeyHold::default();
        let min = Duration::from_millis(32);
        let t0 = Instant::now();
        hold.on_press(0x1e, t0);
        assert!(hold
            .release_delay(0x1e, t0 + Duration::from_millis(80), min)
            .is_zero());
    }

    // Two different keys keep independent hold deadlines, and a release with no
    // matching press (or a duplicate release) never blocks.
    #[test]
    fn key_hold_tracks_keys_independently_and_ignores_stray_releases() {
        let mut hold = KeyHold::default();
        let min = Duration::from_millis(32);
        let t0 = Instant::now();
        hold.on_press(0x1e, t0);
        hold.on_press(0x30, t0 + Duration::from_millis(20));
        assert_eq!(
            hold.release_delay(0x30, t0 + Duration::from_millis(24), min),
            Duration::from_millis(28)
        );
        assert!(hold
            .release_delay(0x1e, t0 + Duration::from_millis(40), min)
            .is_zero());
        assert!(hold.release_delay(0x1e, t0, min).is_zero()); // already released
        assert!(hold.release_delay(0x77, t0, min).is_zero()); // never pressed
    }

    // Sustained typing: the Press after a Release owes the rest of the gap, so
    // the emulator sees an all-keys-up frame between two characters instead of
    // one long chord.
    #[test]
    fn key_gap_defers_a_press_that_treads_on_the_previous_release() {
        let mut hold = KeyHold::default();
        let gap = Duration::from_millis(32);
        let t0 = Instant::now();
        hold.on_release(t0);
        assert_eq!(
            hold.press_delay(t0 + Duration::from_millis(2), gap),
            Duration::from_millis(30)
        );
        assert!(hold
            .press_delay(t0 + Duration::from_millis(50), gap)
            .is_zero());
    }

    // The very first key, and every key of a chord that is still building (no
    // Release yet — e.g. Shift down, then the letter down), start immediately.
    #[test]
    fn key_gap_never_splits_a_chord_or_delays_the_first_key() {
        let mut hold = KeyHold::default();
        let gap = Duration::from_millis(32);
        let t0 = Instant::now();
        assert!(hold.press_delay(t0, gap).is_zero()); // first key ever
        hold.on_press(0x2a, t0); // Shift down
        assert!(hold.press_delay(t0, gap).is_zero()); // letter down, same chord
    }

    // Hold and gap compose over a two-character burst: 'a' down at t0 is held
    // min_hold, and 'b' down then waits min_gap past that release.
    #[test]
    fn key_hold_and_gap_compose_over_a_typed_burst() {
        let mut hold = KeyHold::default();
        let (min, gap) = (Duration::from_millis(32), Duration::from_millis(32));
        let t0 = Instant::now();
        hold.on_press(0x1e, t0);
        let wait = hold.release_delay(0x1e, t0 + Duration::from_millis(1), min);
        assert_eq!(wait, Duration::from_millis(31));
        let released = t0 + Duration::from_millis(1) + wait;
        hold.on_release(released);
        assert_eq!(hold.press_delay(released, gap), Duration::from_millis(32));
    }

    // Legacy OFF (modern guests): dedicated cursor cluster keeps the ENHANCED
    // 0x80|(code&0x7f) form (Up=0xC8, Down=0xD0, Left=0xCB, Right=0xCD).
    #[test]
    fn extended_arrows_enhanced_when_not_legacy() {
        assert_eq!(key_qnum(0xe048, false), 0xC8); // Up
        assert_eq!(key_qnum(0xe050, false), 0xD0); // Down
        assert_eq!(key_qnum(0xe04b, false), 0xCB); // Left
        assert_eq!(key_qnum(0xe04d, false), 0xCD); // Right
    }

    // Legacy ON (Win 1.x/2.x): the dedicated cursor/navigation cluster
    // (0xE047..=0xE053) folds to the BARE numeric-keypad scancode (Up=0x48,
    // Down=0x50, Left=0x4B, Right=0x4D, Home=0x47 ... Del=0x53) that the guest's
    // pre-1986 INT 09h driver understands.
    #[test]
    fn legacy_arrows_use_bare_keypad_scancodes() {
        assert_eq!(key_qnum(0xe047, true), 0x47); // Home
        assert_eq!(key_qnum(0xe048, true), 0x48); // Up
        assert_eq!(key_qnum(0xe049, true), 0x49); // PgUp
        assert_eq!(key_qnum(0xe04b, true), 0x4B); // Left
        assert_eq!(key_qnum(0xe04d, true), 0x4D); // Right
        assert_eq!(key_qnum(0xe04f, true), 0x4F); // End
        assert_eq!(key_qnum(0xe050, true), 0x50); // Down
        assert_eq!(key_qnum(0xe051, true), 0x51); // PgDn
        assert_eq!(key_qnum(0xe052, true), 0x52); // Ins
        assert_eq!(key_qnum(0xe053, true), 0x53); // Del
    }

    // Legacy ON must ONLY touch the 0xE047..=0xE053 cluster: other extended keys
    // (RCtrl=0xe01d, RAlt=0xe038, KP-Enter=0xe01c) keep the enhanced form so they
    // don't collide with distinct keypad keys; plain keys pass straight through.
    #[test]
    fn legacy_leaves_other_keys_untouched() {
        assert_eq!(key_qnum(0xe01d, true), 0x9D); // RCtrl (enhanced)
        assert_eq!(key_qnum(0xe038, true), 0xB8); // RAlt (enhanced)
        assert_eq!(key_qnum(0xe01c, true), 0x9C); // KP-Enter (enhanced)
        assert_eq!(key_qnum(0x1c, true), 0x1c); // Enter (plain)
        assert_eq!(key_qnum(0x01, true), 0x01); // Esc (plain)
        assert_eq!(key_qnum(0x1e, true), 0x1e); // 'a' (plain)
    }
}
