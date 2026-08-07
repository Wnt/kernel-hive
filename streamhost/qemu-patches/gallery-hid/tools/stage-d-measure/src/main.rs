//! Bounded Solaris Stage-D input latency observer.
//!
//! A second QEMU D-Bus display listener timestamps Update/UpdateMap callback
//! entry with CLOCK_MONOTONIC and copies only two 32x32 cursor ROIs in-handler.
//! The control thread drives one persistent TCP input connection and evaluates
//! calibrated source-disappear/destination-appear templates from those callback
//! snapshots. For native measurements its TCP target is streamhost's optional
//! loopback benchmark ingress, which feeds the production router/sink. It is not
//! the full T2 gate tool.

use anyhow::{bail, Context, Result};
use nix::sys::socket::{
    sendmsg, socketpair, AddressFamily, ControlMessage, MsgFlags, SockFlag, SockType,
};
use serde_json::json;
use std::fs::{create_dir_all, File};
use std::io::{BufRead, BufReader, IoSlice, Write};
use std::net::TcpStream;
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;
use zbus::zvariant::Fd;

const CONSOLE: &str = "/org/qemu/Display1/Console_0";
const IFACE_CONSOLE: &str = "org.qemu.Display1.Console";
const ROI: usize = 32;
const A: (usize, usize) = (1200, 250);
const B: (usize, usize) = (1700, 800);
const MARGIN: usize = 4;
const TIMEOUT: Duration = Duration::from_secs(1);
const FINAL_TIMEOUT_NS: u64 = 100_000_000;
const SETTLE: Duration = Duration::from_millis(70);

fn monotonic_ns() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    assert_eq!(rc, 0);
    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

fn clock_resolution_ns() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    let rc = unsafe { libc::clock_getres(libc::CLOCK_MONOTONIC, &mut ts) };
    assert_eq!(rc, 0);
    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

#[derive(Clone)]
struct DamageEvent {
    callback_ns: u64,
    generation: u64,
    rect: [i32; 4],
    a: Vec<u8>,
    b: Vec<u8>,
    inspect_ns: u64,
}

struct Surface {
    map_ptr: *mut u8,
    map_len: usize,
    offset: usize,
    width: usize,
    height: usize,
    stride: usize,
    fb: Vec<u8>,
    fb_width: usize,
    fb_height: usize,
    fb_stride: usize,
    generation: u64,
}
unsafe impl Send for Surface {}

impl Surface {
    fn new() -> Self {
        Self {
            map_ptr: std::ptr::null_mut(), map_len: 0, offset: 0,
            width: 0, height: 0, stride: 0, fb: Vec::new(),
            fb_width: 0, fb_height: 0, fb_stride: 0, generation: 0,
        }
    }

    fn patch(&self, point: (usize, usize)) -> Option<Vec<u8>> {
        let x = point.0.checked_sub(MARGIN)?;
        let y = point.1.checked_sub(MARGIN)?;
        let (ptr, len, base, width, height, stride) = if !self.map_ptr.is_null() {
            (self.map_ptr as *const u8, self.map_len, self.offset,
             self.width, self.height, self.stride)
        } else if !self.fb.is_empty() {
            (self.fb.as_ptr(), self.fb.len(), 0,
             self.fb_width, self.fb_height, self.fb_stride)
        } else {
            return None;
        };
        if x + ROI > width || y + ROI > height { return None; }
        let mut out = vec![0u8; ROI * ROI * 4];
        for row in 0..ROI {
            let src = base + (y + row) * stride + x * 4;
            if src + ROI * 4 > len { return None; }
            unsafe {
                std::ptr::copy_nonoverlapping(
                    ptr.add(src), out.as_mut_ptr().add(row * ROI * 4), ROI * 4,
                );
            }
        }
        Some(out)
    }

    fn drop_map(&mut self) {
        if !self.map_ptr.is_null() {
            unsafe { libc::munmap(self.map_ptr as *mut libc::c_void, self.map_len); }
            self.map_ptr = std::ptr::null_mut();
            self.map_len = 0;
        }
    }
}

#[derive(Default)]
struct ObserverStats {
    callbacks: AtomicU64,
    inspect_total_ns: AtomicU64,
    inspect_max_ns: AtomicU64,
}

#[derive(Clone)]
struct Listener {
    surface: Arc<Mutex<Surface>>,
    tx: mpsc::Sender<DamageEvent>,
    stats: Arc<ObserverStats>,
}

impl Listener {
    fn capture(&self, callback_ns: u64, rect: [i32; 4]) {
        let mut s = self.surface.lock().unwrap();
        s.generation = s.generation.wrapping_add(1);
        let generation = s.generation;
        let a = s.patch(A);
        let b = s.patch(B);
        drop(s);
        if let (Some(a), Some(b)) = (a, b) {
            let inspect_ns = monotonic_ns().saturating_sub(callback_ns);
            self.stats.callbacks.fetch_add(1, Relaxed);
            self.stats.inspect_total_ns.fetch_add(inspect_ns, Relaxed);
            self.stats.inspect_max_ns.fetch_max(inspect_ns, Relaxed);
            let _ = self.tx.send(DamageEvent {
                callback_ns, generation, rect, a, b, inspect_ns,
            });
        }
    }
}

#[zbus::interface(name = "org.qemu.Display1.Listener.Unix.Map")]
impl Listener {
    async fn scanout_map(
        &self, handle: zbus::zvariant::OwnedFd, offset: u32, width: u32,
        height: u32, stride: u32, _format: u32,
    ) {
        let len = offset as usize + stride as usize * height as usize;
        let ptr = unsafe {
            libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ,
                libc::MAP_SHARED, handle.as_raw_fd(), 0)
        };
        if ptr == libc::MAP_FAILED { return; }
        let mut s = self.surface.lock().unwrap();
        s.drop_map();
        s.map_ptr = ptr as *mut u8;
        s.map_len = len;
        s.offset = offset as usize;
        s.width = width as usize;
        s.height = height as usize;
        s.stride = stride as usize;
        s.fb.clear();
    }

    async fn update_map(&self, x: i32, y: i32, w: i32, h: i32) {
        let callback_ns = monotonic_ns();
        self.capture(callback_ns, [x, y, w, h]);
    }
}

#[derive(Clone)]
struct ListenerV1(Listener);

#[zbus::interface(name = "org.qemu.Display1.Listener")]
impl ListenerV1 {
    #[zbus(property)]
    async fn interfaces(&self) -> Vec<String> {
        vec!["org.qemu.Display1.Listener.Unix.Map".to_string()]
    }

    #[zbus(name = "Scanout")]
    async fn scanout(&self, width: u32, height: u32, stride: u32, _format: u32, data: &[u8]) {
        let callback_ns = monotonic_ns();
        {
            let mut s = self.0.surface.lock().unwrap();
            s.drop_map();
            s.fb_width = width as usize;
            s.fb_height = height as usize;
            s.fb_stride = stride as usize;
            s.fb = data.to_vec();
        }
        self.0.capture(callback_ns, [0, 0, width as i32, height as i32]);
    }

    #[zbus(name = "Update")]
    async fn update(
        &self, x: i32, y: i32, width: i32, height: i32,
        stride: u32, _format: u32, data: &[u8],
    ) {
        let callback_ns = monotonic_ns();
        {
            let mut s = self.0.surface.lock().unwrap();
            if !s.fb.is_empty() && width > 0 && height > 0 {
                let (fw, fh, fs) = (s.fb_width, s.fb_height, s.fb_stride);
                let (rx, ry) = (x.max(0) as usize, y.max(0) as usize);
                let rw = (width as usize).min(fw.saturating_sub(rx));
                let rh = (height as usize).min(fh.saturating_sub(ry));
                for row in 0..rh {
                    let so = row * stride as usize;
                    let dst = (ry + row) * fs + rx * 4;
                    let n = rw * 4;
                    if so + n <= data.len() && dst + n <= s.fb.len() {
                        s.fb[dst..dst + n].copy_from_slice(&data[so..so + n]);
                    }
                }
            }
        }
        self.0.capture(callback_ns, [x, y, width, height]);
    }

    #[zbus(name = "Disable")]
    async fn disable(&self) {}
}

fn qmp_line(reader: &mut impl BufRead) -> Result<String> {
    let mut line = String::new();
    reader.read_line(&mut line)?;
    Ok(line.trim().to_string())
}

async fn p2p_client(fd: RawFd) -> Result<zbus::Connection> {
    let stream = unsafe { UnixStream::from_raw_fd(fd) };
    stream.set_nonblocking(true)?;
    let stream = tokio::net::UnixStream::from_std(stream)?;
    Ok(zbus::connection::Builder::unix_stream(stream).p2p().build().await?)
}

async fn p2p_server(fd: RawFd, listener: Listener) -> Result<zbus::Connection> {
    let stream = unsafe { UnixStream::from_raw_fd(fd) };
    stream.set_nonblocking(true)?;
    let stream = tokio::net::UnixStream::from_std(stream)?;
    Ok(zbus::connection::Builder::unix_stream(stream)
        .p2p()
        .serve_at("/org/qemu/Display1/Listener", listener.clone())?
        .serve_at("/org/qemu/Display1/Listener", ListenerV1(listener))?
        .build().await?)
}

async fn connect_observer(
    qmp_path: &str,
) -> Result<(Arc<Mutex<Surface>>, mpsc::Receiver<DamageEvent>, zbus::Connection, zbus::Connection, Arc<ObserverStats>)> {
    let qmp = UnixStream::connect(qmp_path)?;
    let mut reader = BufReader::new(qmp.try_clone()?);
    let mut writer = qmp.try_clone()?;
    qmp_line(&mut reader)?;
    writeln!(writer, "{}", json!({"execute":"qmp_capabilities"}))?;
    qmp_line(&mut reader)?;

    let (main_a, main_b) = socketpair(AddressFamily::Unix, SockType::Stream, None, SockFlag::empty())?;
    let request = format!("{}\n", json!({"execute":"getfd","arguments":{"fdname":"stage-d-dbus"}}));
    let iov = [IoSlice::new(request.as_bytes())];
    let fds = [main_b.as_raw_fd()];
    let cmsg = [ControlMessage::ScmRights(&fds)];
    sendmsg::<()>(qmp.as_raw_fd(), &iov, &cmsg, MsgFlags::empty(), None)?;
    qmp_line(&mut reader)?;
    drop(main_b);
    writeln!(writer, "{}", json!({"execute":"add_client","arguments":{
        "protocol":"@dbus-display","fdname":"stage-d-dbus"}}))?;
    qmp_line(&mut reader)?;
    let main = p2p_client(main_a.into_raw_fd()).await?;

    let surface = Arc::new(Mutex::new(Surface::new()));
    let stats = Arc::new(ObserverStats::default());
    let (tx, rx) = mpsc::channel();
    let listener = Listener { surface: surface.clone(), tx, stats: stats.clone() };
    let (list_a, list_b) = socketpair(AddressFamily::Unix, SockType::Stream, None, SockFlag::empty())?;
    let task = tokio::spawn(p2p_server(list_a.into_raw_fd(), listener));
    tokio::time::sleep(Duration::from_millis(50)).await;
    main.call_method(None::<&str>, CONSOLE, Some(IFACE_CONSOLE),
        "RegisterListener", &(Fd::from(&list_b),)).await?;
    drop(list_b);
    let server = task.await??;
    tokio::time::sleep(Duration::from_millis(700)).await;
    Ok((surface, rx, main, server, stats))
}

fn patch_pair(surface: &Arc<Mutex<Surface>>) -> Result<(Vec<u8>, Vec<u8>, usize, usize)> {
    let s = surface.lock().unwrap();
    let a = s.patch(A).context("A ROI unavailable")?;
    let b = s.patch(B).context("B ROI unavailable")?;
    let width = if s.width > 0 { s.width } else { s.fb_width };
    let height = if s.height > 0 { s.height } else { s.fb_height };
    Ok((a, b, width, height))
}

fn differing_bytes(a: &[u8], b: &[u8]) -> usize {
    a.iter().zip(b).filter(|(x, y)| x != y).count()
}

fn send_move(stream: &mut TcpStream, point: (usize, usize)) -> Result<u64> {
    let record = format!("M {} {}\n", point.0, point.1);
    let t0 = monotonic_ns();
    stream.write_all(record.as_bytes())?;
    Ok(t0)
}

fn drain(rx: &mpsc::Receiver<DamageEvent>) {
    while rx.try_recv().is_ok() {}
}

fn audit(qmp_path: &str, filename: &str) -> Result<u64> {
    let start = monotonic_ns();
    let qmp = UnixStream::connect(qmp_path)?;
    let mut r = BufReader::new(qmp.try_clone()?);
    let mut w = qmp;
    qmp_line(&mut r)?;
    writeln!(w, "{}", json!({"execute":"qmp_capabilities"}))?;
    qmp_line(&mut r)?;
    writeln!(w, "{}", json!({"execute":"screendump","arguments":{"filename":filename}}))?;
    loop {
        let line = qmp_line(&mut r)?;
        if line.contains("\"return\"") { break; }
    }
    Ok(monotonic_ns() - start)
}

fn stable_at(
    surface: &Arc<Mutex<Surface>>, point: (usize, usize),
    a_cursor: &[u8], a_bg: &[u8], b_cursor: &[u8], b_bg: &[u8], limit: usize,
) -> bool {
    std::thread::sleep(SETTLE);
    let Ok((a, b, _, _)) = patch_pair(surface) else { return false; };
    if point == A {
        differing_bytes(&a, a_cursor) <= limit && differing_bytes(&b, b_bg) <= limit
    } else {
        differing_bytes(&a, a_bg) <= limit && differing_bytes(&b, b_cursor) <= limit
    }
}

fn shuffled_directions(n: usize) -> Vec<bool> {
    let mut v: Vec<bool> = (0..n).map(|i| i % 2 == 0).collect(); // true = A->B
    let mut state = 0x6a09e667f3bcc909u64 ^ n as u64;
    for i in (1..v.len()).rev() {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        v.swap(i, (state as usize) % (i + 1));
    }
    v
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 8 {
        bail!("usage: stage-d-measure QMP INPUT_ADDR PATH CONDITION N OUT.jsonl AUDIT_DIR");
    }
    let qmp_path = &args[1];
    let input_addr = &args[2];
    let path_name = &args[3];
    let condition = &args[4];
    let n: usize = args[5].parse()?;
    let out_path = &args[6];
    let audit_dir = &args[7];
    create_dir_all(audit_dir)?;

    let (surface, rx, _main, _server, stats) = connect_observer(qmp_path).await?;
    let mut input = TcpStream::connect(input_addr)?;
    input.set_nodelay(true)?;

    // Calibration: at B, A is background and B contains the cursor; vice versa at A.
    send_move(&mut input, B)?;
    std::thread::sleep(Duration::from_millis(250));
    let (a_bg, b_cursor, width, height) = patch_pair(&surface)?;
    send_move(&mut input, A)?;
    std::thread::sleep(Duration::from_millis(250));
    let (a_cursor, b_bg, width2, height2) = patch_pair(&surface)?;
    if (width, height) != (1920, 1200) || (width2, height2) != (1920, 1200) {
        bail!("unexpected scanout geometry: {width}x{height}, {width2}x{height2}");
    }
    let a_signal = differing_bytes(&a_cursor, &a_bg);
    let b_signal = differing_bytes(&b_cursor, &b_bg);
    if a_signal < 40 || b_signal < 40 {
        bail!("cursor calibration signal too weak: A={a_signal} B={b_signal} differing bytes");
    }
    let match_limit = 4usize;

    // Warm both directions, unreported.
    let mut current = A;
    for i in 0..50 {
        let target = if i % 2 == 0 { B } else { A };
        send_move(&mut input, target)?;
        std::thread::sleep(Duration::from_millis(25));
        current = target;
    }
    std::thread::sleep(SETTLE);
    drain(&rx);
    let audit0 = format!("{audit_dir}/{path_name}-{condition}-start.ppm");
    let audit_start_ns = audit(qmp_path, &audit0)?;

    let mut out = File::create(out_path)?;
    let directions = shuffled_directions(n);
    for (trial, ab) in directions.into_iter().enumerate() {
        let (source, target, direction) = if ab { (A, B, "A_to_B") } else { (B, A, "B_to_A") };
        if current != source {
            send_move(&mut input, source)?;
            if !stable_at(&surface, source, &a_cursor, &a_bg, &b_cursor, &b_bg, match_limit) {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        let stable = stable_at(&surface, source, &a_cursor, &a_bg, &b_cursor, &b_bg, match_limit);
        drain(&rx);
        let t0_ns = send_move(&mut input, target)?;
        let deadline = std::time::Instant::now() + TIMEOUT;
        let mut early: Option<(DamageEvent, &'static str, usize, usize)> = None;
        let mut final_ok = false;
        while std::time::Instant::now() < deadline {
            let wait = deadline.saturating_duration_since(std::time::Instant::now());
            let Ok(ev) = rx.recv_timeout(wait) else { break; };
            if ev.callback_ns < t0_ns { continue; }
            let (source_patch, source_bg, target_patch, target_cursor) = if ab {
                (&ev.a, &a_bg, &ev.b, &b_cursor)
            } else {
                (&ev.b, &b_bg, &ev.a, &a_cursor)
            };
            let source_bg_score = differing_bytes(source_patch, source_bg);
            let target_cursor_score = differing_bytes(target_patch, target_cursor);
            let disappeared = source_bg_score <= match_limit;
            let appeared = target_cursor_score <= match_limit;
            if early.is_none() && (disappeared || appeared) {
                let kind = match (disappeared, appeared) {
                    (true, true) => "source_gone+target_present",
                    (true, false) => "source_gone",
                    (false, true) => "target_present",
                    _ => unreachable!(),
                };
                early = Some((ev.clone(), kind, source_bg_score, target_cursor_score));
            }
            if disappeared && appeared {
                final_ok = true;
                if early.is_some() { break; }
            }
            if let Some((first, _, _, _)) = &early {
                if ev.callback_ns.saturating_sub(first.callback_ns) > FINAL_TIMEOUT_NS { break; }
            }
        }
        let (status, tfb_ns, latency_us, generation, rect, kind, source_score, target_score, inspect_ns) =
            match early {
                Some((ev, kind, ss, ts)) if final_ok => (
                    "ok", Some(ev.callback_ns), Some((ev.callback_ns - t0_ns) as f64 / 1000.0),
                    Some(ev.generation), Some(ev.rect), Some(kind), Some(ss), Some(ts), Some(ev.inspect_ns)),
                Some((ev, kind, ss, ts)) => (
                    "wrong_target", Some(ev.callback_ns), None, Some(ev.generation), Some(ev.rect),
                    Some(kind), Some(ss), Some(ts), Some(ev.inspect_ns)),
                None => ("timeout", None, None, None, None, None, None, None, None),
            };
        writeln!(out, "{}", json!({
            "trial":trial, "path":path_name, "condition":condition, "direction":direction,
            "source":{"x":source.0,"y":source.1}, "target":{"x":target.0,"y":target.1},
            "stable_before":stable, "enqueue_accepted":true,
            "t0_monotonic_ns":t0_ns, "tfb_monotonic_ns":tfb_ns, "latency_us":latency_us,
            "status":status, "generation":generation, "damage_rect":rect,
            "predicate":kind, "source_bg_diff_bytes":source_score,
            "target_cursor_diff_bytes":target_score, "handler_roi_inspect_ns":inspect_ns
        }))?;
        out.flush()?;
        current = target;
        if (trial + 1) % 100 == 0 {
            std::thread::sleep(SETTLE);
            let filename = format!("{audit_dir}/{path_name}-{condition}-{:04}.ppm", trial + 1);
            let _ = audit(qmp_path, &filename)?;
        }
    }
    std::thread::sleep(SETTLE);
    let audit1 = format!("{audit_dir}/{path_name}-{condition}-end.ppm");
    let audit_end_ns = audit(qmp_path, &audit1)?;
    let callbacks = stats.callbacks.load(Relaxed);
    let meta_path = format!("{out_path}.meta.json");
    let mut meta = File::create(meta_path)?;
    writeln!(meta, "{}", serde_json::to_string_pretty(&json!({
        "method":"coexisting QEMU D-Bus display listener; ROI copy at callback entry",
        "clock":"CLOCK_MONOTONIC", "clock_resolution_ns":clock_resolution_ns(),
        "qmp":qmp_path, "input_addr":input_addr, "path":path_name, "condition":condition,
        "n":n, "warmups":50, "timeout_ms":1000, "settle_ms":70,
        "screen":{"width":width,"height":height},
        "roi":{"size":ROI,"margin":MARGIN,"A":{"x":A.0,"y":A.1},"B":{"x":B.0,"y":B.1}},
        "calibration":{"a_signal_diff_bytes":a_signal,"b_signal_diff_bytes":b_signal,
            "match_limit_diff_bytes":match_limit},
        "observer":{"callbacks":callbacks,
            "mean_handler_roi_inspect_ns":if callbacks>0 {stats.inspect_total_ns.load(Relaxed)/callbacks}else{0},
            "max_handler_roi_inspect_ns":stats.inspect_max_ns.load(Relaxed)},
        "screendump_overhead_ns":{"start":audit_start_ns,"end":audit_end_ns}
    }))?)?;
    Ok(())
}
