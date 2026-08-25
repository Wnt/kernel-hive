//! Keyboard/button support for the `x11test` input sink: the XT-set1-scancode
//! -> X keysym table and the dwell pacer that stretches edges an emulator
//! sampling at 50 Hz would otherwise never see.
//!
//! THE TABLE reuses the vice-native format and file: the built-in default is
//! `stations/vice-native/us-layout.keysyms` embedded at compile time (already
//! the contract with the SPA's scancode vocabulary — see the vice_keymap
//! tests), and `SH_X11TEST_KEYMAP` may name a replacement in the same format.
//! Only the PLAIN column is consulted: XTEST presses PHYSICAL keys, the X
//! server's own layout applies the shift level because the browser sends real
//! Shift make/break edges — so unlike the vicesock sink there is no shift
//! substitution here. XT 0xe05b/0xe05c (LWin/RWin) map to Super_L/Super_R,
//! which FS-UAE maps to Left/Right Amiga.
//!
//! THE PACER mirrors the semantics of `drain_keys()` in the ctlsock module
//! (`scripts/build-guests/emulators/mamectl/.../ctlsock.cpp`) as they apply
//! WITHOUT exclusive-scan mode — which is the mode that applies here: XTEST
//! feeds an SDL emulator's event queue, not a ROM-scanned matrix. That means
//! per-field dwell gates with per-field ordering ONLY: a release waits HOLD
//! after its own field's press, a re-press waits GAP after its own field's
//! release, and edges of OTHER fields flow freely past a waiting one — the
//! rule that keeps a stretched dwell on key A from deadlocking or delaying
//! key B (strict arrival order wedges on real, overlapping typing; see the
//! three-barrier commentary in ctlsock.cpp and docs/lab/DEBRIDGE-HANDOVER.md).
//! Cross-field edges are never REORDERED relative to their own field, and a
//! modifier is a field like any other: its press goes out the pass it
//! arrives, so it is already down when the character it belongs to follows.
//! Pure and time-injected so the state machine is unit-testable.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::vice_keymap::ViceKeyMap;

/// Bound on queued-but-unpaced edges. Generous: at the default 40/40 pacing a
/// full queue is ~5 s of typing backlog, and a visitor cannot produce that
/// without pasting; beyond it the offer is rejected as Overflow like every
/// other sink's bounded ordered queue.
pub(crate) const PACER_CAPACITY: usize = 128;

/// The generated US-layout table, embedded so the backend works with no
/// per-station file. Regenerate with `scripts/dev/vice-keymap.py`; never edit.
const BUILTIN_TABLE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../stations/vice-native/us-layout.keysyms"
));

pub(crate) fn builtin_keymap() -> ViceKeyMap {
    ViceKeyMap::parse(BUILTIN_TABLE).expect("embedded us-layout.keysyms must parse")
}

/// `SH_X11TEST_KEYMAP`: optional replacement table, same generated format.
/// Fail CLOSED and LOUD like the mamesock/vicesock keymaps: a declared-but-
/// broken file yields an empty map that rejects every key, never a silent
/// fall back to the built-in table. Unset = the built-in US-layout table.
pub(crate) fn x11test_keymap() -> Arc<ViceKeyMap> {
    let Some(path) = std::env::var("SH_X11TEST_KEYMAP")
        .ok()
        .filter(|p| !p.trim().is_empty())
    else {
        return Arc::new(builtin_keymap());
    };
    match ViceKeyMap::load(&path) {
        Ok(map) => {
            eprintln!("[input-router] x11test keymap: {path}");
            Arc::new(map)
        }
        Err(e) => {
            eprintln!(
                "[input-router] SH_X11TEST_KEYMAP {path}: {e} — keyboard DISABLED \
                 (fail-closed; the built-in table is not a fallback)"
            );
            Arc::new(ViceKeyMap::empty())
        }
    }
}

/// What the pacer paces: one X keycode or one X pointer button. The dwell
/// gates and the ordering guarantee are per-field.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Field {
    /// X keycode (already resolved from scancode -> keysym -> keycode).
    Key(u8),
    /// X pointer button number (1=left, 2=middle, 3=right, 4/5=wheel).
    Button(u8),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Edge {
    pub(crate) field: Field,
    pub(crate) down: bool,
}

/// The dwell state machine. `push` enqueues in arrival order; `drain(now)`
/// returns the edges ready to inject NOW plus the earliest instant a deferred
/// edge becomes ready (the caller's sleep deadline).
pub(crate) struct Pacer {
    queue: VecDeque<Edge>,
    down_at: HashMap<Field, Instant>,
    up_at: HashMap<Field, Instant>,
    key_hold: Duration,
    key_gap: Duration,
    /// Buttons use ONE knob for both directions (SH_BTN_MIN_HOLD_MS): the
    /// press-to-release dwell and the release-to-next-press gap.
    btn_hold: Duration,
}

impl Pacer {
    pub(crate) fn new(key_hold_ms: u64, key_gap_ms: u64, btn_hold_ms: u64) -> Self {
        Self {
            queue: VecDeque::new(),
            down_at: HashMap::new(),
            up_at: HashMap::new(),
            key_hold: Duration::from_millis(key_hold_ms),
            key_gap: Duration::from_millis(key_gap_ms),
            btn_hold: Duration::from_millis(btn_hold_ms),
        }
    }

    /// The dwell an edge owes, measured from the OPPOSITE edge of its own
    /// field: a press waits GAP after its field's last release, a release
    /// waits HOLD after its field's last press.
    fn dwell(&self, field: Field, down: bool) -> Duration {
        match (field, down) {
            (Field::Button(_), _) => self.btn_hold,
            (Field::Key(_), true) => self.key_gap,
            (Field::Key(_), false) => self.key_hold,
        }
    }

    /// Enqueue one edge; `Err(())` when the bounded queue is full (the caller
    /// rejects the offer as Overflow — the diff-against-enqueued mask re-derives
    /// a rejected button edge on the next accepted event).
    pub(crate) fn push(&mut self, edge: Edge) -> Result<(), ()> {
        if self.queue.len() >= PACER_CAPACITY {
            return Err(());
        }
        self.queue.push_back(edge);
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    /// One drain pass at `now`. An edge still inside its own field's dwell
    /// blocks LATER EDGES OF THAT FIELD ONLY (per-field order can never
    /// invert); every other field's edges apply the pass they arrive. Applied
    /// edges stamp their gate time with `now`, so a press+release pair pushed
    /// together emits the press and returns `now + hold` as the deadline for
    /// the release.
    pub(crate) fn drain(&mut self, now: Instant) -> (Vec<Edge>, Option<Instant>) {
        let mut out = Vec::new();
        let mut blocked: HashSet<Field> = HashSet::new();
        let mut deadline: Option<Instant> = None;
        let mut i = 0;
        while i < self.queue.len() {
            let e = self.queue[i];
            if blocked.contains(&e.field) {
                i += 1;
                continue;
            }
            let gate = if e.down {
                self.up_at.get(&e.field)
            } else {
                self.down_at.get(&e.field)
            };
            if let Some(ready) = gate
                .map(|t| *t + self.dwell(e.field, e.down))
                .filter(|ready| *ready > now)
            {
                blocked.insert(e.field);
                deadline = Some(deadline.map_or(ready, |d| d.min(ready)));
                i += 1;
                continue;
            }
            if e.down {
                self.down_at.insert(e.field, now);
            } else {
                self.up_at.insert(e.field, now);
            }
            out.push(e);
            self.queue.remove(i);
        }
        (out, deadline)
    }
}

#[cfg(test)]
mod tests {
    use super::{builtin_keymap, Edge, Field, Pacer, PACER_CAPACITY};
    use std::time::{Duration, Instant};

    fn key(k: u8, down: bool) -> Edge {
        Edge {
            field: Field::Key(k),
            down,
        }
    }

    fn btn(b: u8, down: bool) -> Edge {
        Edge {
            field: Field::Button(b),
            down,
        }
    }

    /// Every printable ASCII character must be typeable on the built-in table:
    /// either its keysym is a PLAIN entry, or it is the US-layout SHIFTED
    /// keysym of a key whose plain entry exists (the browser sends the real
    /// Shift edges; the X server applies the level).
    #[test]
    fn builtin_table_covers_printable_ascii() {
        let map = builtin_keymap();
        let plain_exists = |sym: u32| {
            (0u16..=0xff)
                .chain(0xe000..=0xe0ff)
                .any(|c| map.lookup(c, false) == Some(sym))
        };
        let shifted_exists = |sym: u32| {
            (0u16..=0xff)
                .chain(0xe000..=0xe0ff)
                .any(|c| map.lookup(c, true) == Some(sym))
        };
        for ch in 0x20u32..=0x7e {
            assert!(
                plain_exists(ch) || shifted_exists(ch),
                "printable ASCII {ch:#04x} ({:?}) unreachable from the built-in table",
                char::from_u32(ch).unwrap()
            );
        }
    }

    /// The keys the task names must all resolve, including the Amiga keys.
    #[test]
    fn builtin_table_has_the_named_keys() {
        let map = builtin_keymap();
        for (code, sym) in [
            (0x0001u16, 0xff1bu32), // Esc
            (0x000e, 0xff08),       // Backspace
            (0x000f, 0xff09),       // Tab
            (0x001c, 0xff0d),       // Enter
            (0x0039, 0x0020),       // Space
            (0x002a, 0xffe1),       // Shift_L
            (0x0036, 0xffe2),       // Shift_R
            (0x001d, 0xffe3),       // Control_L
            (0xe01d, 0xffe4),       // Control_R
            (0x0038, 0xffe9),       // Alt_L
            (0xe038, 0xffea),       // Alt_R
            (0x003b, 0xffbe),       // F1
            (0x0058, 0xffc9),       // F12
            (0xe048, 0xff52),       // Up
            (0xe050, 0xff54),       // Down
            (0xe04b, 0xff51),       // Left
            (0xe04d, 0xff53),       // Right
            (0xe047, 0xff50),       // Home
            (0xe04f, 0xff57),       // End
            (0xe049, 0xff55),       // PgUp
            (0xe051, 0xff56),       // PgDn
            (0xe052, 0xff63),       // Insert
            (0xe053, 0xffff),       // Delete
            (0x0052, 0xffb0),       // KP_0
            (0xe05b, 0xffeb),       // LWin -> Super_L (Left Amiga)
            (0xe05c, 0xffec),       // RWin -> Super_R (Right Amiga)
        ] {
            assert_eq!(map.lookup(code, false), Some(sym), "scancode {code:#06x}");
        }
    }

    /// The core dwell contract: a press+release pair pushed together emits the
    /// press at once, defers the release the full HOLD, and a re-press then
    /// owes GAP after that release — the browser's ~0 ms click stretched,
    /// never dropped.
    #[test]
    fn instant_click_is_stretched_to_hold_and_gap() {
        let mut p = Pacer::new(40, 40, 60);
        let t0 = Instant::now();
        p.push(btn(1, true)).unwrap();
        p.push(btn(1, false)).unwrap();

        let (out, deadline) = p.drain(t0);
        assert_eq!(out, vec![btn(1, true)]);
        assert_eq!(deadline, Some(t0 + Duration::from_millis(60)));
        // Still inside the hold: nothing emits, the deadline stands.
        let (out, deadline) = p.drain(t0 + Duration::from_millis(30));
        assert!(out.is_empty());
        assert_eq!(deadline, Some(t0 + Duration::from_millis(60)));
        // Hold elapsed: the release goes out.
        let t1 = t0 + Duration::from_millis(60);
        let (out, deadline) = p.drain(t1);
        assert_eq!(out, vec![btn(1, false)]);
        assert_eq!(deadline, None);
        // An immediate double-click's second press owes the gap.
        p.push(btn(1, true)).unwrap();
        let (out, deadline) = p.drain(t1 + Duration::from_millis(1));
        assert!(out.is_empty());
        assert_eq!(deadline, Some(t1 + Duration::from_millis(60)));
        let (out, _) = p.drain(t1 + Duration::from_millis(60));
        assert_eq!(out, vec![btn(1, true)]);
    }

    /// A slow, human-paced key adds NO latency: its release is past the hold
    /// already and applies the pass it arrives.
    #[test]
    fn slow_edges_are_not_delayed() {
        let mut p = Pacer::new(40, 40, 60);
        let t0 = Instant::now();
        p.push(key(38, true)).unwrap();
        assert_eq!(p.drain(t0).0, vec![key(38, true)]);
        p.push(key(38, false)).unwrap();
        let (out, deadline) = p.drain(t0 + Duration::from_millis(200));
        assert_eq!(out, vec![key(38, false)]);
        assert_eq!(deadline, None);
    }

    /// The anti-deadlock rule from the ctlsock drain: key A's dwell-deferred
    /// release must not block key B's edges — other fields flow freely — while
    /// A's own later edges stay strictly behind its deferred one.
    #[test]
    fn a_stretched_dwell_never_blocks_or_reorders_another_field() {
        let mut p = Pacer::new(40, 40, 60);
        let t0 = Instant::now();
        // Overlapped typing: A down, B down, A up, B up — all within 1 ms.
        p.push(key(10, true)).unwrap();
        p.push(key(11, true)).unwrap();
        p.push(key(10, false)).unwrap();
        p.push(key(11, false)).unwrap();
        let (out, _) = p.drain(t0);
        // Both presses apply at once; both releases owe their own hold.
        assert_eq!(out, vec![key(10, true), key(11, true)]);
        // A re-press of A queued BEHIND its deferred release must not pass it.
        p.push(key(10, true)).unwrap();
        let (out, _) = p.drain(t0 + Duration::from_millis(40));
        assert_eq!(out, vec![key(10, false), key(11, false)]);
        // ...and applies only after A's release plus its gap.
        assert!(p.drain(t0 + Duration::from_millis(50)).0.is_empty());
        assert_eq!(
            p.drain(t0 + Duration::from_millis(80)).0,
            vec![key(10, true)]
        );
        assert!(p.is_empty());
    }

    /// A modifier is a field like any other: Shift's press flows out ahead of
    /// the character even while the PREVIOUS character's release sits in its
    /// dwell — the level is already down when the character applies, and no
    /// cross-field barrier exists to hold it back (this sink feeds an SDL
    /// event queue, not a ROM-scanned matrix).
    #[test]
    fn modifier_press_flows_past_another_keys_dwell() {
        let mut p = Pacer::new(40, 40, 60);
        let t0 = Instant::now();
        p.push(key(20, true)).unwrap(); // character 1 down
        p.push(key(20, false)).unwrap(); // character 1 up (will defer)
        p.push(key(50, true)).unwrap(); // Shift down
        p.push(key(21, true)).unwrap(); // character 2 down
        let (out, _) = p.drain(t0);
        assert_eq!(out, vec![key(20, true), key(50, true), key(21, true)]);
        let (out, _) = p.drain(t0 + Duration::from_millis(40));
        assert_eq!(out, vec![key(20, false)]);
    }

    /// Keys and buttons pace independently, buttons with their own knob for
    /// both directions.
    #[test]
    fn buttons_and_keys_have_independent_gates() {
        let mut p = Pacer::new(40, 40, 100);
        let t0 = Instant::now();
        p.push(btn(1, true)).unwrap();
        p.push(btn(1, false)).unwrap();
        p.push(key(30, true)).unwrap();
        p.push(key(30, false)).unwrap();
        let (out, _) = p.drain(t0);
        assert_eq!(out, vec![btn(1, true), key(30, true)]);
        // Key hold (40) elapses before button hold (100).
        let (out, deadline) = p.drain(t0 + Duration::from_millis(40));
        assert_eq!(out, vec![key(30, false)]);
        assert_eq!(deadline, Some(t0 + Duration::from_millis(100)));
        let (out, _) = p.drain(t0 + Duration::from_millis(100));
        assert_eq!(out, vec![btn(1, false)]);
    }

    /// The queue is bounded; the overflow surfaces as a rejection, and edges
    /// already queued are unharmed.
    #[test]
    fn queue_overflow_rejects_the_push() {
        let mut p = Pacer::new(40, 40, 60);
        for _ in 0..PACER_CAPACITY / 2 {
            p.push(key(9, true)).unwrap();
            p.push(key(9, false)).unwrap();
        }
        assert!(p.push(key(9, true)).is_err());
        let (out, _) = p.drain(Instant::now());
        assert_eq!(out.len(), 1, "head press applies; the rest pace out");
    }
}
