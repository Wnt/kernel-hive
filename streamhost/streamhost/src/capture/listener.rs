// D-Bus display listener: the p2p server QEMU pushes scanout/damage into.
//
// We serve /org/qemu/Display1/Listener implementing BOTH the zero-copy
// shared-memory scanout interface (org.qemu.Display1.Listener.Unix.Map) and the
// v1 copy-path fallback (org.qemu.Display1.Listener). `register_listener` builds
// a fresh socketpair, serves these interfaces on one end, and hands the other
// to QEMU via Console.RegisterListener — used both on first connect and by the
// RSS guard's recycle (see `super::guard`).
//
// PERF / flow-control (shm attach-burst root cause, 2026-07): the v1 Scanout/
// Update args are `&[u8]` ON PURPOSE — zvariant deserializes borrowed byte
// slices via the bytes fast path (one bounds check + slice borrow), whereas
// `Vec<u8>` goes through serde's per-element sequence visitor. On the bridge
// stations the copy path carries ~3 MB per Update at up to 60 Hz; the per-byte
// loop capped drain at a few msgs/s (100%+ CPU), the socket backpressured, and
// QEMU's unbounded output queue OOM'd the guest cgroup. A v1 Scanout also
// invalidates (munmaps) any previously offered shm map so the copy path is
// authoritative and a stale placeholder never wins snapshot_bgra().

use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, RawFd};
use std::os::unix::net::UnixStream as StdUnixStream;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Mutex};

use nix::sys::socket::{socketpair, AddressFamily, SockFlag, SockType};
use tokio::sync::Notify;
use zbus::zvariant::Fd;

use super::frame::FrameState;
use super::{CONSOLE, I_CONSOLE};

/// Listener dispatch counters (SH_CAP_TRACE=1 prints per-2s deltas).
#[derive(Default)]
pub struct CapStats {
    pub map_scanout: AtomicU64,
    pub map_update: AtomicU64,
    pub v1_scanout: AtomicU64,
    pub v1_update: AtomicU64,
    pub v1_bytes: AtomicU64,
    pub handler_us: AtomicU64,
    pub guard_trips: AtomicU64,
}

#[derive(Clone)]
struct ListenerMap {
    st: Arc<Mutex<FrameState>>,
    damage: Arc<Notify>,
    stats: Arc<CapStats>,
}
#[derive(Clone)]
struct ListenerV1 {
    st: Arc<Mutex<FrameState>>,
    damage: Arc<Notify>,
    stats: Arc<CapStats>,
}

// zero-copy shared-memory scanout. Interface name MUST be exactly
// org.qemu.Display1.Listener.Unix.Map (SPIKE A finding).
#[zbus::interface(name = "org.qemu.Display1.Listener.Unix.Map")]
impl ListenerMap {
    async fn scanout_map(
        &self,
        handle: zbus::zvariant::OwnedFd,
        offset: u32,
        width: u32,
        height: u32,
        stride: u32,
        pixman_format: u32,
    ) {
        self.stats.map_scanout.fetch_add(1, Relaxed);
        let fd = handle.as_raw_fd();
        let len = offset as usize + stride as usize * height as usize;
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ,
                libc::MAP_SHARED,
                fd,
                0,
            )
        };
        let mut s = self.st.lock().unwrap();
        if ptr == libc::MAP_FAILED {
            eprintln!(
                "[capture] ScanoutMap mmap FAILED errno={}",
                std::io::Error::last_os_error()
            );
            return;
        }
        if !s.map_ptr.is_null() {
            unsafe { libc::munmap(s.map_ptr as *mut libc::c_void, s.map_len) };
        }
        let resized = s.width != width || s.height != height || s.stride != stride;
        s.map_ptr = ptr as *mut u8;
        s.map_len = len;
        s.offset = offset as usize;
        s.width = width;
        s.height = height;
        s.stride = stride;
        s.format = pixman_format;
        // A ScanoutMap re-invocation means a mode/resolution switch. Bump the
        // damage generation and pulse so the encoder wakes immediately and its
        // geometry-change guard restarts x264 at the new size (rather than waiting
        // for the next UpdateMap, which may not come until the guest repaints).
        s.gen = s.gen.wrapping_add(1);
        s.note_full_damage();
        s.frames += 1;
        // Once QEMU offers the shm map, any stale v1 copy-path framebuffer is dead
        // weight and could win snapshot_bgra() at the wrong size — drop it.
        if !s.fb.is_empty() {
            s.fb = Vec::new();
            s.fb_w = 0;
            s.fb_h = 0;
        }
        drop(s);
        self.damage.notify_waiters();
        eprintln!(
            "[capture] ScanoutMap {}x{} stride={} off={} fmt=0x{:08x} len={} resized={}",
            width, height, stride, offset, pixman_format, len, resized
        );
    }

    async fn update_map(&self, x: i32, y: i32, w: i32, h: i32) {
        self.stats.map_update.fetch_add(1, Relaxed);
        {
            let mut s = self.st.lock().unwrap();
            s.frames += 1;
            s.gen = s.gen.wrapping_add(1);
            s.note_damage(x, y, w, h);
        }
        self.damage.notify_waiters();
    }
}

// base Listener: the `Interfaces` property advertises Unix.Map (flips QEMU's
// can_share_map=true). Also carries the copy-path fallback methods.
//
// PERF: `data` args are `&[u8]` ON PURPOSE — zvariant deserializes borrowed
// byte slices via the bytes fast path (one bounds check + slice borrow),
// whereas `Vec<u8>` goes through serde's per-element sequence visitor. On the
// kiosks the copy path carries ~3 MB per Update at up to 60 Hz; the
// per-byte loop capped drain at a few msgs/s (100%+ CPU), the socket
// backpressured, and QEMU's unbounded output queue OOM'd the guest cgroup.
#[zbus::interface(name = "org.qemu.Display1.Listener")]
impl ListenerV1 {
    #[zbus(property)]
    async fn interfaces(&self) -> Vec<String> {
        vec!["org.qemu.Display1.Listener.Unix.Map".to_string()]
    }

    #[zbus(name = "Scanout")]
    async fn scanout(&self, width: u32, height: u32, stride: u32, pixman_format: u32, data: &[u8]) {
        let t0 = std::time::Instant::now();
        self.stats.v1_scanout.fetch_add(1, Relaxed);
        self.stats.v1_bytes.fetch_add(data.len() as u64, Relaxed);
        let mut superseded: Option<(u32, u32)> = None; // logged after the lock is released
        {
            let mut s = self.st.lock().unwrap();
            // A full v1 Scanout means QEMU switched to a non-shareable surface
            // (copy path is now authoritative). Invalidate any earlier shm map —
            // it is a dead surface (typically the pre-guest-init 640x480
            // placeholder from a first attach) and must not win snapshot_bgra().
            if !s.map_ptr.is_null() {
                superseded = Some((s.width, s.height));
                s.drop_map();
            }
            s.fb_w = width;
            s.fb_h = height;
            s.fb_stride = stride;
            s.format = pixman_format;
            s.fb = data.to_vec();
            s.frames += 1;
            s.gen = s.gen.wrapping_add(1);
            s.note_full_damage();
        }
        if let Some((ow, oh)) = superseded {
            eprintln!(
                "[capture] v1 Scanout {}x{} supersedes shm map ({}x{}) — copy path authoritative",
                width, height, ow, oh
            );
        }
        self.damage.notify_waiters();
        self.stats
            .handler_us
            .fetch_add(t0.elapsed().as_micros() as u64, Relaxed);
    }
    #[zbus(name = "Update")]
    #[allow(clippy::too_many_arguments)] // signature fixed by the QEMU dbus-display protocol
    async fn update(
        &self,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        stride: u32,
        _fmt: u32,
        data: &[u8],
    ) {
        let t0 = std::time::Instant::now();
        self.stats.v1_update.fetch_add(1, Relaxed);
        self.stats.v1_bytes.fetch_add(data.len() as u64, Relaxed);
        {
            let mut s = self.st.lock().unwrap();
            let (fbw, fbh, fbs) = (s.fb_w as usize, s.fb_h as usize, s.fb_stride as usize);
            if !s.fb.is_empty() && width > 0 && height > 0 {
                let src_stride = stride as usize;
                let bpp = 4usize;
                let rx = x.max(0) as usize;
                let ry = y.max(0) as usize;
                let rw = (width as usize).min(fbw.saturating_sub(rx));
                let rh = (height as usize).min(fbh.saturating_sub(ry));
                for row in 0..rh {
                    let so = row * src_stride;
                    let do_ = (ry + row) * fbs + rx * bpp;
                    let n = rw * bpp;
                    if so + n <= data.len() && do_ + n <= s.fb.len() {
                        s.fb[do_..do_ + n].copy_from_slice(&data[so..so + n]);
                    }
                }
            }
            s.frames += 1;
            s.gen = s.gen.wrapping_add(1);
            s.note_damage(x, y, width, height);
        }
        self.damage.notify_waiters();
        self.stats
            .handler_us
            .fetch_add(t0.elapsed().as_micros() as u64, Relaxed);
    }
    #[zbus(name = "Disable")]
    async fn disable(&self) {}
}

async fn build_conn_server(fd: RawFd, m: ListenerMap, v1: ListenerV1) -> zbus::Connection {
    let std_stream = unsafe { StdUnixStream::from_raw_fd(fd) };
    std_stream.set_nonblocking(true).unwrap();
    let tok = tokio::net::UnixStream::from_std(std_stream).unwrap();
    zbus::connection::Builder::unix_stream(tok)
        .p2p()
        .serve_at("/org/qemu/Display1/Listener", m)
        .unwrap()
        .serve_at("/org/qemu/Display1/Listener", v1)
        .unwrap()
        .build()
        .await
        .expect("build listener p2p")
}

/// Build a fresh listener socketpair, serve the Listener interfaces on one end
/// and hand the other end to QEMU via Console.RegisterListener.
pub(super) async fn register_listener(
    main_conn: &zbus::Connection,
    state: &Arc<Mutex<FrameState>>,
    damage: &Arc<Notify>,
    stats: &Arc<CapStats>,
) -> anyhow::Result<zbus::Connection> {
    let m = ListenerMap {
        st: state.clone(),
        damage: damage.clone(),
        stats: stats.clone(),
    };
    let v1 = ListenerV1 {
        st: state.clone(),
        damage: damage.clone(),
        stats: stats.clone(),
    };
    let (list_a, list_b) = socketpair(
        AddressFamily::Unix,
        SockType::Stream,
        None,
        SockFlag::empty(),
    )?;
    let list_a_fd = list_a.into_raw_fd();
    let server_task = tokio::spawn(async move { build_conn_server(list_a_fd, m, v1).await });
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    main_conn
        .call_method(
            None::<&str>,
            CONSOLE,
            Some(I_CONSOLE),
            "RegisterListener",
            &(Fd::from(&list_b),),
        )
        .await?;
    let server_conn = server_task.await?;
    drop(list_b);
    Ok(server_conn)
}
