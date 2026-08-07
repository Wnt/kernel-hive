// X11 root-window capture (Xvfb) for LXC emulator-bridge tiles.
//
// The QEMU dbus-display path (see `super::connect`) is unavailable for tiles
// whose emulator must run on the bare-metal CPU rather than a KVM vCPU (the SGI
// IRIX/MAME tile: MAME's Indy emulation deterministically kernel-panics inside a
// KVM guest but runs fine in an LXC container / on the host). Those tiles render
// into an Xvfb; this module grabs that X server's root window straight into the
// same `FrameState.fb` BGRA copy-path the encoder already consumes, so the whole
// encode/transport/SPA stack is reused unchanged.
//
// Design (proven by the x11rb spike, docs/history/irix-tile-issue20-handoff.md):
//   * pure-Rust x11rb, no C libraries.
//   * XDamage(DELTA_RECTANGLES) on the root drives grabs — a static desktop
//     produces no events (no wasted CPU / bandwidth; the encoder heartbeats),
//     matching the QEMU damage-gated behavior.
//   * each grab is a full-frame GetImage(Z_PIXMAP) (~3.2 ms for 1280x1024 on the
//     lab box = ~300 fps headroom), copied into `fb`; only the damaged
//     rectangles are reported to the encoder via `note_damage`, so a small
//     repaint still converts just its bbox.
//   * depth-24 Z_PIXMAP on little-endian X is BGRX — byte-identical to the
//     encoder's expected BGRA (the pad byte occupies the ignored alpha slot).
//
// Geometry is read once at connect. IRIX/MAME renders a fixed 1280x1024 (xl24);
// a mid-stream XRandR resize is out of scope for the initial tile.

use std::sync::{Arc, Mutex};

use anyhow::Context;
use tokio::sync::Notify;
use x11rb::connection::Connection;
use x11rb::protocol::damage::{ConnectionExt as _, ReportLevel};
use x11rb::protocol::xproto::{ConnectionExt as _, ImageFormat, Rectangle};
use x11rb::protocol::Event;

use super::frame::FrameState;
use super::listener::CapStats;
use super::Capture;

/// Connect to an X server (Xvfb) and stream its root window into a `Capture`.
/// `display` is an X display string (e.g. ":99"). Returns once the first frame
/// has been grabbed so `main.rs` can log real geometry; the background thread
/// then owns the connection for the process lifetime.
pub async fn connect_x11(display: &str) -> anyhow::Result<Capture> {
    let state = Arc::new(Mutex::new(FrameState::new()));
    let damage = Arc::new(Notify::new());

    let (first_tx, first_rx) = tokio::sync::oneshot::channel::<anyhow::Result<(u16, u16)>>();
    let display = display.to_string();
    let st = state.clone();
    let dmg = damage.clone();
    std::thread::Builder::new()
        .name("x11capture".into())
        .spawn(move || {
            if let Err(e) = capture_loop(&display, st, dmg, first_tx) {
                eprintln!("[x11cap] capture loop ended: {e:#}");
            }
        })
        .context("spawn x11capture thread")?;

    let (w, h) = first_rx
        .await
        .map_err(|_| anyhow::anyhow!("x11 capture thread died before first frame"))??;
    eprintln!("[x11cap] first frame {w}x{h}");

    Ok(Capture {
        state,
        damage,
        main_conn: None,
        listener: Arc::new(Mutex::new(None)),
        stats: Arc::new(CapStats::default()),
    })
}

fn capture_loop(
    display: &str,
    state: Arc<Mutex<FrameState>>,
    damage: Arc<Notify>,
    first_tx: tokio::sync::oneshot::Sender<anyhow::Result<(u16, u16)>>,
) -> anyhow::Result<()> {
    let connect_and_arm = || -> anyhow::Result<_> {
        let (conn, screen_num) =
            x11rb::connect(Some(display)).context("x11rb connect to Xvfb display")?;
        let screen = &conn.setup().roots[screen_num];
        let root = screen.root;
        let w = screen.width_in_pixels;
        let h = screen.height_in_pixels;
        conn.damage_query_version(1, 1)
            .context("XDamage query")?
            .reply()
            .context("XDamage version reply")?;
        let dmg_id = conn.generate_id()?;
        conn.damage_create(dmg_id, root, ReportLevel::DELTA_RECTANGLES)
            .context("damage_create")?;
        conn.flush()?;
        Ok((conn, root, w, h, dmg_id))
    };

    let (conn, root, w, h, dmg_id) = match connect_and_arm() {
        Ok(v) => v,
        Err(e) => {
            let _ = first_tx.send(Err(e));
            return Ok(());
        }
    };

    // Initial full grab so the daemon has geometry + an IDR-worthy first frame.
    if let Err(e) = grab(&conn, root, w, h, &state, None) {
        let _ = first_tx.send(Err(e));
        return Ok(());
    }
    damage.notify_waiters();
    let _ = first_tx.send(Ok((w, h)));

    // Damage-gated grab loop. wait_for_event blocks with no CPU cost while the
    // guest desktop is static; a burst of repaints is coalesced into one grab.
    loop {
        let ev = conn.wait_for_event().context("x11 wait_for_event")?;
        let mut rects: Vec<Rectangle> = Vec::new();
        collect_damage(ev, &mut rects);
        while let Some(ev) = conn.poll_for_event().context("x11 poll_for_event")? {
            collect_damage(ev, &mut rects);
        }
        // Re-arm before grabbing so repaints during the grab are not lost.
        conn.damage_subtract(dmg_id, x11rb::NONE, x11rb::NONE)
            .context("damage_subtract")?;
        if rects.is_empty() {
            continue;
        }
        grab(&conn, root, w, h, &state, Some(&rects))?;
        damage.notify_waiters();
    }
}

fn collect_damage(ev: Event, rects: &mut Vec<Rectangle>) {
    if let Event::DamageNotify(d) = ev {
        rects.push(d.area);
    }
}

/// Full-frame GetImage into `FrameState.fb`. `rects = None` marks a full-damage
/// first frame; otherwise only the given (guest-pixel) rectangles are reported to
/// the encoder so a partial repaint converts just its bbox.
fn grab(
    conn: &impl Connection,
    root: x11rb::protocol::xproto::Window,
    w: u16,
    h: u16,
    state: &Arc<Mutex<FrameState>>,
    rects: Option<&[Rectangle]>,
) -> anyhow::Result<()> {
    let img = conn
        .get_image(ImageFormat::Z_PIXMAP, root, 0, 0, w, h, !0)
        .context("get_image")?
        .reply()
        .context("get_image reply")?;
    let data = img.data;
    let expected = w as usize * h as usize * 4;
    if data.len() < expected {
        anyhow::bail!(
            "x11 GetImage short read: got {} want {} ({w}x{h}x4)",
            data.len(),
            expected
        );
    }

    let mut s = state.lock().unwrap();
    if s.fb.len() != data.len() {
        s.fb = vec![0u8; data.len()];
    }
    s.fb.copy_from_slice(&data);
    s.fb_w = w as u32;
    s.fb_h = h as u32;
    s.fb_stride = w as u32 * 4;
    s.gen = s.gen.wrapping_add(1);
    match rects {
        None => s.note_full_damage(),
        Some(rs) => {
            for r in rs {
                s.note_damage(r.x as i32, r.y as i32, r.width as i32, r.height as i32);
            }
        }
    }
    Ok(())
}
