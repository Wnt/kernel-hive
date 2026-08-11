//! Window-free input sink for a MAME tile captured over `CaptureBackend::Shm`.
//!
//! The `x11test` sink (see `x11_input.rs`) injects pointer MOTION with XTest and
//! sends only buttons/keys down the Lua agent's command file. That works only
//! while MAME has an X window to receive raw motion. Once MAME runs `-video none`
//! — which is the entire point of the shm capture backend, since the SDL texture
//! upload + llvmpipe blit + X round trip was 32-43% of host time — there is no
//! window, no X server, and nothing for XTest to inject into.
//!
//! So EVERY input event rides the one channel that never depended on a display:
//! the command file that `irixagent.lua` consumes, which writes the emulated PS/2
//! mouse's ioport fields directly (`:ioc2:aux:hle_ps2_mouse:mouse_{x,y}_axis`).
//!
//! POINTER MODE (SH_MAMECMD_ABS, default ON): the sink emits closed-loop
//! `MOVEA x y` TARGETS in emulated framebuffer pixels. The agent reads the
//! ACTUAL guest cursor position from the Newport VC2 hardware-cursor registers
//! each periodic tick, computes the residual error and bleeds paced relative
//! counts (the same MOVEP pacing machinery) until it converges — so there is no
//! homing slam, no edge resync, and accumulated dead-reckoning loss (the "edge
//! hugging" bug) is structurally impossible. The target is restated before
//! every button edge, which makes out-of-band cursor moves (ops scripts, guest
//! warps) self-correct immediately.
//!
//! Everything below about absolute->relative dead reckoning describes the
//! `SH_MAMECMD_ABS=0` ROLLBACK path (and remains the agent-side transport under
//! MOVEA): the dead reckoning is the same one the XTest sink already proved:
//!
//! - the first sample HOMES with an over-large negative delta, clamping the guest
//!   cursor into the top-left corner to establish a known (0,0) origin;
//! - after that each absolute client target becomes a delta from the last one.
//!
//! Dead reckoning requires the guest to apply the delta 1:1, so the golden's
//! `/.sgisession` runs **`xset m 1/1 0`** — NOT `xset m 0 0`, which sets a zero
//! numerator (`acceleration: 0/1`) rather than unity. IRIX otherwise applies
//! ~2.75x horizontal / ~1.77x vertical acceleration above a 4 px threshold,
//! which no constant calibration can undo. Measured on golden v3 at the 4Dwm
//! desktop: 1000 px commanded -> 1000 px moved, three sweeps running.
//!
//! PACING is the agent's job, not ours. `hle_ps2_mouse::sample()` runs at the
//! guest-programmed sample rate (100 Hz by default), reads the axis fields, and
//! transmits the difference as a single **8-bit** value: any delta outside
//! -256..=255 between two samples is truncated on the wire. Splitting a large
//! move into several command lines does NOT help, because the agent consumes
//! every pending line within one periodic tick and the device only ever sees the
//! final field value. Hence the `MOVEP` verb: the agent accumulates the delta and
//! bleeds it out at a bounded number of counts per tick, so an arbitrarily large
//! jump (a homing slam, a teleport across the screen) arrives intact. `MOVE`
//! keeps its original apply-immediately semantics for the ops scripts that use it.
//!
//! The route is LOSSLESS, which is the reason it is worth having beyond the
//! capture win. Every count written to the command file reaches the ioport (the
//! agent queues rather than samples), and the emulated device merges rather than
//! drops when it is busy (`sample()` leaves `m_mouse_x` untouched when it skips,
//! so the delta is delivered later). Measured through the production router at
//! 60 and 200 events/s: commanded counts == counts applied to the ioport ==
//! pixels the cursor moved, exactly, on every sweep. The XTest path it replaces
//! was measured losing 12-16% of motion under load.
//!
//! KEYBOARD rides the same file, as the emulated key MATRIX. MAME's
//! `natkeyboard` is not an option on `indy_4610`: the machine's keyboard is a PC
//! "Microsoft Natural" behind an SGI keymap, and every SHIFTED character is
//! silently dropped — uppercase arrives lowercase, `_ | ~ " < > ? :` never
//! arrive at all — so `POST` appears to work until a visitor types a real path.
//! The browser already sends XT set1 make/break for every physical key including
//! a real Shift, so each scancode maps to exactly one `:ioc2:kbd:ms_naturl`
//! ioport field and the agent presses and releases it. Shift, Ctrl and Alt are
//! not special-cased anywhere: they are fields like any other, which is what
//! makes both `_` and Ctrl-C work. Hold timing is the agent's job (the emulated
//! keyboard polls the matrix on its own clock, so a press and release inside one
//! periodic tick is invisible) — see `KEY` in `irixagent.lua`.

use std::io::Write;
use std::sync::{Arc, Mutex};

use crate::ptr_reckon::Reckoner;
use crate::realtime_input::{
    AcceptedSeq, KeyEvent, PointerAbs, RealtimeInputSink, Reject, SinkHealth,
};

/// Over-large homing delta: the guest cursor clamps hard into the top-left
/// corner, giving a known (0,0) origin to track deltas from. It only has to
/// exceed the surface (1288x1024); -8192 would merely make the one-time drain
/// four times longer.
const HOME_DELTA: i32 = -2048;

/// XT set1 scancode (as the SPA puts it on the wire, `0xe0..` for the extended
/// cluster) -> the `:ioc2:kbd:ms_naturl` matrix port and field name that key
/// occupies. The field names are MAME's own and contain spaces, so the `KEY`
/// verb takes the field as the rest of the line.
///
/// Read out of the live machine with the agent's `KEYDUMP` verb, not guessed —
/// `keys.py`'s hand-dumped table (which this otherwise ports) is missing the
/// whole keypad, Menu, right Meta and Print Screen. A scancode with no field is
/// REJECTED rather than folded onto some neighbouring key.
pub(crate) const KEY_MATRIX: &[(u16, &str, &str)] = &[
    (0x01, "P1.6", "Esc"),
    (0x02, "P1.6", "1"),
    (0x03, "P1.2", "2"),
    (0x04, "P1.4", "3"),
    (0x05, "P1.5", "4"),
    (0x06, "P1.5", "5"),
    (0x07, "P2.0", "6"),
    (0x08, "P2.0", "7"),
    (0x09, "P1.4", "8"),
    (0x0a, "P2.2", "9"),
    (0x0b, "P2.3", "0"),
    (0x0c, "P2.2", "-"),
    (0x0d, "P2.1", "="),
    (0x0e, "P2.1", "Backspace"),
    (0x0f, "P1.6", "Tab"),
    (0x10, "P1.6", "Q"),
    (0x11, "P1.2", "W"),
    (0x12, "P1.4", "E"),
    (0x13, "P1.5", "R"),
    (0x14, "P1.5", "T"),
    (0x15, "P2.0", "Y"),
    (0x16, "P2.0", "U"),
    (0x17, "P1.4", "I"),
    (0x18, "P2.2", "O"),
    (0x19, "P2.3", "P"),
    (0x1a, "P2.2", "["),
    (0x1b, "P2.1", "]"),
    (0x1c, "P2.1", "Enter"),
    (0x1d, "P1.1", "Left Ctrl"),
    (0x1e, "P1.6", "A"),
    (0x1f, "P1.2", "S"),
    (0x20, "P1.4", "D"),
    (0x21, "P1.5", "F"),
    (0x22, "P1.5", "G"),
    (0x23, "P2.0", "H"),
    (0x24, "P2.0", "J"),
    (0x25, "P1.4", "K"),
    (0x26, "P2.2", "L"),
    (0x27, "P2.3", ";"),
    (0x28, "P2.3", "'"),
    (0x29, "P1.6", "`"),
    (0x2a, "P1.7", "Left Shift"),
    (0x2b, "P2.1", "\\"),
    (0x2c, "P1.6", "Z"),
    (0x2d, "P1.2", "X"),
    (0x2e, "P1.4", "C"),
    (0x2f, "P1.5", "V"),
    (0x30, "P1.5", "B"),
    (0x31, "P2.0", "N"),
    (0x32, "P2.0", "M"),
    (0x33, "P1.4", ","),
    (0x34, "P2.2", "."),
    (0x35, "P2.3", "/"),
    (0x36, "P1.7", "Right Shift"),
    (0x37, "P2.7", "Keypad *"),
    (0x38, "P1.3", "Left Alt"),
    (0x39, "P2.4", "Space"),
    (0x3a, "P1.1", "Caps Lock"),
    (0x3b, "P1.2", "F1"),
    (0x3c, "P1.2", "F2"),
    (0x3d, "P2.6", "F3"),
    (0x3e, "P2.6", "F4"),
    (0x3f, "P2.1", "F5"),
    (0x40, "P2.1", "F6"),
    (0x41, "P2.2", "F7"),
    (0x42, "P2.2", "F8"),
    (0x43, "P2.3", "F9"),
    (0x44, "P2.3", "F10"),
    (0x45, "P1.3", "Num Lock"),
    (0x46, "P1.0", "Scroll Lock"),
    (0x47, "P2.7", "Keypad 7"),
    (0x48, "P2.5", "Keypad 8"),
    (0x49, "P2.6", "Keypad 9"),
    (0x4a, "P1.3", "Keypad -"),
    (0x4b, "P2.7", "Keypad 4"),
    (0x4c, "P2.5", "Keypad 5"),
    (0x4d, "P2.6", "Keypad 6"),
    (0x4e, "P2.7", "Keypad +"),
    (0x4f, "P2.7", "Keypad 1"),
    (0x50, "P2.5", "Keypad 2"),
    (0x51, "P2.6", "Keypad 3"),
    (0x52, "P2.5", "Keypad 0"),
    (0x53, "P2.6", "Keypad ."),
    // The ISO 102-key extra key next to left Shift, which MAME names by its
    // scancode. European visitors have it; a US keyboard does not.
    (0x56, "P1.6", "INT1 56"),
    (0x57, "P2.5", "F11"),
    (0x58, "P2.5", "F12"),
    (0xe01c, "P1.0", "Keypad Enter"),
    (0xe01d, "P1.1", "Right Ctrl"),
    (0xe035, "P2.7", "Keypad /"),
    (0xe037, "P2.7", "Print Screen"),
    (0xe038, "P1.3", "Right Alt"),
    (0xe047, "P2.5", "Home"),
    (0xe048, "P2.4", "Cursor Up"),
    (0xe049, "P1.2", "Page Up"),
    (0xe04b, "P2.1", "Cursor Left"),
    (0xe04d, "P2.4", "Cursor Right"),
    (0xe04f, "P2.5", "End"),
    (0xe050, "P2.3", "Cursor Down"),
    (0xe051, "P1.2", "Page Down"),
    (0xe052, "P2.6", "Insert"),
    (0xe053, "P2.6", "Delete"),
    (0xe05b, "P1.0", "Left Win"),
    (0xe05c, "P2.4", "Right Win"),
    (0xe05d, "P2.7", "Menu"),
];

/// Shared with the `mamesock` sink: both routes speak the same matrix.
pub(crate) fn matrix_key(code: u16) -> Option<(&'static str, &'static str)> {
    KEY_MATRIX
        .iter()
        .find(|(c, _, _)| *c == code)
        .map(|(_, port, field)| (*port, *field))
}

/// SH_MAMESOCK_KEYMAP: a per-tile scancode -> (port, field) map, replacing the
/// compiled-in IRIX matrix above — the one piece of the MAME input plane that
/// was machine-specific rather than machine-generic. One row per key:
/// `scancode-hex<TAB>port<TAB>field` (`#` comments, blank lines ignored);
/// field names carry spaces, so the split is on the first two tabs only.
/// Generated per machine by `scripts/dev/mame-keymap.py` from the ctlsock
/// module's own KEYDUMP — never hand-guessed, same rule as the IRIX table.
/// Env unset = the IRIX matrix, byte-identical behavior.
pub(crate) struct KeyMap {
    entries: Vec<(u16, String, String)>,
}

impl KeyMap {
    /// A declared-but-broken keymap fails CLOSED and LOUD: an empty map that
    /// rejects every key, never a silent fall back to the IRIX matrix — keys
    /// landing on some other machine's fields is the failure this exists to
    /// end, not one to reintroduce on a typo.
    pub(crate) fn from_env() -> Option<Arc<KeyMap>> {
        let path = std::env::var("SH_MAMESOCK_KEYMAP").ok()?;
        if path.trim().is_empty() {
            return None;
        }
        match Self::load(&path) {
            Ok(map) => {
                eprintln!(
                    "[input-router] mame keymap: {} keys from {path}",
                    map.entries.len()
                );
                Some(Arc::new(map))
            }
            Err(e) => {
                eprintln!(
                    "[input-router] SH_MAMESOCK_KEYMAP {path}: {e} — keyboard DISABLED \
                     (fail-closed; fix the file, the IRIX matrix is not a fallback)"
                );
                Some(Arc::new(KeyMap {
                    entries: Vec::new(),
                }))
            }
        }
    }

    pub(crate) fn load(path: &str) -> Result<KeyMap, String> {
        let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
        let mut entries: Vec<(u16, String, String)> = Vec::new();
        for (n, raw) in text.lines().enumerate() {
            let line = raw.trim_end();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut it = line.splitn(3, '\t');
            let (Some(code), Some(port), Some(field)) = (it.next(), it.next(), it.next()) else {
                return Err(format!("line {}: want scancode<TAB>port<TAB>field", n + 1));
            };
            let code = u16::from_str_radix(code.trim_start_matches("0x"), 16)
                .map_err(|_| format!("line {}: bad scancode {code:?}", n + 1))?;
            if entries.iter().any(|(c, _, _)| *c == code) {
                return Err(format!("line {}: duplicate scancode {code:#x}", n + 1));
            }
            if port.is_empty() || field.is_empty() {
                return Err(format!("line {}: empty port or field", n + 1));
            }
            entries.push((code, port.to_string(), field.to_string()));
        }
        if entries.is_empty() {
            return Err("no entries".into());
        }
        Ok(KeyMap { entries })
    }

    pub(crate) fn lookup(&self, code: u16) -> Option<(&str, &str)> {
        self.entries
            .iter()
            .find(|(c, _, _)| *c == code)
            .map(|(_, port, field)| (port.as_str(), field.as_str()))
    }
}

/// The one lookup both MAME sinks route through: the tile's keymap when one
/// is declared, the IRIX matrix otherwise.
pub(crate) fn key_for(map: &Option<Arc<KeyMap>>, code: u16) -> Option<(&str, &str)> {
    match map {
        Some(m) => m.lookup(code),
        None => matrix_key(code),
    }
}

#[derive(Default)]
struct PtrState {
    reckon: Reckoner,
    buttons: u16,
}

pub struct MameCmdSink {
    cmd_file: String,
    /// SH_MAMECMD_ABS: true = closed-loop MOVEA targets (default), false =
    /// dead-reckoned MOVEP deltas (rollback). Frozen at construction like every
    /// other sink's config; tests pass the mode explicitly and never touch env.
    abs_mode: bool,
    /// Per-tile keymap (SH_MAMESOCK_KEYMAP); None = the IRIX matrix.
    keymap: Option<Arc<KeyMap>>,
    st: Mutex<PtrState>,
}

impl MameCmdSink {
    pub fn new(cmd_file: &str, abs_mode: bool, keymap: Option<Arc<KeyMap>>) -> Arc<Self> {
        eprintln!(
            "[input-router] mamecmd sink cmd_file={cmd_file} mode={}",
            if abs_mode {
                "abs(MOVEA)"
            } else {
                "reckon(MOVEP)"
            }
        );
        Arc::new(Self {
            cmd_file: cmd_file.to_string(),
            abs_mode,
            keymap,
            st: Mutex::new(PtrState::default()),
        })
    }

    /// Append one command line. O_APPEND keeps a write atomic against the agent's
    /// forward-reading consumer for a line this short.
    fn cmd(&self, line: &str) -> Result<(), Reject> {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.cmd_file)
            .map_err(|_| Reject::BackendDown)?;
        writeln!(f, "{line}").map_err(|_| Reject::BackendDown)?;
        Ok(())
    }
}

impl RealtimeInputSink for MameCmdSink {
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject> {
        let mut st = self.st.lock().map_err(|_| Reject::BackendDown)?;

        if self.abs_mode {
            // Closed loop: send the surface-clamped TARGET; the agent reads the
            // actual VC2 cursor position each tick and bleeds paced counts until
            // it converges, so no homing slam and no edge resync are needed.
            // Emitted UNCONDITIONALLY (even for button/wheel-only events at an
            // unchanged coordinate): restating the target before every click is
            // what makes out-of-band cursor moves (ops scripts, guest warps)
            // self-correct immediately instead of after REHOME_IDLE.
            let tx = event.x.min(event.width.saturating_sub(1));
            let ty = event.y.min(event.height.saturating_sub(1));
            self.cmd(&format!("MOVEA {tx} {ty}"))?;
        } else {
            // Absolute -> relative, including the one-time homing slam and the
            // one-shot edge resync (see ptr_reckon).
            let step = st.reckon.step(event.x, event.y, event.width, event.height);
            if step.home {
                // A SEPARATE command, never merged with the delta below: the agent
                // drains its queue head-first, so the homing overshoot is spent
                // against the guest's clamp before the real move starts. Summed into
                // one delta it would cancel part of that overshoot instead.
                self.cmd(&format!("MOVEP {HOME_DELTA} {HOME_DELTA}"))?;
            }
            if step.dx != 0 || step.dy != 0 {
                self.cmd(&format!("MOVEP {} {}", step.dx, step.dy))?;
            }
        }

        // BUTTONS: diff vs last applied mask. Wire bit0=L,1=M,2=R.
        let changed = st.buttons ^ event.buttons;
        if changed & 0b001 != 0 {
            self.cmd(if event.buttons & 0b001 != 0 {
                "DOWN1"
            } else {
                "UP1"
            })?;
        }
        // Right and middle carry REAL press/release edges, exactly like left.
        // They used to fire a synthetic `CLICK2`/`CLICK3` on the down edge and
        // throw the visitor's release away, which cannot drive this guest: 4Dwm
        // menus are SPRING-LOADED — the root menu and the Toolchest stay posted
        // only while the button is held, and the item under the pointer is
        // chosen on release. A synthetic click therefore opened the root menu
        // and closed it again within a few frames, which is what a visitor saw.
        // Discarding a release is also a correctness hazard in its own right:
        // the guest's button state must never be able to drift from the
        // browser's, or the guest is left holding a phantom button.
        if changed & 0b100 != 0 {
            self.cmd(if event.buttons & 0b100 != 0 {
                "DOWN2"
            } else {
                "UP2"
            })?; // right
        }
        if changed & 0b010 != 0 {
            self.cmd(if event.buttons & 0b010 != 0 {
                "DOWN3"
            } else {
                "UP3"
            })?; // middle
        }
        st.buttons = event.buttons;

        Ok(AcceptedSeq(event.seq))
    }

    /// One physical key -> one matrix field, make and break exactly as the
    /// browser reports them. `repeat` is deliberately forwarded as a plain
    /// down: the agent coalesces a press of an already-pressed field away, so
    /// IRIX generates its own auto-repeat from the held matrix bit instead of
    /// the browser's rate fighting the guest's.
    fn try_key(&self, event: KeyEvent) -> Result<AcceptedSeq, Reject> {
        let Some((port, field)) = key_for(&self.keymap, event.key) else {
            return Err(Reject::Unsupported);
        };
        let line = format!("KEY {} {port} {field}", u8::from(event.down));
        self.cmd(&line)?;
        Ok(AcceptedSeq(event.seq))
    }

    fn health(&self) -> SinkHealth {
        SinkHealth::Healthy
    }

    fn backend_name(&self) -> &'static str {
        "mamecmd"
    }
}

#[cfg(test)]
mod tests {
    use super::{key_for, matrix_key, KeyMap, MameCmdSink, KEY_MATRIX};
    use crate::realtime_input::{KeyEvent, PointerAbs, RealtimeInputSink, Reject};
    use std::sync::Arc;

    fn key(seq: u64, code: u16, down: bool) -> KeyEvent {
        KeyEvent {
            seq,
            key: code,
            down,
            repeat: false,
            modifiers: 0,
        }
    }

    fn ev(seq: u64, x: u32, y: u32, buttons: u16) -> PointerAbs {
        PointerAbs {
            seq,
            x,
            y,
            width: 1288,
            height: 1024,
            buttons,
            wheel_v: 0,
            wheel_h: 0,
            ordered: false,
        }
    }

    /// The rollback-path (SH_MAMECMD_ABS=0) wire contract with `irixagent.lua`:
    /// home once, then pure deltas, with button edges interleaved in order.
    #[test]
    fn homes_once_then_emits_exact_deltas() {
        let dir = std::env::temp_dir().join(format!("mamecmd-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cmd");
        let _ = std::fs::remove_file(&path);
        let sink = MameCmdSink::new(path.to_str().unwrap(), false, None);

        sink.try_pointer_abs(ev(1, 100, 50, 0)).unwrap();
        sink.try_pointer_abs(ev(2, 140, 50, 1)).unwrap();
        sink.try_pointer_abs(ev(3, 140, 50, 0)).unwrap();
        // Clamped to the last addressable pixel of the surface.
        sink.try_pointer_abs(ev(4, 9999, 9999, 0)).unwrap();

        let lines: Vec<String> = std::fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        assert_eq!(
            lines,
            vec![
                "MOVEP -2048 -2048",
                "MOVEP 100 50",
                "MOVEP 40 0",
                "DOWN1",
                "UP1",
                // Target clamps to the bottom-right corner, so the delta carries
                // a one-shot full-surface slam in each axis to resync the guest.
                "MOVEP 2435 1997",
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Rollback path (SH_MAMECMD_ABS=0): entering a screen edge must carry a
    /// one-shot full-surface slam so the clamping guest and our dead-reckoned
    /// model cannot drift apart there — and parking on the edge must NOT keep
    /// queueing slams.
    #[test]
    fn edge_entry_slams_once_and_leaving_is_a_plain_delta() {
        let dir = std::env::temp_dir().join(format!("mamecmd-edge-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cmd");
        let _ = std::fs::remove_file(&path);
        let sink = MameCmdSink::new(path.to_str().unwrap(), false, None);

        sink.try_pointer_abs(ev(1, 500, 500, 0)).unwrap();
        sink.try_pointer_abs(ev(2, 0, 500, 0)).unwrap(); // enter left edge
        sink.try_pointer_abs(ev(3, 0, 400, 0)).unwrap(); // parked on it
        sink.try_pointer_abs(ev(4, 300, 400, 0)).unwrap(); // leave it

        let lines: Vec<String> = std::fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        assert_eq!(
            lines,
            vec![
                "MOVEP -2048 -2048",
                "MOVEP 500 500",
                "MOVEP -1788 0", // -500 plus a 1288-wide slam into the edge
                "MOVEP 0 -100",  // still on the edge: no second slam
                "MOVEP 300 0",
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 4Dwm's root menu is spring-loaded: it stays posted only while the button
    /// is held and the item is chosen on release. So right and middle must put
    /// a real press AND a real release on the wire, not a synthetic click —
    /// here in the production-default abs mode. The duplicate MOVEA lines at an
    /// unchanged coordinate are the deliberate restate-before-click property:
    /// every button edge rides behind a fresh statement of the target, so a
    /// stationary out-of-band cursor move is corrected before the click lands.
    #[test]
    fn right_and_middle_carry_press_and_release_edges() {
        let dir = std::env::temp_dir().join(format!("mamecmd-btn-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cmd");
        let _ = std::fs::remove_file(&path);
        let sink = MameCmdSink::new(path.to_str().unwrap(), true, None);

        // Wire bit0=L, bit1=M, bit2=R. Press right, drag, release right.
        sink.try_pointer_abs(ev(1, 500, 500, 0)).unwrap();
        sink.try_pointer_abs(ev(2, 500, 500, 0b100)).unwrap();
        sink.try_pointer_abs(ev(3, 520, 540, 0b100)).unwrap();
        sink.try_pointer_abs(ev(4, 520, 540, 0)).unwrap();
        // Middle, same shape.
        sink.try_pointer_abs(ev(5, 520, 540, 0b010)).unwrap();
        sink.try_pointer_abs(ev(6, 520, 540, 0)).unwrap();

        let lines: Vec<String> = std::fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        assert_eq!(
            lines,
            vec![
                "MOVEA 500 500",
                "MOVEA 500 500",
                "DOWN2",
                "MOVEA 520 540",
                "MOVEA 520 540",
                "UP2",
                "MOVEA 520 540",
                "DOWN3",
                "MOVEA 520 540",
                "UP3",
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Abs mode (SH_MAMECMD_ABS on, the production default): every pointer
    /// event states a surface-clamped MOVEA target — no homing slam, no edge
    /// resync, no MOVEP ever — with button edges interleaved after the target
    /// they should land on.
    #[test]
    fn abs_mode_emits_clamped_movea_targets() {
        let dir = std::env::temp_dir().join(format!("mamecmd-abs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cmd");
        let _ = std::fs::remove_file(&path);
        let sink = MameCmdSink::new(path.to_str().unwrap(), true, None);

        sink.try_pointer_abs(ev(1, 100, 50, 0)).unwrap();
        sink.try_pointer_abs(ev(2, 140, 50, 1)).unwrap();
        sink.try_pointer_abs(ev(3, 140, 50, 0)).unwrap();
        // Clamps to the last addressable pixel of the 1288x1024 surface.
        sink.try_pointer_abs(ev(4, 9999, 9999, 0)).unwrap();
        // The origin is a plain target too, not a slam.
        sink.try_pointer_abs(ev(5, 0, 0, 0)).unwrap();

        let lines: Vec<String> = std::fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        assert_eq!(
            lines,
            vec![
                "MOVEA 100 50",
                "MOVEA 140 50",
                "DOWN1",
                "MOVEA 140 50",
                "UP1",
                "MOVEA 1287 1023",
                "MOVEA 0 0",
            ]
        );
        assert!(
            lines.iter().all(|l| !l.starts_with("MOVEP")),
            "abs mode must never emit a dead-reckoned MOVEP"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The shifted characters natkeyboard silently eats are the whole reason
    /// this path exists: `_` is Shift+`-`, and the browser sends the Shift
    /// make/break itself, so the wire is four plain matrix events. Ctrl-C is
    /// the same shape with a different modifier field.
    #[test]
    fn shifted_and_ctrl_chords_are_plain_matrix_events() {
        let dir = std::env::temp_dir().join(format!("mamecmd-key-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cmd");
        let _ = std::fs::remove_file(&path);
        let sink = MameCmdSink::new(path.to_str().unwrap(), true, None);

        // Shift+'-' => '_'
        sink.try_key(key(1, 0x2a, true)).unwrap();
        sink.try_key(key(2, 0x0c, true)).unwrap();
        sink.try_key(key(3, 0x0c, false)).unwrap();
        sink.try_key(key(4, 0x2a, false)).unwrap();
        // Ctrl-C
        sink.try_key(key(5, 0x1d, true)).unwrap();
        sink.try_key(key(6, 0x2e, true)).unwrap();
        sink.try_key(key(7, 0x2e, false)).unwrap();
        sink.try_key(key(8, 0x1d, false)).unwrap();

        let lines: Vec<String> = std::fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        assert_eq!(
            lines,
            vec![
                "KEY 1 P1.7 Left Shift",
                "KEY 1 P2.2 -",
                "KEY 0 P2.2 -",
                "KEY 0 P1.7 Left Shift",
                "KEY 1 P1.1 Left Ctrl",
                "KEY 1 P1.4 C",
                "KEY 0 P1.4 C",
                "KEY 0 P1.1 Left Ctrl",
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A key this matrix does not have (keypad digits, Menu, right Meta) is
    /// rejected, never mapped onto some other field.
    #[test]
    fn unmapped_scancodes_are_rejected_not_guessed() {
        let dir = std::env::temp_dir().join(format!("mamecmd-unmapped-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cmd");
        let _ = std::fs::remove_file(&path);
        let sink = MameCmdSink::new(path.to_str().unwrap(), true, None);
        // Pause/Break (no single set1 code), the Korean/Japanese IME keys, and
        // anything the SPA could not resolve at all.
        for code in [0x00u16, 0x59, 0x70, 0x7b, 0xe011, 0xe05e] {
            assert_eq!(sink.try_key(key(1, code, true)), Err(Reject::Unsupported));
        }
        assert!(std::fs::read_to_string(&path)
            .unwrap_or_default()
            .is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The `KEY` verb takes the field name as the REST of the line, so no field
    /// may contain a newline and every scancode must be unique — a duplicate
    /// would shadow the later entry in the linear lookup.
    #[test]
    fn matrix_table_is_unique_and_line_safe() {
        let mut codes: Vec<u16> = KEY_MATRIX.iter().map(|(c, _, _)| *c).collect();
        codes.sort_unstable();
        let before = codes.len();
        codes.dedup();
        assert_eq!(codes.len(), before, "duplicate scancode in KEY_MATRIX");
        for (_, port, field) in KEY_MATRIX {
            assert!(!port.contains(' ') && !port.is_empty());
            assert!(!field.contains('\n') && !field.is_empty());
        }
        assert_eq!(matrix_key(0x39), Some(("P2.4", "Space")));
        assert_eq!(matrix_key(0xe048), Some(("P2.4", "Cursor Up")));
        assert_eq!(matrix_key(0x52), Some(("P2.5", "Keypad 0")));
    }

    /// The per-tile keymap: loads, looks up, and REFUSES malformed input —
    /// a broken declared keymap must never degrade to the IRIX matrix.
    #[test]
    fn keymap_loads_and_fails_closed() {
        let dir = std::env::temp_dir().join(format!("keymap-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("st.keymap");
        let p = path.to_str().unwrap();

        std::fs::write(
            &path,
            "# ST\n0x10\t:keyboard:P0\tQ\n0xe048\t:keyboard:P4\tUp\n",
        )
        .unwrap();
        let map = KeyMap::load(p).unwrap();
        assert_eq!(map.lookup(0x10), Some((":keyboard:P0", "Q")));
        assert_eq!(map.lookup(0xe048), Some((":keyboard:P4", "Up")));
        assert_eq!(map.lookup(0x11), None);

        for bad in [
            "0x10\t:k\tQ\n0x10\t:k\tW\n", // duplicate scancode
            "0x10 :k Q\n",                // spaces, not tabs
            "zz\t:k\tQ\n",                // unparsable scancode
            "0x10\t\tQ\n",                // empty port
            "# only comments\n",          // no entries at all
        ] {
            std::fs::write(&path, bad).unwrap();
            assert!(KeyMap::load(p).is_err(), "must refuse: {bad:?}");
        }
    }

    /// `key_for` routes through the declared map when present — including its
    /// misses — and only uses the IRIX matrix when no map is declared.
    #[test]
    fn key_for_prefers_the_declared_map() {
        let dir = std::env::temp_dir().join(format!("keyfor-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("one.keymap");
        std::fs::write(&path, "0x10\t:kbd:X\tSt Q\n").unwrap();
        let map = Some(Arc::new(KeyMap::load(path.to_str().unwrap()).unwrap()));

        assert_eq!(key_for(&map, 0x10), Some((":kbd:X", "St Q")));
        // 0x39 is Space in the IRIX matrix; the declared map does not carry it
        // and must NOT fall through.
        assert_eq!(key_for(&map, 0x39), None);
        assert_eq!(key_for(&None, 0x39), Some(("P2.4", "Space")));
    }
}
