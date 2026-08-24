//! Input sink for `CaptureBackend::X11` stations whose emulator is MAME driving a
//! guest with a RELATIVE mouse behind an SDL window that fills the whole Xvfb
//! (the SGI IRIX/MAME station, issue #20).
//!
//! Two channels, because MAME-SDL only delivers mouse BUTTONS + keyboard to the
//! machine while the window is pointer-CAPTURED, and capture needs an
//! SDL_WINDOWEVENT_ENTER that can never fire when the window == the whole screen
//! (the pointer can't enter/leave). Pointer MOTION is unaffected (XTest relative
//! motion is focus/capture-independent raw input). So:
//!
//! - MOTION -> XTest RELATIVE injection (root=NONE => the coords are deltas). The
//!   guest runs with acceleration disabled (`xset m 0 0`), so a delta maps ~1:1;
//!   we convert the client's ABSOLUTE target into a delta from the last position,
//!   homing to the origin on the first sample (an over-large negative delta
//!   clamps the guest cursor into the top-left corner => a known origin).
//! - BUTTONS -> a one-command-per-line file the in-MAME Lua agent (irixagent.lua)
//!   consumes+truncates each frame and replays onto the emulated PS/2 mouse
//!   ioport. Every button carries real press/release edges (DOWN1/UP1,
//!   DOWN2/UP2, DOWN3/UP3), which spring-loaded 4Dwm menus require.
//!
//! See docs/history/irix-tile-issue20-handoff.md and the RECIPE on labhost.
//!
//! THREE OPT-IN MODES generalize the sink to any UNPATCHED SDL emulator under
//! Xvfb (proven on FS-UAE 3.1.66 with `--mouse_integration=1`); every existing
//! station keeps the behavior above byte for byte with the envs unset:
//!
//! - `SH_X11TEST_ABS=1`  -> MOTION as TRUE ABSOLUTE XTEST (root window + root
//!   coords). FS-UAE follows the host X cursor 1:1, so there is no homing, no
//!   dead reckoning and no chunking in this mode.
//! - `SH_X11TEST_BUTTONS=xtest` -> buttons (and wheel, one click per event) as
//!   XTEST ButtonPress/ButtonRelease instead of cmd-file lines, stretched by
//!   `SH_BTN_MIN_HOLD_MS` (default 60 ms = three 50 Hz frames): a browser click
//!   whose down/up pair arrives ~0 ms apart is NEVER seen by an emulator that
//!   samples at 50 Hz (measured: a 150-200 ms hold lands reliably, xdotool's
//!   instant click never does), so the pair is stretched, never dropped.
//! - `SH_X11TEST_KEYS=1` -> keyboard as XTEST KeyPress/KeyRelease. Scancode ->
//!   keysym via the embedded US-layout table (override: `SH_X11TEST_KEYMAP`),
//!   keysym -> keycode resolved once at startup from the display's own keyboard
//!   mapping; unmapped keys are rejected+counted, never guessed. Paced by
//!   `SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS` (defaults 40/40 HERE — the envs
//!   being unset must not turn the floor off for a 50 Hz guest).
//!
//! Both paced channels ride ONE dwell pacer (`x11_keys::Pacer`) drained by a
//! background task, so edges of one field can never deadlock or reorder
//! another field's — see the pacer's module doc for the ctlsock lineage.

use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};

use tokio::sync::Notify;

use crate::config::X11TestConfig;
use crate::ptr_reckon::Reckoner;
use crate::realtime_input::{
    AcceptedSeq, KeyEvent, PointerAbs, RealtimeInputSink, Reject, SinkHealth,
};
use crate::x11_keys::{Edge, Field, Pacer};

const X_KEY_PRESS: u8 = 2;
const X_KEY_RELEASE: u8 = 3;
const X_BUTTON_PRESS: u8 = 4;
const X_BUTTON_RELEASE: u8 = 5;
const X_MOTION_NOTIFY: u8 = 6;
/// Over-large homing delta: with accel disabled the guest cursor clamps hard into
/// the top-left corner, giving a known (0,0) origin to track deltas from.
/// Chunked by `rel_chunks` like any other large delta.
const HOME_DELTA: i32 = -8192;

#[derive(Default)]
struct PtrState {
    reckon: Reckoner,
    /// Mask as of the last APPLIED (or successfully enqueued) transition, so a
    /// pacer-Overflow-rejected edge is re-derived by the next accepted event
    /// instead of silently lost.
    buttons: u16,
}

/// The paced-edge channel shared with the background injection task.
struct Paced {
    pacer: Mutex<Pacer>,
    notify: Notify,
}

pub struct X11TestSink {
    conn: x11rb::rust_connection::RustConnection,
    cmd_file: String,
    st: Mutex<PtrState>,
    opts: X11TestConfig,
    /// Root window of the connected screen (absolute-motion target).
    root: u32,
    /// XT set1 scancode -> X keycode, resolved once at startup. Empty unless
    /// `opts.keys`.
    keycodes: std::collections::HashMap<u16, u8>,
    /// Some only when a paced channel (xtest buttons or keys) is active.
    paced: Option<Arc<Paced>>,
    /// Key edges whose scancode has no keycode — counted AND logged per edge,
    /// same rule as the mamesock/vicesock sinks.
    unmapped: AtomicU64,
}

impl X11TestSink {
    pub fn new(display: &str, cmd_file: &str, opts: X11TestConfig) -> anyhow::Result<Arc<Self>> {
        use anyhow::Context as _;
        use x11rb::connection::Connection as _;
        let (conn, screen) = x11rb::connect(Some(display)).context("x11test connect to Xvfb")?;
        {
            use x11rb::protocol::xtest::ConnectionExt as _;
            conn.xtest_get_version(2, 1)
                .context("XTEST query")?
                .reply()
                .context("XTEST version reply")?;
        }
        let root = conn.setup().roots[screen].root;
        let keycodes = if opts.keys {
            resolve_keycodes(&conn).context("x11test keyboard mapping")?
        } else {
            std::collections::HashMap::new()
        };
        eprintln!(
            "[input-router] x11test connected display={display} cmd_file={cmd_file} \
             abs={} buttons={} keys={} ({} scancodes resolved)",
            opts.abs,
            if opts.buttons_xtest {
                "xtest"
            } else {
                "cmdfile"
            },
            opts.keys,
            keycodes.len(),
        );
        let paced = (opts.buttons_xtest || opts.keys).then(|| {
            Arc::new(Paced {
                pacer: Mutex::new(Pacer::new(
                    opts.key_hold_ms,
                    opts.key_gap_ms,
                    opts.btn_hold_ms,
                )),
                notify: Notify::new(),
            })
        });
        let sink = Arc::new(Self {
            conn,
            cmd_file: cmd_file.to_string(),
            st: Mutex::new(PtrState::default()),
            opts,
            root,
            keycodes,
            paced: paced.clone(),
            unmapped: AtomicU64::new(0),
        });
        if let Some(paced) = paced {
            tokio::spawn(paced_inject_task(Arc::downgrade(&sink), paced));
        }
        Ok(sink)
    }

    /// Enqueue one paced edge and wake the drain task. `opts` guarantees
    /// `paced` is Some on every path that calls this.
    fn push_edge(&self, field: Field, down: bool) -> Result<(), Reject> {
        let paced = self.paced.as_ref().ok_or(Reject::Unsupported)?;
        paced
            .pacer
            .lock()
            .map_err(|_| Reject::BackendDown)?
            .push(Edge { field, down })
            .map_err(|_| Reject::Overflow)?;
        paced.notify.notify_one();
        Ok(())
    }

    /// XTEST key/button edge. Root/coords are ignored by the server for these
    /// event types; time 0 = CurrentTime.
    fn fake_edge(&self, edge: Edge) -> Result<(), Reject> {
        use x11rb::protocol::xtest::ConnectionExt as _;
        let (typ, detail) = match edge.field {
            Field::Button(b) => (
                if edge.down {
                    X_BUTTON_PRESS
                } else {
                    X_BUTTON_RELEASE
                },
                b,
            ),
            Field::Key(k) => (
                if edge.down {
                    X_KEY_PRESS
                } else {
                    X_KEY_RELEASE
                },
                k,
            ),
        };
        self.conn
            .xtest_fake_input(typ, detail, 0, x11rb::NONE, 0, 0, 0)
            .map_err(|_| Reject::BackendDown)?;
        Ok(())
    }

    /// XTEST TRUE ABSOLUTE pointer motion: root window + root coordinates
    /// (detail 0). The exact injection `xdotool mousemove` performs, which the
    /// FS-UAE rig proved lands the Amiga pointer at precisely (x, y).
    fn abs_motion(&self, x: i16, y: i16) -> Result<(), Reject> {
        use x11rb::protocol::xtest::ConnectionExt as _;
        self.conn
            .xtest_fake_input(X_MOTION_NOTIFY, 0, 0, self.root, x, y, 0)
            .map_err(|_| Reject::BackendDown)?;
        Ok(())
    }

    /// XTest RELATIVE pointer motion by (dx,dy): root=NONE marks the coords as a
    /// delta from the current pointer position.
    fn rel_motion(&self, dx: i16, dy: i16) -> Result<(), Reject> {
        use x11rb::protocol::xtest::ConnectionExt as _;
        self.conn
            .xtest_fake_input(X_MOTION_NOTIFY, 0, 0, x11rb::NONE, dx, dy, 0)
            .map_err(|_| Reject::BackendDown)?;
        Ok(())
    }

    /// Append one command line to the Lua agent's command file. O_APPEND keeps a
    /// write atomic against the agent's read+truncate for a line this short.
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

impl RealtimeInputSink for X11TestSink {
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject> {
        use x11rb::connection::Connection as _;
        let mut st = self.st.lock().map_err(|_| Reject::BackendDown)?;

        if self.opts.abs {
            // TRUE ABSOLUTE: state the surface-clamped target, nothing else.
            // No homing, no Reckoner, no chunking — the X server owns the
            // cursor and the guest (FS-UAE mouse_integration) follows it 1:1.
            let tx = event
                .x
                .min(event.width.saturating_sub(1))
                .min(i16::MAX as u32);
            let ty = event
                .y
                .min(event.height.saturating_sub(1))
                .min(i16::MAX as u32);
            self.abs_motion(tx as i16, ty as i16)?;
        } else {
            // MOTION: absolute target -> relative delta, with the one-time homing
            // slam and the one-shot edge resync (see ptr_reckon — without the latter
            // a single clamp at a screen edge desyncs this sink from the guest
            // permanently, which was measured at 127 px on the IRIX station).
            let step = st.reckon.step(event.x, event.y, event.width, event.height);
            if step.home {
                for (cx, cy) in rel_chunks(HOME_DELTA, HOME_DELTA) {
                    self.rel_motion(cx, cy)?;
                }
            }
            // Chunk large deltas so a single PS/2 report can't clamp/truncate them
            // (matches the QEMU rel path's MAX_REL_STEP guard).
            for (cx, cy) in rel_chunks(step.dx, step.dy) {
                self.rel_motion(cx, cy)?;
            }
        }
        self.conn.flush().map_err(|_| Reject::BackendDown)?;

        // BUTTONS: diff vs last applied/enqueued mask. Wire bit0=L,1=M,2=R.
        if self.opts.buttons_xtest {
            // XTEST edges through the dwell pacer (never dropped, always
            // stretched to SH_BTN_MIN_HOLD_MS). Wire bit -> X button number:
            // bit0=L->1, bit1=M->2, bit2=R->3, emitted in the cmd path's
            // left/right/middle order. On an Overflow st.buttons keeps the OLD
            // mask, so the missing edge is re-derived by the next event.
            let changed = st.buttons ^ event.buttons;
            for (bit, button) in [(0b001u16, 1u8), (0b100, 3), (0b010, 2)] {
                if changed & bit != 0 {
                    self.push_edge(Field::Button(button), event.buttons & bit != 0)?;
                }
            }
            // WHEEL: one paced click per event, sign only (the warpd sink's
            // convention: up=4, down=5; horizontal left=6, right=7). A wheel
            // click is a press+release pair, so it needs the same stretch a
            // button click does.
            if event.wheel_v != 0 {
                let b = if event.wheel_v < 0 { 4 } else { 5 };
                self.push_edge(Field::Button(b), true)?;
                self.push_edge(Field::Button(b), false)?;
            }
            if event.wheel_h != 0 {
                let b = if event.wheel_h < 0 { 6 } else { 7 };
                self.push_edge(Field::Button(b), true)?;
                self.push_edge(Field::Button(b), false)?;
            }
        } else {
            let changed = st.buttons ^ event.buttons;
            if changed & 0b001 != 0 {
                self.cmd(if event.buttons & 0b001 != 0 {
                    "DOWN1"
                } else {
                    "UP1"
                })?;
            }
            // Right/middle carry real press/release edges (`DOWN2`/`UP2`,
            // `DOWN3`/`UP3`), like left. The agent gained those verbs because 4Dwm
            // menus are spring-loaded and a synthetic click cannot post one; this
            // sink is the rollback path for the same guest, so it must behave
            // identically.
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
        }
        st.buttons = event.buttons;

        Ok(AcceptedSeq(event.seq))
    }

    /// One physical key -> one X keycode, make and break exactly as the browser
    /// reports them; the X server applies the layout (real Shift edges arrive
    /// like any other key). Routed here only when `SH_X11TEST_KEYS=1` — see
    /// input.rs — so the rejection with the flag off changes nothing.
    fn try_key(&self, event: KeyEvent) -> Result<AcceptedSeq, Reject> {
        if !self.opts.keys {
            return Err(Reject::Unsupported);
        }
        let Some(&keycode) = self.keycodes.get(&event.key) else {
            self.unmapped.fetch_add(1, Ordering::Relaxed);
            eprintln!(
                "[x11test] unmapped scancode 0x{:04x} down={} (total {})",
                event.key,
                event.down,
                self.unmapped.load(Ordering::Relaxed)
            );
            return Err(Reject::Unsupported);
        };
        self.push_edge(Field::Key(keycode), event.down)?;
        Ok(AcceptedSeq(event.seq))
    }

    fn health(&self) -> SinkHealth {
        SinkHealth::Healthy
    }

    fn backend_name(&self) -> &'static str {
        "x11test"
    }
}

/// Resolve the scancode->keysym table against the DISPLAY'S OWN keyboard
/// mapping (never a hardcoded keycode guess): one GetKeyboardMapping at
/// startup, then keysym -> first keycode that carries it in any column.
/// A scancode whose keysym the display does not carry is simply absent from
/// the result — rejected+counted per edge at runtime, never folded onto a
/// neighbouring key.
fn resolve_keycodes(
    conn: &x11rb::rust_connection::RustConnection,
) -> anyhow::Result<std::collections::HashMap<u16, u8>> {
    use anyhow::Context as _;
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::ConnectionExt as _;

    let (min, max) = {
        let setup = conn.setup();
        (setup.min_keycode, setup.max_keycode)
    };
    let mapping = conn
        .get_keyboard_mapping(min, max - min + 1)
        .context("GetKeyboardMapping")?
        .reply()
        .context("GetKeyboardMapping reply")?;
    let per = mapping.keysyms_per_keycode as usize;
    let mut keysym_to_code: std::collections::HashMap<u32, u8> = std::collections::HashMap::new();
    for (i, chunk) in mapping.keysyms.chunks(per).enumerate() {
        let keycode = min + i as u8;
        for &sym in chunk {
            if sym != 0 {
                keysym_to_code.entry(sym).or_insert(keycode);
            }
        }
    }

    let table = crate::x11_keys::x11test_keymap();
    let mut out = std::collections::HashMap::new();
    let mut unresolved = 0usize;
    for code in (0u16..=0xff).chain(0xe000..=0xe0ff) {
        let Some(sym) = table.lookup(code, false) else {
            continue;
        };
        match keysym_to_code.get(&sym) {
            Some(&kc) => {
                out.insert(code, kc);
            }
            None => {
                unresolved += 1;
                eprintln!(
                    "[x11test] scancode 0x{code:04x}: keysym 0x{sym:04x} not in the display's \
                     keyboard mapping — key will be rejected"
                );
            }
        }
    }
    if unresolved > 0 {
        eprintln!("[x11test] {unresolved} scancode(s) unresolved against the display keymap");
    }
    Ok(out)
}

/// Drain the dwell pacer and inject ready edges. Holds only a Weak sink ref so
/// the task ends when the sink is dropped; the Notify wakes it on every push
/// and the pacer's own deadline wakes it for a deferred edge.
async fn paced_inject_task(sink: Weak<X11TestSink>, paced: Arc<Paced>) {
    use x11rb::connection::Connection as _;
    loop {
        let notified = paced.notify.notified();
        let (edges, deadline) = {
            let Ok(mut pacer) = paced.pacer.lock() else {
                return;
            };
            pacer.drain(std::time::Instant::now())
        };
        {
            let Some(sink) = sink.upgrade() else { return };
            let n = edges.len();
            for edge in edges {
                if let Err(e) = sink.fake_edge(edge) {
                    eprintln!("[x11test] paced edge injection failed: {e:?}");
                }
            }
            if n > 0 {
                if sink.conn.flush().is_err() {
                    eprintln!("[x11test] flush failed after paced edges");
                }
                crate::input_telemetry::record_inject("x11test", n as u64, 0, None);
            }
        }
        match deadline {
            Some(d) => {
                tokio::select! {
                    _ = notified => {}
                    _ = tokio::time::sleep_until(tokio::time::Instant::from_std(d)) => {}
                }
            }
            None => notified.await,
        }
    }
}

/// Split a (dx,dy) delta into chunks each within the per-report clamp window so a
/// large/fast move can't be truncated by the emulated PS/2 mouse. Small moves are
/// a single chunk (the common case), exactly 1:1.
const MAX_REL_STEP: i32 = 200;
fn rel_chunks(dx: i32, dy: i32) -> Vec<(i16, i16)> {
    if dx == 0 && dy == 0 {
        return Vec::new();
    }
    if dx.abs() <= MAX_REL_STEP && dy.abs() <= MAX_REL_STEP {
        return vec![(dx as i16, dy as i16)];
    }
    let steps = (dx.abs().max(dy.abs()) + MAX_REL_STEP - 1) / MAX_REL_STEP;
    let mut out = Vec::with_capacity(steps as usize);
    let (mut sent_x, mut sent_y) = (0i32, 0i32);
    for i in 1..=steps {
        let tx = dx * i / steps;
        let ty = dy * i / steps;
        out.push(((tx - sent_x) as i16, (ty - sent_y) as i16));
        sent_x = tx;
        sent_y = ty;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::rel_chunks;

    #[test]
    fn small_delta_is_single_chunk() {
        assert_eq!(rel_chunks(0, 0), vec![]);
        assert_eq!(rel_chunks(10, -7), vec![(10, -7)]);
        assert_eq!(rel_chunks(200, -200), vec![(200, -200)]);
    }

    #[test]
    fn large_delta_chunked_and_sums_exactly() {
        for (dx, dy) in [(1000, 0), (0, -900), (1279, 1023), (-8192, -8192)] {
            let chunks = rel_chunks(dx, dy);
            let (mut sx, mut sy) = (0i32, 0i32);
            for (cx, cy) in &chunks {
                assert!(cx.unsigned_abs() as i32 <= super::MAX_REL_STEP);
                assert!(cy.unsigned_abs() as i32 <= super::MAX_REL_STEP);
                sx += *cx as i32;
                sy += *cy as i32;
            }
            assert_eq!((sx, sy), (dx, dy), "chunks must sum to the delta");
        }
    }
}
