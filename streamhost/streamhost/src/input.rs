// Input injection: browser input records -> QEMU dbus Mouse/Keyboard/MultiTouch.
//
// Wire format (little-endian), one record. Records arrive over the reliable bidi
// stream (buttons/keys/wheel/touch) or over datagrams (move/RTT ping):
//   type=1 mouse-move-abs : u8=1, u16 x, u16 y, u32 cseq   -> Mouse.SetAbsPosition
//   type=2 mouse-button   : u8=2, u8 button(0=L,1=M,2=R), u8 down(1)/up(0),
//                            u16 x, u16 y, u32 cseq        -> Mouse.Press/Release
//   type=3 key            : u8=3, u8 down(1)/up(0), u16 qemu_keycode (XT set1)
//                                                          -> Keyboard.Press/Release
//   type=4 mouse-move-rel : u8=4, i16 dx, i16 dy          -> Mouse.RelMotion
//   type=5 wheel          : u8=5, i16 dx, i16 dy          -> Mouse.Press/Release
//                            (wheel-up=btn3 / wheel-down=btn4; horizontal ignored)
//   type=6 touch          : u8=6, u8 kind(0 begin,1 update,2 end,3 cancel),
//                            u8 slot, u16 x, u16 y        -> MultiTouch.SendEvent
//
// THE CLIENT OWNS POINTER STATE; `cseq` is how it says so. Moves ride unreliable
// datagrams and buttons ride a reliable stream — two transports the network may
// reorder against each other, and only one of which can drop. So a press used to
// race its own position: when the button won, the guest was pressed at the
// PREVIOUS point and the cursor then slid to the real one with the button held,
// which every guest reads as a drag (measured on IRIX, 2026-08-05).
//
// Two properties settle it without adding a server-side delay:
//   * a button record CARRIES the point it happens at, so a press and its
//     position are one atomic reliable record that cannot be separated;
//   * `cseq` is a monotonic client stamp, so an ABSOLUTE move older than what has
//     already been applied is DROPPED rather than rewinding the cursor under a
//     held button. Relative moves carry no stamp and are never dropped: deltas
//     accumulate, so a late one is still owed to the guest.
// A button is never dropped as stale — a lost click is far worse than a
// backwards cursor — it simply does not move the cursor when it arrives late.
//
// QEMU InputButton order: left=0 middle=1 right=2 wheel-up=3 wheel-down=4.
// Absolute pointer (type 1) needs the guest to bind usb-tablet (Windows/ReactOS/
// evdev-Linux). Guests whose X only reads relative /dev/input/mice use type 4.
// Touch (type 6) needs `-device virtio-multitouch-pci` (or usb) for phone stations.

use std::sync::Arc;

use tokio::sync::Mutex;

use crate::capture::{Capture, CONSOLE, I_KBD, I_MOUSE};
use crate::config::{Config, InputBackend};
use crate::key_quirks::{key_gate, key_qnum, remap_key};

pub const I_MTOUCH: &str = "org.qemu.Display1.MultiTouch";

/// Per-SESSION pointer state for the abs->rel bridge (FIX 2). The client always
/// sends absolute coords (type 1); on PS/2 guests with no usb-tablet that is a
/// no-op, so we convert each abs sample into a relative delta from the last one.
/// Shared (Arc<Mutex>) between the datagram task and the reliable-stream task so
/// position-carrying clicks and datagram moves feed one continuous last-position.
#[derive(Default)]
pub struct MouseState {
    lx: i32,
    ly: i32,
    seeded: bool,
    /// When the last warpd MOTION was sent (hybrid-buttons race guard; see type2).
    last_move: Option<std::time::Instant>,
    /// Highest client stamp (`cseq`) whose POSITION has been applied. An absolute
    /// move older than this is stale — the client has already told us where the
    /// pointer went after it — so it is dropped instead of rewinding the cursor.
    applied_cseq: u32,
    /// Last absolute position actually applied, so a button's CARRIED point is
    /// only injected when it says something new. In the common case the move
    /// datagram already won the race and the click costs nothing extra — which
    /// matters on the paced warpd stations, where a redundant motion command would
    /// delay the very click it was meant to place.
    last_abs: Option<(u32, u32)>,
}

/// Is client stamp `a` newer than `b`? Signed wrap-around compare, so the u32
/// rolling over is a seam rather than a cliff.
fn newer(a: u32, b: u32) -> bool {
    (a.wrapping_sub(b) as i32) > 0
}

pub type SharedMouse = Arc<Mutex<MouseState>>;

pub fn new_mouse() -> SharedMouse {
    Arc::new(Mutex::new(MouseState::default()))
}

/// Env-gated (SH_DEBUG_INPUT=1) diagnostic: log absolute samples so a per-guest
/// tablet-origin offset (FIX 3) can be measured against the real client. Off by
/// default; used only during calibration.
fn debug_input() -> bool {
    static D: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *D.get_or_init(|| {
        matches!(
            std::env::var("SH_DEBUG_INPUT").as_deref(),
            Ok("1") | Ok("on")
        )
    })
}

/// SH_REL_MAX_STEP (1..=MAX_REL_STEP) / SH_REL_STEP_PACE_MS (<=200): the
/// per-station override for the rel chunk cap and inter-chunk pace. Defaults
/// keep every existing rel station byte-identical; a guest that takes only the
/// first PS/2 packet of a chained move (Rhapsody DR2) lowers the cap. See
/// docs/guests/rhapsody.md.
fn rel_max_step() -> i32 {
    static V: std::sync::OnceLock<i32> = std::sync::OnceLock::new();
    *V.get_or_init(|| env_num("SH_REL_MAX_STEP", MAX_REL_STEP).clamp(1, MAX_REL_STEP))
}
/// SH_REL_QUANTUM (0 = off, every station today): the rel bridge sends motion
/// ONLY in multiples of this many guest units and keeps the sub-quantum
/// remainder pending in its model. For a guest whose per-event response is a
/// deterministic truncation (A/UX at "Very Slow": px = trunc(0.75 * units) up
/// to 32 units, accelerated above) a quantum of 4 (= 3 px exactly) with
/// SH_REL_MAX_STEP=32 makes every send land on the model: 1:1, no drift.
/// See docs/guests/aux.md.
fn rel_quantum() -> i32 {
    static V: std::sync::OnceLock<i32> = std::sync::OnceLock::new();
    *V.get_or_init(|| env_num("SH_REL_QUANTUM", 0).clamp(0, MAX_REL_STEP))
}
fn rel_step_pace_ms() -> u64 {
    static V: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
    *V.get_or_init(|| env_num("SH_REL_STEP_PACE_MS", REL_STEP_PACE_MS).min(200))
}
fn env_num<T: std::str::FromStr>(k: &str, default: T) -> T {
    std::env::var(k)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

/// Apply per-guest calibration to an absolute client coordinate. The same
/// transform feeds a real absolute tablet or the absolute-client -> relative
/// PS/2 bridge; identity settings preserve the previous relative behavior.
fn calibrated_abs(x: u32, y: u32, off_x: i32, off_y: i32, scale: f64) -> (i32, i32) {
    let xf = (x as f64 * scale).round() as i32 + off_x;
    let yf = (y as f64 * scale).round() as i32 + off_y;
    (xf.max(0), yf.max(0))
}

/// Absolute inject with per-guest tablet-origin calibration (FIX 3). Most stations
/// use identity (scale=1.0, off=0).
pub async fn set_abs(cap: &Capture, x: u32, y: u32, off_x: i32, off_y: i32, scale: f64) {
    let Some(conn) = cap.main_conn.as_ref() else {
        return;
    };
    let (xf, yf) = calibrated_abs(x, y, off_x, off_y, scale);
    let xu = xf.max(0) as u32;
    let yu = yf.max(0) as u32;
    let _ = conn
        .call_method(
            None::<&str>,
            CONSOLE,
            Some(I_MOUSE),
            "SetAbsPosition",
            &(xu, yu),
        )
        .await;
}

pub async fn rel_motion(cap: &Capture, dx: i32, dy: i32) {
    let Some(conn) = cap.main_conn.as_ref() else {
        return;
    };
    let _ = conn
        .call_method(None::<&str>, CONSOLE, Some(I_MOUSE), "RelMotion", &(dx, dy))
        .await;
}

/// Default max per-send relative delta per axis, and inter-chunk pace (ms).
/// QEMU's PS/2 emulation accumulates rel deltas and clamps a single large
/// `RelMotion` (measured on QNX: a lone -8192 is a no-op), so a big move is
/// chunked and paced. SH_REL_MAX_STEP / SH_REL_STEP_PACE_MS override per-station.
const MAX_REL_STEP: i32 = 256;
const REL_STEP_PACE_MS: u64 = 16;

/// How far the homing corner-pin throws the guest cursor, per axis.
///
/// It only has to EXCEED the largest guest surface we drive (1280x1024), because
/// the guest clamps at its own screen edge and the overshoot is free. It used to
/// be 8192, which is free only if you ignore the wire: the PS/2 mouse carries at
/// most ~127 counts per packet and drains at its 100 Hz sample rate, so an 8192
/// pin is ~65 packets and takes the better part of a second to arrive. Anything
/// sent during that drain is queued BEHIND it and merges into one enormous
/// negative motion — which is how the pin came to swallow the first target whole
/// on the Xerox Star station: the Star cursor parked in the corner while the
/// daemon's model believed it was at the target, a fixed offset for the rest of
/// the session, i.e. exactly what the pin exists to prevent.
const HOME_PIN: i32 = 2048;

/// The corner-pin actually sent, for a station whose guest SCALES the deltas it
/// receives.
///
/// `HOME_PIN` above states its own invariant — exceed the largest guest surface
/// — but that is stated in PIXELS while the pin is sent in guest DELTA UNITS,
/// which silently assumes the guest turns one unit into one pixel. Mac OS 7.5.3
/// on the ADB mouse does not: at its only non-accelerated tracking setting it
/// applies a measured, dead-linear **0.36 px per unit**, so a 2048 pin travels
/// 737 px and cannot cross the 1152 px `macos753` screen. The cursor would stop
/// short while the model believed it was pinned at 0,0 — the exact fixed offset
/// FIX 4 exists to prevent.
///
/// `cursor_scale` is already that factor's reciprocal (it is what converts a
/// client pixel into the delta needed to move the guest one pixel), so scaling
/// the pin by it restores the invariant for any guest. `max(1.0)` keeps every
/// gain>=1 station **byte-identical**: the fleet's other relative station,
/// `nt351`, has `cursor_scale` 1.0 and still sends exactly 2048.
///
/// The Xerox Star reasoning that shrank this pin from 8192 is PS/2-specific and
/// does NOT generalise to ADB: measured on `macos753`, a 3200-unit pin followed
/// by a walk is observed as two separate movements at every settle from 250 ms
/// to 3 s, so `HOME_SETTLE_MS` still covers it.
fn home_pin(cursor_scale: f64) -> i32 {
    let scaled = f64::from(HOME_PIN) * cursor_scale.max(1.0);
    // Saturate rather than wrap: a nonsense calibration must not become a
    // negative pin that throws the cursor the wrong way.
    if scaled >= f64::from(i32::MAX) {
        i32::MAX
    } else {
        scaled as i32
    }
}

/// Settle time after the homing corner-pin, before the origin -> target walk.
///
/// The pin and the walk must be OBSERVED as two separate movements. That takes
/// long enough for the pin to DRAIN over the PS/2 wire (HOME_PIN above: ~17
/// packets at 100 Hz, ~170 ms) and then be sampled by a guest that reads the
/// host pointer once per emulated video field and warps it back — measured on
/// Darkstar at ~45 fields/sec, ~22 ms a field. Paid ONCE per session, on the
/// very first pointer sample.
const HOME_SETTLE_MS: u64 = 250;

/// Pure chunker for `rel_motion_bounded` (unit-tested). Split (dx,dy) into a
/// sequence of per-send deltas, each with |axis| <= MAX_REL_STEP, distributed
/// proportionally so both axes finish together. The chunk deltas SUM EXACTLY to
/// (dx,dy) — no rounding drift, so tracking stays 1:1. A move that already fits
/// in one step returns a single chunk (empty for a zero move), i.e. the common
/// pointer-lock small-delta case is byte-identical to a bare `rel_motion`.
#[cfg(test)]
fn rel_chunks(dx: i32, dy: i32, max_step: i32) -> Vec<(i32, i32)> {
    rel_chunks_q(dx, dy, max_step, 0)
}

/// Round `v` toward zero to a multiple of `q` (`q <= 1` = identity).
fn quantize(v: i32, q: i32) -> i32 {
    if q <= 1 {
        v
    } else {
        v - v % q
    }
}

/// `rel_chunks` with a QUANTUM: with `quantum > 1` every chunk delta is a
/// multiple of `quantum` on both axes (the caller passes an already-quantized
/// (dx,dy); the last chunk absorbs the rounding of the intermediate targets, so
/// the sum stays exact and no chunk exceeds `max_step` by more than one quantum).
/// `quantum <= 1` is the plain chunker, byte for byte.
fn rel_chunks_q(dx: i32, dy: i32, max_step: i32, quantum: i32) -> Vec<(i32, i32)> {
    let max_step = max_step.max(1);
    if dx.abs() <= max_step && dy.abs() <= max_step {
        return if dx == 0 && dy == 0 {
            Vec::new()
        } else {
            vec![(dx, dy)]
        };
    }
    let steps = (dx.abs().max(dy.abs()) + max_step - 1) / max_step;
    let steps = steps.max(1);
    let mut out = Vec::with_capacity(steps as usize);
    let (mut sent_x, mut sent_y) = (0i32, 0i32);
    for i in 1..=steps {
        // Cumulative target at chunk i (rounded to the quantum, the final
        // step being the exact total), then the incremental delta. Integer
        // division here can never make a chunk exceed max_step by more than
        // one quantum.
        let (tx, ty) = if i == steps {
            (dx, dy)
        } else {
            (
                quantize(dx * i / steps, quantum),
                quantize(dy * i / steps, quantum),
            )
        };
        let (cx, cy) = (tx - sent_x, ty - sent_y);
        sent_x = tx;
        sent_y = ty;
        if cx != 0 || cy != 0 {
            out.push((cx, cy));
        }
    }
    out
}

/// Send a relative pointer delta SAFELY: chunk it (<=256 px/axis) and pace the
/// chunks so QEMU's PS/2 per-send clamp can never truncate a large/fast move (the
/// QNX / rel-station fix). A small delta is one un-paced send == `rel_motion`, so the
/// pointer-lock direct-rel (type=4) small-delta path stays exactly 1:1.
pub async fn rel_motion_bounded(cap: &Capture, dx: i32, dy: i32) {
    let chunks = rel_chunks_q(dx, dy, rel_max_step(), rel_quantum());
    let n = chunks.len();
    for (i, (cx, cy)) in chunks.into_iter().enumerate() {
        rel_motion(cap, cx, cy).await;
        if i + 1 < n {
            tokio::time::sleep(std::time::Duration::from_millis(rel_step_pace_ms())).await;
        }
    }
}

pub async fn button(cap: &Capture, btn: u32, down: bool) {
    let Some(conn) = cap.main_conn.as_ref() else {
        return;
    };
    let m = if down { "Press" } else { "Release" };
    let _ = conn
        .call_method(None::<&str>, CONSOLE, Some(I_MOUSE), m, &(btn,))
        .await;
}

async fn send_key(conn: &zbus::Connection, code: u32, qnum: u32, down: bool) {
    let m = if down { "Press" } else { "Release" };
    if let Err(e) = conn
        .call_method(None::<&str>, CONSOLE, Some(I_KBD), m, &(qnum,))
        .await
    {
        eprintln!("[input] key {m} code=0x{code:x} qnum=0x{qnum:x} ERR: {e}");
    }
    crate::input_telemetry::key_sent(code, down);
}

pub async fn key(cap: &Capture, code: u32, down: bool, cfg: &Config) {
    let Some(conn) = cap.main_conn.as_ref() else {
        return;
    };
    let qnum = key_qnum(code, cfg.legacy_kbd);
    if cfg.key_min_hold_ms == 0 && cfg.key_min_gap_ms == 0 {
        send_key(conn, code, qnum, down).await;
        return;
    }
    // Both knobs share ONE gate, so a whole pasted line is paced in arrival
    // order: press -> (hold) -> release -> (gap) -> next press. Events queue
    // behind the mutex when the client types faster than the pacing allows;
    // nothing is reordered and nothing is dropped.
    let min_hold = std::time::Duration::from_millis(cfg.key_min_hold_ms);
    let min_gap = std::time::Duration::from_millis(cfg.key_min_gap_ms);
    let mut gate = key_gate().lock().await;
    if down {
        let wait = gate.press_delay(std::time::Instant::now(), min_gap);
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
        send_key(conn, code, qnum, true).await;
        gate.on_press(qnum, std::time::Instant::now());
    } else {
        let wait = gate.release_delay(qnum, std::time::Instant::now(), min_hold);
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
        send_key(conn, code, qnum, false).await;
        gate.on_release(std::time::Instant::now());
    }
}

/// One wheel notch: press then release the wheel-up (3) or wheel-down (4) button.
pub async fn wheel(cap: &Capture, dy: i32) {
    if dy == 0 {
        return;
    }
    let btn: u32 = if dy < 0 { 3 } else { 4 };
    button(cap, btn, true).await;
    button(cap, btn, false).await;
}

/// MultiTouch.SendEvent(kind u, num_slot t, x d, y d). x/y are guest pixel coords.
pub async fn touch(cap: &Capture, kind: u32, slot: u64, x: f64, y: f64) {
    let Some(conn) = cap.main_conn.as_ref() else {
        return;
    };
    let _ = conn
        .call_method(
            None::<&str>,
            CONSOLE,
            Some(I_MTOUCH),
            "SendEvent",
            &(kind, slot, x, y),
        )
        .await;
}

/// Handle one binary input record from the browser.
///
/// `cfg` carries the station's pointer mode + cursor calibration; `mouse` is the
/// per-session abs->rel state shared across the datagram and reliable tasks.
/// Apply an ABSOLUTE pointer position, however it arrived: as a move record of
/// its own, or carried on a button edge. One body so a click's position and a
/// move's position can never diverge in calibration, seeding or backend routing.
async fn apply_move_abs(
    cap: &Capture,
    cfg: &Config,
    mouse: &SharedMouse,
    router: Option<&std::sync::Arc<crate::realtime_input::InputRouter>>,
    x: u32,
    y: u32,
) {
    if let Some(router) = router {
        let (width, height) = {
            let state = cap.state.lock().unwrap();
            (
                state.width.max(state.fb_w).max(1),
                state.height.max(state.fb_h).max(1),
            )
        };
        if router.backend() == "warpd" && cfg.warpd_buttons_qemu {
            let mut st = mouse.lock().await;
            st.lx = x as i32;
            st.ly = y as i32;
            st.last_move = Some(std::time::Instant::now());
        }
        let _ = router.try_move(x, y, width, height);
        return;
    }
    // Routed backends returned above. InputRouter::from_config is the
    // single construction seam for both sinks.
    debug_assert!(cfg.input_backend.is_dbus());
    if cfg.input_backend == InputBackend::DbusAbs {
        // Abs (usb-tablet) guests: inject absolute (with FIX 3 calibration).
        if debug_input() {
            eprintln!(
                "[input] ABS recv=({x},{y}) off=({},{}) scale={} -> inject=({},{})",
                cfg.cursor_off_x,
                cfg.cursor_off_y,
                cfg.cursor_scale,
                (x as f64 * cfg.cursor_scale).round() as i32 + cfg.cursor_off_x,
                (y as f64 * cfg.cursor_scale).round() as i32 + cfg.cursor_off_y,
            );
        }
        set_abs(
            cap,
            x,
            y,
            cfg.cursor_off_x,
            cfg.cursor_off_y,
            cfg.cursor_scale,
        )
        .await
    } else {
        // FIX 2: Rel (PS/2, no usb-tablet) guests: convert abs -> relative delta.
        // FIX 4: HOME on seed. The guest cursor after a (checkpoint) reset sits at
        // an UNKNOWN position, but naively seeding lx/ly to the first client
        // target assumes the guest cursor already matches it — leaving a fixed
        // offset that confines the cursor to a sub-rectangle (audited: win95/
        // win98se/os2warp/win311/ninefront/kolibrios could reach one corner but
        // not the opposite). So on the FIRST sample we PIN the guest cursor to
        // the (0,0) origin with an over-large negative delta (the guest clamps
        // at the screen edge, and pointer acceleration only makes it clamp
        // harder), then track from a KNOWN 0,0. Subsequent absolute targets then
        // map to an accurate delta and every corner becomes reachable.
        let (tx, ty) = calibrated_abs(x, y, cfg.cursor_off_x, cfg.cursor_off_y, cfg.cursor_scale);
        if debug_input() {
            eprintln!(
                "[input] ABS->REL recv=({x},{y}) off=({},{}) scale={} -> target=({tx},{ty})",
                cfg.cursor_off_x, cfg.cursor_off_y, cfg.cursor_scale,
            );
        }
        let (dx, dy) = {
            let mut st = mouse.lock().await;
            if !st.seeded {
                // Deliberate over-clamp into the top-left corner: a merge/clamp
                // is the goal here, not a truncation hazard, and it establishes
                // a known 0,0 origin.
                let pin = home_pin(cfg.cursor_scale);
                rel_motion(cap, -pin, -pin).await;
                tokio::time::sleep(std::time::Duration::from_millis(HOME_SETTLE_MS)).await;
                // The seeding sample sends NO motion of its own. It sets the
                // model to the origin it just pinned and stops; the NEXT sample
                // (tens of hertz away — one frame, invisible) walks origin ->
                // target as an ordinary delta.
                //
                // Sending the walk from inside this same handler is what broke
                // the Xerox Star station: pointer MOVES ride unreliable datagrams
                // and are handled concurrently, so the pin, the seed walk and
                // the next few deltas raced through the PS/2 queue and the guest
                // observed only their merged, hugely negative sum. The cursor
                // parked in the corner while the model believed it was at the
                // target — a fixed offset for the rest of the session, i.e.
                // exactly what the pin exists to prevent. Separating the two
                // costs one sample and removes the race entirely.
                st.lx = 0;
                st.ly = 0;
                st.seeded = true;
                (0, 0)
            } else if rel_quantum() > 1 {
                // QUANTIZED bridge (SH_REL_QUANTUM): send only whole quanta and
                // leave the remainder PENDING in the model — lx/ly advance by
                // what was actually sent, not to the target — so a guest that
                // truncates per event (A/UX: trunc(0.75 * units) px) never
                // loses a fraction the model believed it moved. The residual
                // is < one quantum (< 3 px on A/UX) and is made up as soon as
                // the pointer moves on.
                let q = rel_quantum();
                let dx = quantize(tx - st.lx, q);
                let dy = quantize(ty - st.ly, q);
                st.lx += dx;
                st.ly += dy;
                (dx, dy)
            } else {
                let dx = tx - st.lx;
                let dy = ty - st.ly;
                st.lx = tx;
                st.ly = ty;
                (dx, dy)
            }
        };
        // Route the homing delta through the bounded/paced sender so a
        // large seed jump (origin -> target) or a fast drag never hits
        // the PS/2 per-send clamp and truncates (the rel-station fix). A
        // (0,0) delta yields no send, so this is a no-op when idle.
        rel_motion_bounded(cap, dx, dy).await;
    }
}

pub async fn handle(
    cap: &Capture,
    cfg: &Config,
    mouse: &SharedMouse,
    router: Option<&std::sync::Arc<crate::realtime_input::InputRouter>>,
    rec: &[u8],
) {
    if rec.is_empty() {
        return;
    }
    if cfg.input_backend == InputBackend::Disabled && rec[0] != 3 {
        return;
    }
    match rec[0] {
        1 if rec.len() >= 5 => {
            let x = u16::from_le_bytes([rec[1], rec[2]]) as u32;
            let y = u16::from_le_bytes([rec[3], rec[4]]) as u32;
            // ORDERING GATE. A stamped move that the client emitted before
            // something already applied is obsolete: dropping it is the whole
            // point, because applying it would drag the cursor backwards — under
            // a held button, if it lost the race to its own press.
            {
                let mut st = mouse.lock().await;
                if rec.len() >= 9 {
                    let cseq = u32::from_le_bytes([rec[5], rec[6], rec[7], rec[8]]);
                    if !newer(cseq, st.applied_cseq) {
                        return;
                    }
                    st.applied_cseq = cseq;
                }
                st.last_abs = Some((x, y));
            }
            apply_move_abs(cap, cfg, mouse, router, x, y).await;
        }
        2 if rec.len() >= 3 => {
            let btn = rec[1] as u32;
            let down = rec[2] != 0;
            crate::input_telemetry::set_button(btn as u8, down);
            // THE CARRIED POSITION. The client states where this edge happens, in
            // the same atomic record as the edge, so the press can no longer be
            // separated from its coordinates by the network. Applied FIRST and in
            // this task, so the position and the edge reach the sink together.
            //
            // Only when this edge is the newest thing the client has sent: a
            // button that lost a race to a LATER move must still click (dropping
            // a click is worse than anything it fixes), but it must not rewind
            // the cursor to where the pointer used to be.
            //
            // Skipped for warpd hybrid stations: their motion rides the agent
            // channel, the button plane is pure PS/2 and never carries a point,
            // and feeding one here would re-arm the very button-guard below.
            let carried = if rec.len() >= 11 {
                let cseq = u32::from_le_bytes([rec[7], rec[8], rec[9], rec[10]]);
                let at = (
                    u16::from_le_bytes([rec[3], rec[4]]) as u32,
                    u16::from_le_bytes([rec[5], rec[6]]) as u32,
                );
                let mut st = mouse.lock().await;
                // Newer than anything applied, AND actually somewhere else: when
                // the move datagram already won its race this is the position we
                // are on, and re-sending it is pure cost.
                if newer(cseq, st.applied_cseq) && st.last_abs != Some(at) {
                    st.applied_cseq = cseq;
                    st.last_abs = Some(at);
                    Some(at)
                } else {
                    if newer(cseq, st.applied_cseq) {
                        st.applied_cseq = cseq;
                    }
                    None
                }
            } else {
                None
            };
            let hybrid_warpd = cfg.input_backend == InputBackend::Warpd && cfg.warpd_buttons_qemu;
            let at = match (carried, hybrid_warpd) {
                (Some((x, y)), false) => {
                    let (width, height) = {
                        let state = cap.state.lock().unwrap();
                        (
                            state.width.max(state.fb_w).max(1),
                            state.height.max(state.fb_h).max(1),
                        )
                    };
                    Some((x, y, width, height))
                }
                _ => None,
            };
            if let Some(router) = router.filter(|r| {
                r.backend() == "gallery-hid"
                    || r.backend() == "x11test"
                    || r.backend() == "mamecmd"
                    || r.backend() == "mamesock"
                    || (r.backend() == "warpd" && !cfg.warpd_buttons_qemu)
            }) {
                // Position and edge in ONE router acquisition and ONE ordered
                // event. A rejected edge is LOUD: it is a click the visitor did
                // not get, and it stayed invisible for as long as it did only
                // because this call discarded its result.
                if let Err(e) = router.try_button_at(btn as u8, down, at) {
                    eprintln!(
                        "[input] button edge REJECTED btn={btn} down={down} backend={} err={e:?}",
                        router.backend()
                    );
                }
            } else {
                if let Some((x, y, _, _)) = at {
                    apply_move_abs(cap, cfg, mouse, router, x, y).await;
                }
                // Hybrid warpd stations (SH_WARPD_BUTTONS=qemu): MOTION rides the (possibly
                // slow serial) agent channel while BUTTONS ride the instant PS/2 path —
                // two channels with no ordering. During a drag the press/release would
                // land BEFORE the queued motion reaches the guest, collapsing the drag
                // into a click at the stale position. Guard: if a warpd move was sent
                // within the last SH_WARPD_BUTTON_DELAY_MS, hold the button until that
                // window elapses so the agent has applied the cursor position first.
                if cfg.input_backend == InputBackend::Warpd && cfg.warpd_button_delay_ms > 0 {
                    let since_ms = {
                        let st = mouse.lock().await;
                        st.last_move.map(|t| t.elapsed().as_millis() as u64)
                    };
                    if let Some(s) = since_ms {
                        if s < cfg.warpd_button_delay_ms {
                            tokio::time::sleep(std::time::Duration::from_millis(
                                cfg.warpd_button_delay_ms - s,
                            ))
                            .await;
                        }
                    }
                }
                button(cap, btn, down).await;
            }
        }
        3 if rec.len() >= 4 => {
            let down = rec[1] != 0;
            // The per-station remap rewrites the WIRE code first, so every backend
            // below (and key_qnum's legacy-kbd quirk) sees the key the emulated
            // hardware actually has.
            let code = remap_key(u16::from_le_bytes([rec[2], rec[3]]) as u32, &cfg.key_remap);
            // Keyboard-lag evidence chain, first daemon-side link: when this
            // edge ARRIVED, on the wall clock CTLTRACE and the sink tx/ack
            // lines share (SH_INPUT_TELEMETRY >= 1, else free). The backend
            // named is where the edge is ROUTED below: the matrix sinks by
            // name, everything else lands on the QEMU/dbus keyboard path.
            crate::input_telemetry::key_recv(
                router
                    .map(|r| r.backend())
                    .filter(|b| matches!(*b, "mamecmd" | "mamesock" | "vicesock"))
                    .unwrap_or("dbus"),
                code,
                down,
            );
            // mamecmd/mamesock (the IRIX station) have no D-Bus connection at all —
            // Capture.main_conn is None for every non-QEMU backend, which is
            // exactly why browser keys had never reached that guest. Route it to
            // the key matrix instead (the Lua agent's command file, or the same
            // KEY verbs over the ctlsock control socket); every other backend
            // keeps the classic path byte for byte.
            //
            // gallery-hid is NOT routed here even though its sink implements
            // try_key: it is scoped to Solaris/QNX pointer drivers and has no
            // keyboard minor, so keys stay on QEMU's normal keyboard path. The
            // stock guest keyboard driver consumes this D-Bus injection.
            if let Some(router) = router.filter(|r| {
                r.backend() == "mamecmd" || r.backend() == "mamesock" || r.backend() == "vicesock"
            }) {
                let _ = router.try_key(code as u16, down, false);
                return;
            }
            key(cap, code, down, cfg).await;
        }
        // type=4 DIRECT relative (pointer-lock movementX/Y): NO homing/corner-pin.
        // The UI pointer-lock sends small per-event deltas that reach the guest
        // 1:1; routing through the bounded sender keeps that exact 1:1 for small
        // deltas (single un-paced send) while still chunking an occasional large
        // batched delta so it can't truncate.
        4 if rec.len() >= 5 => {
            let dx = i16::from_le_bytes([rec[1], rec[2]]) as i32;
            let dy = i16::from_le_bytes([rec[3], rec[4]]) as i32;
            rel_motion_bounded(cap, dx, dy).await;
        }
        5 if rec.len() >= 5 => {
            let dx = i16::from_le_bytes([rec[1], rec[2]]) as i32;
            let dy = i16::from_le_bytes([rec[3], rec[4]]) as i32;
            if let Some(router) = router.filter(|r| {
                r.backend() == "gallery-hid"
                    || r.backend() == "x11test"
                    || r.backend() == "mamecmd"
                    || r.backend() == "mamesock"
                    || (r.backend() == "warpd" && cfg.warpd_wheel_agent)
            }) {
                let _ = router.try_wheel(dx, dy);
            } else {
                wheel(cap, dy).await;
            }
        }
        6 if rec.len() >= 7 => {
            let kind = rec[1] as u32;
            let slot = rec[2] as u64;
            let x = u16::from_le_bytes([rec[3], rec[4]]) as f64;
            let y = u16::from_le_bytes([rec[5], rec[6]]) as f64;
            touch(cap, kind, slot, x, y).await;
        }
        _ => {}
    }
}

#[cfg(test)]
#[path = "input_tests.rs"]
mod tests;
