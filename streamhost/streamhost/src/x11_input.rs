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

use std::io::Write;
use std::sync::{Arc, Mutex};

use crate::ptr_reckon::Reckoner;
use crate::realtime_input::{AcceptedSeq, PointerAbs, RealtimeInputSink, Reject, SinkHealth};

const X_MOTION_NOTIFY: u8 = 6;
/// Over-large homing delta: with accel disabled the guest cursor clamps hard into
/// the top-left corner, giving a known (0,0) origin to track deltas from.
/// Chunked by `rel_chunks` like any other large delta.
const HOME_DELTA: i32 = -8192;

#[derive(Default)]
struct PtrState {
    reckon: Reckoner,
    buttons: u16,
}

pub struct X11TestSink {
    conn: x11rb::rust_connection::RustConnection,
    cmd_file: String,
    st: Mutex<PtrState>,
}

impl X11TestSink {
    pub fn new(display: &str, cmd_file: &str) -> anyhow::Result<Arc<Self>> {
        use anyhow::Context as _;
        let (conn, _screen) = x11rb::connect(Some(display)).context("x11test connect to Xvfb")?;
        {
            use x11rb::protocol::xtest::ConnectionExt as _;
            conn.xtest_get_version(2, 1)
                .context("XTEST query")?
                .reply()
                .context("XTEST version reply")?;
        }
        eprintln!("[input-router] x11test connected display={display} cmd_file={cmd_file}");
        Ok(Arc::new(Self {
            conn,
            cmd_file: cmd_file.to_string(),
            st: Mutex::new(PtrState::default()),
        }))
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
        self.conn.flush().map_err(|_| Reject::BackendDown)?;

        // BUTTONS: diff vs last applied mask. Wire bit0=L,1=M,2=R.
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
        st.buttons = event.buttons;

        Ok(AcceptedSeq(event.seq))
    }

    fn health(&self) -> SinkHealth {
        SinkHealth::Healthy
    }

    fn backend_name(&self) -> &'static str {
        "x11test"
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
