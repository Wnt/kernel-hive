// Shared-memory framebuffer capture — the emulator publishes finished frames
// straight into a file-backed mapping and we read them; no X server, no window.
//
// WHY (measured, see docs/guests/irix.md): the `x11` backend costs the IRIX/MAME
// tile ~1.5-1.7 Gcyc per emulated second (32-43% of host time) and it is all raw
// pixel movement, not shading — MAME rasterises the Newport framebuffer into an
// RGB32 bitmap, uploads it to an SDL texture, blits that through Mesa llvmpipe
// into an X window, and this daemon then reads the same pixels back out. A
// 1280x1024x4 frame is software-rasterised TWICE and pushed through X in between.
// `SDL_RENDER_DRIVER=software` changes nothing (so llvmpipe was never the cost)
// and `-nofilter` is worth ~1.8%. Deleting the whole detour is the only real fix.
//
// So MAME runs `-video none` and its Newport device publishes each finished
// frame into `IRIX_SHM_PATH`; this backend maps that file and hands the pixels to
// the same `FrameState.fb` BGRA copy-path the encoder already consumes. It is
// also a FIDELITY fix: MAME's X window was 1272x954 on a 1280x1024 Xvfb and
// auto-scaled with the display, so the exhibit streamed RESAMPLED pixels; the
// mapping carries the exact emulated framebuffer (1288x1024 once IRIX programs
// the VC2).
//
// WIRE FORMAT (producer: src/devices/bus/gio64/newport.cpp, env-gated on
// IRIX_SHM_PATH so it is inert for every other MAME use):
//
//   off  type  field
//     0  u32   magic 'IFB1' (0x31424649 little-endian)
//     4  u32   version (1)
//     8  u32   width
//    12  u32   height
//    16  u32   stride (bytes per row)
//    20  u32   bpp (32)
//    24  u64   sequence (seqlock)
//    32  u32   dirty_x0      36 u32 dirty_y0
//    40  u32   dirty_x1      44 u32 dirty_y1
//    48        pad to 64
//    64        width*height RGB32 pixels
//
// Pixels are MAME `bitmap_rgb32` = host-endian XRGB8888, i.e. B,G,R,X in memory
// on x86 — byte-identical to the encoder's expected BGRA (the pad byte occupies
// the ignored alpha slot), exactly like the x11 backend's depth-24 Z_PIXMAP. No
// per-pixel conversion happens anywhere on this path; one would eat the entire
// win.
//
// SYNCHRONISATION is a seqlock: one producer, any number of readers, readers
// never write. The sequence goes ODD before pixels are touched and EVEN after
// (release ordering both times). We take it with acquire, copy, re-read, and
// retry when it was odd or changed — so a torn frame can never be accepted. The
// producer's own validation ran 200 accepted samples under maximum write
// pressure and correctly rejected 3,005 torn reads.
//
// DAMAGE. The producer reuses the dirty flag from its whole-frame render cache,
// so the header tells us for free whether the frame changed at all — an
// unchanged frame is skipped without copying a single byte, which is the same
// idle behaviour XDamage gave the x11 backend. What the header does NOT carry is
// sub-frame granularity (it reports either the whole frame or nothing), and
// losing the encoder's damage-bbox conversion to gain the copy saving would be a
// bad trade. So `SH_SHM_DAMAGE=1` (default) recovers it host-side: the copy is
// diffed against the previous frame and a real bbox is derived. The diff is one
// extra pass over pixels we already touched, on dirty frames only, and it runs
// on the streamhost core rather than the emulator core. `SH_SHM_DAMAGE=0` marks
// every dirty frame full-frame (the A/B control).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::Context;
use tokio::sync::Notify;

use super::frame::FrameState;
use super::listener::CapStats;
use super::Capture;

/// Fixed header size in bytes; pixels start here.
const HEADER: usize = 64;
const MAGIC: u32 = 0x3142_4649; // 'IFB1'
/// How long to wait for the producer to create + populate the mapping before
/// giving up. MAME publishes its first frame within a second or two of start,
/// but the tile launcher may race us.
const WAIT_FIRST_FRAME: std::time::Duration = std::time::Duration::from_secs(120);
/// Bound on seqlock retries for one frame before we simply wait for the next.
const MAX_TEARS: u32 = 16;

/// Map a producer-published framebuffer file and stream it into a `Capture`.
/// Returns once the first frame has been read so `main.rs` can log real
/// geometry; the background thread then owns the mapping for the process
/// lifetime.
pub async fn connect_shm(path: &str, poll_ms: u64, diff_damage: bool) -> anyhow::Result<Capture> {
    let state = Arc::new(Mutex::new(FrameState::new()));
    let damage = Arc::new(Notify::new());

    let (first_tx, first_rx) = tokio::sync::oneshot::channel::<anyhow::Result<(u32, u32)>>();
    let path = path.to_string();
    let st = state.clone();
    let dmg = damage.clone();
    let poll = std::time::Duration::from_millis(poll_ms.clamp(1, 100));
    std::thread::Builder::new()
        .name("shmcapture".into())
        .spawn(move || {
            if let Err(e) = capture_loop(&path, st, dmg, first_tx, poll, diff_damage) {
                eprintln!("[shmcap] capture loop ended: {e:#}");
            }
        })
        .context("spawn shmcapture thread")?;

    let (w, h) = first_rx
        .await
        .map_err(|_| anyhow::anyhow!("shm capture thread died before first frame"))??;
    eprintln!("[shmcap] first frame {w}x{h}");

    Ok(Capture {
        state,
        damage,
        main_conn: None,
        listener: Arc::new(Mutex::new(None)),
        stats: Arc::new(CapStats::default()),
    })
}

/// A live read-only mapping of the producer's file, sized from its own header.
struct Mapping {
    ptr: *const u8,
    len: usize,
    w: u32,
    h: u32,
    stride: u32,
}

impl Drop for Mapping {
    fn drop(&mut self) {
        unsafe { libc::munmap(self.ptr as *mut libc::c_void, self.len) };
    }
}

impl Mapping {
    fn hdr(&self, idx: usize) -> u32 {
        unsafe { std::ptr::read_volatile((self.ptr as *const u32).add(idx)) }
    }

    /// The seqlock word. Read with acquire so the pixel loads below cannot be
    /// hoisted above it.
    fn seq(&self) -> u64 {
        let p = unsafe { &*((self.ptr.add(24)) as *const AtomicU64) };
        p.load(Ordering::Acquire)
    }

    fn pixels(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.ptr.add(HEADER), self.len - HEADER) }
    }
}

/// Open + mmap the producer file, validating the header. `None` while the file
/// does not exist yet, is too short, or has not been initialised.
fn try_map(path: &str) -> anyhow::Result<Option<Mapping>> {
    let f = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e).context("open shm framebuffer file"),
    };
    use std::os::fd::AsRawFd;
    let size = f.metadata().context("stat shm framebuffer file")?.len() as usize;
    if size <= HEADER {
        return Ok(None);
    }
    let ptr = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            size,
            libc::PROT_READ,
            libc::MAP_SHARED,
            f.as_raw_fd(),
            0,
        )
    };
    if ptr == libc::MAP_FAILED {
        anyhow::bail!("mmap shm framebuffer: {}", std::io::Error::last_os_error());
    }
    // Build the owning `Mapping` FIRST, so every early return below unmaps
    // through its Drop. Reading the header off the raw pointer and constructing
    // the value afterwards is the version of this that segfaults: `Mapping`'s
    // fields are all `Copy`, so functional-update syntax (`..m`) COPIES them and
    // leaves the original live to be dropped at end of scope — munmapping the
    // region out from under the pointer we just returned.
    let mut m = Mapping {
        ptr: ptr as *const u8,
        len: size,
        w: 0,
        h: 0,
        stride: 0,
    };
    let (magic, ver, w, h, stride, bpp) =
        (m.hdr(0), m.hdr(1), m.hdr(2), m.hdr(3), m.hdr(4), m.hdr(5));
    if magic != MAGIC {
        return Ok(None); // producer has not written the header yet
    }
    if ver != 1 {
        anyhow::bail!("shm framebuffer version {ver} unsupported (expected 1)");
    }
    if bpp != 32 {
        anyhow::bail!("shm framebuffer bpp {bpp} unsupported (expected 32)");
    }
    if w == 0 || h == 0 || stride < w.saturating_mul(4) {
        return Ok(None);
    }
    if size < HEADER + stride as usize * h as usize {
        return Ok(None); // mid-resize; the producer ftruncates before it publishes
    }
    m.w = w;
    m.h = h;
    m.stride = stride;
    Ok(Some(m))
}

fn capture_loop(
    path: &str,
    state: Arc<Mutex<FrameState>>,
    damage: Arc<Notify>,
    first_tx: tokio::sync::oneshot::Sender<anyhow::Result<(u32, u32)>>,
    poll: std::time::Duration,
    diff_damage: bool,
) -> anyhow::Result<()> {
    // Wait for the producer. The tile launcher starts MAME and streamhost
    // together, so the file legitimately does not exist for the first seconds.
    let deadline = std::time::Instant::now() + WAIT_FIRST_FRAME;
    let mut map = loop {
        match try_map(path) {
            Ok(Some(m)) => break m,
            Ok(None) => {}
            Err(e) => {
                let _ = first_tx.send(Err(e));
                return Ok(());
            }
        }
        if std::time::Instant::now() >= deadline {
            let _ = first_tx.send(Err(anyhow::anyhow!(
                "no shm framebuffer at {path} after {}s",
                WAIT_FIRST_FRAME.as_secs()
            )));
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    };

    let mut scratch: Vec<u8> = Vec::new();
    let mut last_seq = u64::MAX;
    let mut first_tx = Some(first_tx);
    let mut tears: u32 = 0;

    loop {
        let seq = map.seq();
        if seq == last_seq || seq & 1 == 1 {
            std::thread::sleep(poll);
            continue;
        }
        // Geometry changes mid-stream: IRIX reprograms the VC2 ~85 frames into
        // boot and the emulated screen goes 1280x1024 -> 1288x1024 (and the
        // stride with it, 5120 -> 5152). The producer re-ftruncates and re-mmaps,
        // growing the file by 32 KiB; a consumer that kept the old, smaller
        // mapping and then trusted the new header would read straight off the end
        // of its map. So re-map on ANY of width/height/stride changing, and never
        // read pixels using a dimension we have not mapped for.
        if map.hdr(2) != map.w || map.hdr(3) != map.h || map.hdr(4) != map.stride {
            match try_map(path) {
                Ok(Some(m)) => {
                    eprintln!(
                        "[shmcap] geometry {}x{} stride {} -> {}x{} stride {}",
                        map.w, map.h, map.stride, m.w, m.h, m.stride
                    );
                    map = m;
                    last_seq = u64::MAX;
                }
                Ok(None) => std::thread::sleep(poll),
                Err(e) => return Err(e),
            }
            continue;
        }

        // An unchanged frame costs nothing: the producer already told us via the
        // dirty rect it carried out of its whole-frame render cache. The FIRST
        // frame is exempt — a daemon started against an already-idle guest (the
        // IRIX login chooser is perfectly static, and a tile relaunch lands
        // exactly there) would otherwise never see a dirty frame, never report
        // geometry, and never come up at all.
        let (dx0, dy0, dx1, dy1) = (map.hdr(8), map.hdr(9), map.hdr(10), map.hdr(11));
        if (dx1 <= dx0 || dy1 <= dy0) && first_tx.is_none() {
            last_seq = seq;
            std::thread::sleep(poll);
            continue;
        }

        let (w, h, stride) = (map.w as usize, map.h as usize, map.stride as usize);
        let row = w * 4;
        // Belt and braces. The mapping is sized from a header written by ANOTHER
        // process; a torn or stale header must never be able to make this thread
        // read out of bounds, which a SIGSEGV in a capture backend under a live
        // exhibit certainly would. The seqlock protects the pixels; this protects
        // the geometry. Re-map (once) rather than read, and if the file still
        // cannot back the geometry, skip the frame instead of faulting.
        let src = map.pixels();
        if pixel_bytes_needed(w, h, stride) > src.len() {
            eprintln!(
                "[shmcap] header {w}x{h} stride {stride} needs {} pixel bytes, mapping has {} — re-mapping",
                pixel_bytes_needed(w, h, stride),
                src.len()
            );
            match try_map(path) {
                Ok(Some(m)) => map = m,
                Ok(None) | Err(_) => std::thread::sleep(poll),
            }
            last_seq = u64::MAX;
            continue;
        }
        if scratch.len() != row * h {
            scratch = vec![0u8; row * h];
        }
        for y in 0..h {
            let s = y * stride;
            scratch[y * row..y * row + row].copy_from_slice(&src[s..s + row]);
        }
        if map.seq() != seq {
            // Torn: the producer overwrote us mid-copy. Retry immediately a
            // bounded number of times, then fall back to waiting for the next
            // frame so a pathologically fast producer cannot spin us forever.
            tears += 1;
            if tears >= MAX_TEARS {
                tears = 0;
                std::thread::sleep(poll);
            }
            continue;
        }
        tears = 0;
        last_seq = seq;

        let notify = {
            let mut s = state.lock().unwrap();
            let same_geom = s.fb.len() == scratch.len() && s.fb_w == map.w && s.fb_h == map.h;
            let rect = if diff_damage && same_geom {
                changed_bbox(&s.fb, &scratch, w, h)
            } else {
                None
            };
            let notify = if diff_damage && same_geom {
                // A bit-identical frame the producer flagged dirty (a repaint
                // that restored the same pixels) is not worth an encode.
                match rect {
                    Some(r) => {
                        std::mem::swap(&mut s.fb, &mut scratch);
                        s.gen = s.gen.wrapping_add(1);
                        s.note_damage(r.0 as i32, r.1 as i32, r.2 as i32, r.3 as i32);
                        true
                    }
                    None => false,
                }
            } else {
                std::mem::swap(&mut s.fb, &mut scratch);
                s.gen = s.gen.wrapping_add(1);
                s.note_full_damage();
                true
            };
            s.fb_w = map.w;
            s.fb_h = map.h;
            s.fb_stride = map.w * 4;
            notify
        };
        if let Some(tx) = first_tx.take() {
            let _ = tx.send(Ok((map.w, map.h)));
        }
        if notify {
            damage.notify_waiters();
        }
    }
}

/// Bytes of pixel data a `w x h` frame at `stride` actually touches: the last
/// row is only `w*4` wide, not a full stride. Saturating throughout so a garbage
/// header produces a huge number (and therefore a refusal) rather than an
/// overflow that wraps into a small, passing one.
fn pixel_bytes_needed(w: usize, h: usize, stride: usize) -> usize {
    if w == 0 || h == 0 {
        return 0;
    }
    h.saturating_sub(1)
        .saturating_mul(stride)
        .saturating_add(w.saturating_mul(4))
}

/// Bounding box of the pixels that differ between two same-geometry tightly
/// packed BGRA frames, as `(x, y, w, h)`. `None` when they are identical.
///
/// Rows are compared whole (one `memcmp` per row, which is what a slice `!=`
/// compiles to); only rows that differ are scanned for their first/last
/// differing pixel, so the column refinement is free on an unchanged row and
/// cheap on a changed one.
fn changed_bbox(a: &[u8], b: &[u8], w: usize, h: usize) -> Option<(u32, u32, u32, u32)> {
    let row = w * 4;
    let (mut y0, mut y1) = (usize::MAX, 0usize);
    let (mut x0, mut x1) = (usize::MAX, 0usize);
    for y in 0..h {
        let ra = &a[y * row..y * row + row];
        let rb = &b[y * row..y * row + row];
        if ra == rb {
            continue;
        }
        if y0 == usize::MAX {
            y0 = y;
        }
        y1 = y;
        // Refine columns only while the box is not already full width.
        if x0 != 0 || x1 != w - 1 {
            let lo = ra.iter().zip(rb).position(|(p, q)| p != q).unwrap_or(0) / 4;
            let hi = ra
                .iter()
                .zip(rb)
                .rposition(|(p, q)| p != q)
                .unwrap_or(row - 1)
                / 4;
            x0 = x0.min(lo);
            x1 = x1.max(hi);
        }
    }
    if y0 == usize::MAX {
        return None;
    }
    Some((
        x0 as u32,
        y0 as u32,
        (x1 - x0 + 1) as u32,
        (y1 - y0 + 1) as u32,
    ))
}

#[cfg(test)]
mod tests {
    use super::{changed_bbox, pixel_bytes_needed};

    #[test]
    fn pixel_bytes_needed_counts_only_the_last_row_that_exists() {
        // The IRIX reconfigure: 1280x1024 stride 5120 -> 1288x1024 stride 5152.
        assert_eq!(pixel_bytes_needed(1280, 1024, 5120), 1280 * 1024 * 4);
        assert_eq!(pixel_bytes_needed(1288, 1024, 5152), 1288 * 1024 * 4);
        // A padded stride costs nothing on the final row.
        assert_eq!(pixel_bytes_needed(4, 3, 64), 64 * 2 + 16);
        assert_eq!(pixel_bytes_needed(0, 1024, 5152), 0);
        assert_eq!(pixel_bytes_needed(1288, 0, 5152), 0);
        // A garbage header must saturate high (=> refused), never wrap low.
        assert_eq!(
            pixel_bytes_needed(usize::MAX, usize::MAX, usize::MAX),
            usize::MAX
        );
    }

    fn frame(w: usize, h: usize) -> Vec<u8> {
        vec![0u8; w * h * 4]
    }

    #[test]
    fn identical_frames_have_no_damage() {
        let a = frame(16, 8);
        let b = a.clone();
        assert_eq!(changed_bbox(&a, &b, 16, 8), None);
    }

    #[test]
    fn single_pixel_change_is_a_unit_box() {
        let a = frame(16, 8);
        let mut b = a.clone();
        // pixel (5,3), green byte
        b[(3 * 16 + 5) * 4 + 1] = 0xff;
        assert_eq!(changed_bbox(&a, &b, 16, 8), Some((5, 3, 1, 1)));
    }

    #[test]
    fn scattered_changes_union_into_one_box() {
        let a = frame(16, 8);
        let mut b = a.clone();
        b[(16 + 2) * 4] = 1; // (2,1)
        b[(6 * 16 + 11) * 4 + 2] = 1; // (11,6)
        assert_eq!(changed_bbox(&a, &b, 16, 8), Some((2, 1, 10, 6)));
    }

    #[test]
    fn full_frame_change_covers_everything() {
        let a = frame(4, 4);
        let b = vec![9u8; 4 * 4 * 4];
        assert_eq!(changed_bbox(&a, &b, 4, 4), Some((0, 0, 4, 4)));
    }
}
