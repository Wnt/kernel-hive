// Keyboard QUIRKS: the small, per-station corrections between what a browser
// keyboard emits and what a given emulated machine can actually receive.
//
// Three concerns live here, all reached from `input.rs`'s type=3 record path:
//   * `key_qnum`      — wire scancode -> QEMU dbus qnum, incl. the SH_LEGACY_KBD
//                       pre-1986 cursor-cluster quirk;
//   * `remap_key`     — the registry-declared SH_KEY_REMAP table;
//   * `KeyHold`/`pace_edge` — the SH_KEY_MIN_HOLD_MS / _GAP_MS / SH_KEY_MOD_LEAD_MS
//                       pacing of the QEMU/dbus keyboard and its serializer.

use std::time::{Duration, Instant};

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
            crate::probes::probe!(KEY_QUIRK_LEGACY_CURSOR);
            code & 0x7f
        } else {
            0x80 | (code & 0x7f)
        }
    } else {
        code
    }
}

/// Apply the station's `SH_KEY_REMAP` table to a browser WIRE code, before any
/// other keyboard handling. Both input surfaces — the physical keyboard and the
/// UI's on-screen keyboard — converge on the same type=3 record, so remapping
/// here covers both. First match wins; an empty table is the identity.
///
/// Motivating case: the MPF-II's 8x8 matrix has no Backspace key at all (MAME
/// `src/mame/apple/tk2000.cpp`, which `mpf2` clones, declares only KEYCODE_LEFT
/// and KEYCODE_RIGHT of the whole edit cluster). On that machine, as on the
/// Apple II, LEFT ARROW is the rubout key: `0x0e:0xe04b`.
pub fn remap_key(code: u32, map: &[(u32, u32)]) -> u32 {
    match map.iter().find(|(from, _)| *from == code) {
        // Only a real rewrite counts. An identity entry, or a table that never
        // matches, must read as "this quirk did nothing" — otherwise every
        // keystroke on a station that merely DECLARES a table looks like a hit.
        Some(&(_, to)) if to != code => {
            crate::probes::probe!(KEY_QUIRK_REMAP);
            to
        }
        Some(&(_, to)) => to,
        None => code,
    }
}

/// Is this QEMU `qnum` a modifier the guest reads as a LEVEL: Shift, Ctrl or
/// Alt, either side (the right-hand ones in `key_qnum`'s folded 0x80| form)?
/// These are the edges `SH_KEY_MOD_LEAD_MS` keeps ahead of the key they modify.
pub(crate) fn is_modifier_qnum(qnum: u32) -> bool {
    matches!(qnum, 0x2a | 0x36 | 0x1d | 0x9d | 0x38 | 0xb8)
}

/// The dbus key gate's three knobs (`SH_KEY_MIN_HOLD_MS`, `SH_KEY_MIN_GAP_MS`,
/// `SH_KEY_MOD_LEAD_MS`; see the config field docs). All zero = no gate at all.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct KeyPacing {
    pub(crate) hold: Duration,
    pub(crate) gap: Duration,
    pub(crate) lead: Duration,
}

impl KeyPacing {
    pub(crate) fn from_ms(hold: u64, gap: u64, lead: u64) -> Self {
        Self {
            hold: Duration::from_millis(hold),
            gap: Duration::from_millis(gap),
            lead: Duration::from_millis(lead),
        }
    }

    fn is_off(&self) -> bool {
        self.hold.is_zero() && self.gap.is_zero() && self.lead.is_zero()
    }
}

/// Minimum-hold bookkeeping for `SH_KEY_MIN_HOLD_MS` (see the config field doc).
/// Pure and time-injected so the frame arithmetic is unit-testable.
#[derive(Default)]
pub struct KeyHold {
    pressed: std::collections::HashMap<u32, Instant>,
    last_release: Option<Instant>,
    /// When the last Shift/Ctrl/Alt edge, press OR release, went out to QEMU:
    /// the clock `SH_KEY_MOD_LEAD_MS` runs against.
    last_mod_edge: Option<Instant>,
}

impl KeyHold {
    pub fn on_press(&mut self, qnum: u32, now: Instant) {
        self.pressed.insert(qnum, now);
        self.note_modifier(qnum, now);
    }

    fn note_modifier(&mut self, qnum: u32, now: Instant) {
        if is_modifier_qnum(qnum) {
            self.last_mod_edge = Some(now);
        }
    }

    /// How much longer the caller must wait before sending this Press.
    ///
    /// GAP (SH_KEY_MIN_GAP_MS): the emulator gets to sample an all-keys-up frame
    /// between two characters. Only a Press that follows a Release waits it:
    /// the first key ever, or the letter of a chord whose Shift is still down,
    /// owes no gap.
    ///
    /// LEAD (SH_KEY_MOD_LEAD_MS): a NON-modifier Press also waits until the last
    /// modifier edge has been on the wire this long, so a guest that scans its
    /// keyboard once a frame sees Shift (or its release) a scan BEFORE the key,
    /// never in the same one. A modifier press itself never waits the lead, so
    /// Shift+Ctrl chords and the order of edges are unchanged; 0 = no lead.
    pub fn press_delay(
        &self,
        qnum: u32,
        now: Instant,
        min_gap: Duration,
        mod_lead: Duration,
    ) -> Duration {
        let since = |at: Instant| now.saturating_duration_since(at);
        let gap = self
            .last_release
            .map_or(Duration::ZERO, |at| min_gap.saturating_sub(since(at)));
        let lead = match self.last_mod_edge {
            Some(at) if !is_modifier_qnum(qnum) => mod_lead.saturating_sub(since(at)),
            _ => Duration::ZERO,
        };
        gap.max(lead)
    }

    /// Record that a Release has just gone out on the wire; starts the gap clock
    /// (and the lead clock, when it was a modifier's).
    pub fn on_release(&mut self, qnum: u32, now: Instant) {
        self.last_release = Some(now);
        self.note_modifier(qnum, now);
    }

    /// How much longer this key must stay down before its Release may be sent.
    /// Zero for a key we never saw pressed (idempotent release) or one already
    /// held long enough.
    pub fn release_delay(&mut self, qnum: u32, now: Instant, min_hold: Duration) -> Duration {
        match self.pressed.remove(&qnum) {
            Some(at) => min_hold.saturating_sub(now.saturating_duration_since(at)),
            None => Duration::ZERO,
        }
    }
}

/// The station-wide key gate. One streamhost process serves ONE station, so a single
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

/// Put one key edge through `gate`: wait out whatever it owes (hold, gap or
/// lead), run `send` (the actual dbus call plus its held-key bookkeeping), then
/// record when it went out. With every knob at 0 there is no gate at all, the
/// edge goes straight out as it always has. The clock is tokio's, which IS the
/// wall clock in production and a virtual one under a paused-clock test.
pub(crate) async fn pace_edge(
    gate: &Mutex<KeyHold>,
    pacing: KeyPacing,
    qnum: u32,
    down: bool,
    send: impl std::future::Future<Output = ()>,
) {
    if pacing.is_off() {
        send.await;
        return;
    }
    let now = || tokio::time::Instant::now().into_std();
    let mut gate = gate.lock().await;
    let wait = if down {
        gate.press_delay(qnum, now(), pacing.gap, pacing.lead)
    } else {
        gate.release_delay(qnum, now(), pacing.hold)
    };
    if !wait.is_zero() {
        tokio::time::sleep(wait).await;
    }
    send.await;
    if down {
        gate.on_press(qnum, now());
    } else {
        gate.on_release(qnum, now());
    }
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
        hold.on_release(0x1e, t0);
        assert_eq!(
            hold.press_delay(0x30, t0 + Duration::from_millis(2), gap, Duration::ZERO),
            Duration::from_millis(30)
        );
        assert!(hold
            .press_delay(0x30, t0 + Duration::from_millis(50), gap, Duration::ZERO)
            .is_zero());
    }

    // The very first key, and every key of a chord that is still building (no
    // Release yet — e.g. Shift down, then the letter down), start immediately.
    #[test]
    fn key_gap_never_splits_a_chord_or_delays_the_first_key() {
        let mut hold = KeyHold::default();
        let gap = Duration::from_millis(32);
        let t0 = Instant::now();
        assert!(hold.press_delay(0x1e, t0, gap, Duration::ZERO).is_zero()); // first key ever
        hold.on_press(0x2a, t0); // Shift down
        assert!(hold.press_delay(0x1e, t0, gap, Duration::ZERO).is_zero()); // letter down, same chord
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
        hold.on_release(0x1e, released);
        assert_eq!(
            hold.press_delay(0x30, released, gap, Duration::ZERO),
            Duration::from_millis(32)
        );
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

#[cfg(test)]
#[path = "key_pacing_tests.rs"]
mod pacing_tests;
