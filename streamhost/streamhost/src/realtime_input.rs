//! Process-wide realtime input router and native gallery-hid backend.
//!
//! Browser receive tasks only take a short `try_lock`, update state, and offer a
//! fixed record. Socket connect/handshake/write/reconnect work lives in one
//! background task. Motion has one latest-wins slot; transitions use a bounded
//! ordered queue and are never coalesced across.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, TryLockError};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::Notify;

use crate::config::{Config, InputBackend};

const RECORD_BYTES: usize = 16;
const ORDERED_CAPACITY: usize = 64;
const HEALTH_STARTING: u8 = 0;
const HEALTH_HEALTHY: u8 = 1;
const HEALTH_DOWN: u8 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AcceptedSeq(pub u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reject {
    Busy,
    Overflow,
    BackendDown,
    Unsupported,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SinkHealth {
    Starting,
    Healthy,
    Down,
}

#[derive(Clone, Copy, Debug)]
pub struct PointerAbs {
    pub seq: u64,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub buttons: u16,
    pub wheel_v: i8,
    pub wheel_h: i8,
    /// Button/wheel snapshots are ordered; move-only snapshots may coalesce.
    pub ordered: bool,
}

// The KeyEvent/try_key path mirrors try_pointer_abs one-for-one. input.rs::handle()
// routes type=3 records here for the `mamecmd`/`mamesock` backends (the IRIX station,
// whose guest has no D-Bus connection to inject over); every other backend still
// takes the classic dbus/warpd key path, so the QEMU fleet is untouched. `repeat` is carried
// but unused by the sinks today — both let the guest auto-repeat from the held key.
#[derive(Clone, Copy, Debug)]
pub struct KeyEvent {
    pub seq: u64,
    pub key: u16,
    pub down: bool,
    pub repeat: bool,
    pub modifiers: u16,
}

pub trait RealtimeInputSink: Send + Sync {
    /// Nonblocking. All socket work is performed by the backend task.
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject>;
    /// Sinks whose transport has no keyboard leave this rejecting; input.rs only
    /// routes keys to backends that implement it.
    fn try_key(&self, _event: KeyEvent) -> Result<AcceptedSeq, Reject> {
        Err(Reject::Unsupported)
    }
    fn health(&self) -> SinkHealth;
    fn backend_name(&self) -> &'static str;
}

#[derive(Default)]
struct Counters {
    accepted: AtomicU64,
    coalesced: AtomicU64,
    dropped: AtomicU64,
    overflow: AtomicU64,
    backend_down: AtomicU64,
}

impl Counters {
    fn line(&self) -> String {
        format!(
            "accepted={} coalesced={} dropped={} overflow={} backend-down={}",
            self.accepted.load(Ordering::Relaxed),
            self.coalesced.load(Ordering::Relaxed),
            self.dropped.load(Ordering::Relaxed),
            self.overflow.load(Ordering::Relaxed),
            self.backend_down.load(Ordering::Relaxed),
        )
    }
}

#[derive(Clone, Copy)]
struct Frame([u8; RECORD_BYTES]);

struct Pending {
    latest_pointer: Option<Frame>,
    ordered: VecDeque<Frame>,
    current_pointer: Frame,
}

struct GalleryShared {
    pending: Mutex<Pending>,
    notify: Notify,
    control: Notify,
    health: AtomicU8,
    counters: Counters,
    closed: AtomicBool,
    paused: AtomicBool,
}

pub struct GalleryHidSink {
    shared: Arc<GalleryShared>,
}

impl GalleryHidSink {
    pub fn new(path: String) -> Arc<Self> {
        let shared = Arc::new(GalleryShared {
            pending: Mutex::new(Pending {
                latest_pointer: None,
                ordered: VecDeque::with_capacity(ORDERED_CAPACITY),
                current_pointer: pointer_frame(PointerAbs {
                    seq: 0,
                    x: 0,
                    y: 0,
                    width: 1,
                    height: 1,
                    buttons: 0,
                    wheel_v: 0,
                    wheel_h: 0,
                    ordered: false,
                }),
            }),
            notify: Notify::new(),
            control: Notify::new(),
            health: AtomicU8::new(HEALTH_STARTING),
            counters: Counters::default(),
            closed: AtomicBool::new(false),
            paused: AtomicBool::new(false),
        });
        tokio::spawn(gallery_writer(path, shared.clone()));
        tokio::spawn(gallery_control_signals(shared.clone()));
        let log_shared = shared.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(10));
            loop {
                tick.tick().await;
                if log_shared.closed.load(Ordering::Relaxed) {
                    break;
                }
                eprintln!("[input-router] gallery-hid {}", log_shared.counters.line());
            }
        });
        Arc::new(Self { shared })
    }

    fn offer(&self, frame: Frame, ordered: bool, seq: u64) -> Result<AcceptedSeq, Reject> {
        // ORDERED events wait for the queue; moves do not. A dropped move is
        // replaced by the next one; a dropped button edge is a click the visitor
        // never gets, and nothing retries it. Neither holder of this lock keeps
        // it across an await, so the wait is microseconds.
        let mut pending = if ordered {
            self.shared
                .pending
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
        } else {
            match self.shared.pending.try_lock() {
                Ok(p) => p,
                Err(TryLockError::WouldBlock) => {
                    self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
                    return Err(Reject::Busy);
                }
                Err(TryLockError::Poisoned(_)) => {
                    self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
                    return Err(Reject::BackendDown);
                }
            }
        };

        // Retain the latest complete pointer state for reconnect recovery even
        // while the backend is down; do not accumulate stale transitions.
        if frame.0[0] == 0x01 {
            let mut snapshot = frame;
            snapshot.0[10] = 0;
            snapshot.0[11] = 0;
            pending.current_pointer = snapshot;
        }
        if self.health() != SinkHealth::Healthy {
            self.shared
                .counters
                .backend_down
                .fetch_add(1, Ordering::Relaxed);
            return Err(Reject::BackendDown);
        }

        if ordered {
            let needed = 1 + usize::from(pending.latest_pointer.is_some());
            if pending.ordered.len() + needed > ORDERED_CAPACITY {
                self.shared
                    .counters
                    .overflow
                    .fetch_add(1, Ordering::Relaxed);
                self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
                return Err(Reject::Overflow);
            }
            if let Some(pointer) = pending.latest_pointer.take() {
                pending.ordered.push_back(pointer);
            }
            pending.ordered.push_back(frame);
        } else if pending.latest_pointer.replace(frame).is_some() {
            self.shared
                .counters
                .coalesced
                .fetch_add(1, Ordering::Relaxed);
        }
        self.shared
            .counters
            .accepted
            .fetch_add(1, Ordering::Relaxed);
        drop(pending);
        self.shared.notify.notify_one();
        Ok(AcceptedSeq(seq))
    }
}

impl RealtimeInputSink for GalleryHidSink {
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject> {
        self.offer(pointer_frame(event), event.ordered, event.seq)
    }

    fn try_key(&self, event: KeyEvent) -> Result<AcceptedSeq, Reject> {
        self.offer(key_frame(event), true, event.seq)
    }

    fn health(&self) -> SinkHealth {
        match self.shared.health.load(Ordering::Acquire) {
            HEALTH_HEALTHY => SinkHealth::Healthy,
            HEALTH_DOWN => SinkHealth::Down,
            _ => SinkHealth::Starting,
        }
    }

    fn backend_name(&self) -> &'static str {
        "gallery-hid"
    }
}

impl Drop for GalleryHidSink {
    fn drop(&mut self) {
        self.shared.closed.store(true, Ordering::Release);
        self.shared.notify.notify_waiters();
        self.shared.control.notify_waiters();
    }
}

/// `/restore` must exclude the process-local gallery socket from `loadvm`.
/// SIGUSR1 pauses (and closes) the backend; SIGUSR2 resumes a fresh GHIN/GHOK
/// handshake after QEMU has loaded the device state. Ordinary input never uses
/// these signals, and non-gallery stations never construct this task.
async fn gallery_control_signals(shared: Arc<GalleryShared>) {
    use tokio::signal::unix::{signal, SignalKind};

    let Ok(mut pause) = signal(SignalKind::user_defined1()) else {
        eprintln!("[gallery-hid] could not install SIGUSR1 restore-pause handler");
        return;
    };
    let Ok(mut resume) = signal(SignalKind::user_defined2()) else {
        eprintln!("[gallery-hid] could not install SIGUSR2 restore-resume handler");
        return;
    };
    loop {
        tokio::select! {
            value = pause.recv() => {
                if value.is_none() { return; }
                shared.paused.store(true, Ordering::Release);
                shared.control.notify_one();
            }
            value = resume.recv() => {
                if value.is_none() { return; }
                shared.paused.store(false, Ordering::Release);
                shared.control.notify_one();
            }
        }
        if shared.closed.load(Ordering::Acquire) {
            return;
        }
    }
}

async fn gallery_writer(path: String, shared: Arc<GalleryShared>) {
    let mut backoff_ms = 50u64;
    while !shared.closed.load(Ordering::Acquire) {
        while shared.paused.load(Ordering::Acquire) && !shared.closed.load(Ordering::Acquire) {
            shared.health.store(HEALTH_DOWN, Ordering::Release);
            shared.control.notified().await;
        }
        if shared.closed.load(Ordering::Acquire) {
            return;
        }
        shared.health.store(HEALTH_STARTING, Ordering::Release);
        match connect_gallery(&path).await {
            Ok(mut stream) => {
                eprintln!("[gallery-hid] connected and GHOK negotiated {path}");
                shared.health.store(HEALTH_HEALTHY, Ordering::Release);
                backoff_ms = 50;

                // A reconnect never replays queued transitions. QEMU/driver also
                // releases on disconnect; establish a clean state then snapshot.
                let current = {
                    let mut pending = shared.pending.lock().unwrap();
                    pending.ordered.clear();
                    pending.latest_pointer = None;
                    pending.current_pointer
                };
                if stream.write_all(&release_all_frame()).await.is_err()
                    || stream.write_all(&restamp(current).0).await.is_err()
                {
                    shared.health.store(HEALTH_DOWN, Ordering::Release);
                    continue;
                }

                loop {
                    if shared.paused.load(Ordering::Acquire) {
                        eprintln!("[gallery-hid] restore pause; closing backend");
                        shared.health.store(HEALTH_DOWN, Ordering::Release);
                        let mut pending = shared.pending.lock().unwrap();
                        pending.ordered.clear();
                        pending.latest_pointer = None;
                        break;
                    }
                    let notified = shared.notify.notified();
                    let next = {
                        let mut pending = shared.pending.lock().unwrap();
                        pending
                            .ordered
                            .pop_front()
                            .or_else(|| pending.latest_pointer.take())
                    };
                    match next {
                        Some(frame) => {
                            if let Err(e) = stream.write_all(&frame.0).await {
                                eprintln!("[gallery-hid] write failed: {e}; reconnecting");
                                shared.health.store(HEALTH_DOWN, Ordering::Release);
                                let mut pending = shared.pending.lock().unwrap();
                                pending.ordered.clear();
                                pending.latest_pointer = None;
                                break;
                            }
                            // Surface gallery-hid in the unified [input-tel] stream.
                            // batch_len=1/rtt=0: the slot's move coalescing already
                            // shows in the [input-router] gallery-hid 10s counters.
                            crate::input_telemetry::record_inject("gallery-hid", 1, 0, None);
                        }
                        None => {
                            tokio::select! {
                                _ = notified => {}
                                _ = shared.control.notified() => {}
                                ready = stream.readable() => {
                                    let disconnected = match ready {
                                        Ok(()) => {
                                            let mut probe = [0u8; 1];
                                            match stream.try_read(&mut probe) {
                                                Ok(0) => true,
                                                Ok(_) => {
                                                    eprintln!("[gallery-hid] unexpected backend data after GHOK; reconnecting");
                                                    true
                                                }
                                                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => false,
                                                Err(e) => {
                                                    eprintln!("[gallery-hid] backend read failed: {e}; reconnecting");
                                                    true
                                                }
                                            }
                                        }
                                        Err(e) => {
                                            eprintln!("[gallery-hid] backend readiness failed: {e}; reconnecting");
                                            true
                                        }
                                    };
                                    if disconnected {
                                        shared.health.store(HEALTH_DOWN, Ordering::Release);
                                        let mut pending = shared.pending.lock().unwrap();
                                        pending.ordered.clear();
                                        pending.latest_pointer = None;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if shared.closed.load(Ordering::Acquire) {
                        return;
                    }
                }
            }
            Err(e) => {
                shared.health.store(HEALTH_DOWN, Ordering::Release);
                eprintln!(
                    "[gallery-hid] connect/handshake {path} failed: {e}; retry {backoff_ms}ms"
                );
            }
        }
        tokio::time::sleep(Duration::from_millis(backoff_ms)).await;
        backoff_ms = (backoff_ms * 2).min(1000);
    }
}

async fn connect_gallery(path: &str) -> std::io::Result<UnixStream> {
    let mut stream = tokio::time::timeout(Duration::from_secs(1), UnixStream::connect(path))
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "connect timeout"))??;
    let mut hello = [0u8; RECORD_BYTES];
    hello[..4].copy_from_slice(b"GHIN");
    hello[4..6].copy_from_slice(&1u16.to_le_bytes());
    hello[6..8].copy_from_slice(&0u16.to_le_bytes());
    hello[8..10].copy_from_slice(&(RECORD_BYTES as u16).to_le_bytes());
    stream.write_all(&hello).await?;
    let mut reply = [0u8; RECORD_BYTES];
    tokio::time::timeout(Duration::from_secs(1), stream.read_exact(&mut reply))
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "GHOK timeout"))??;
    if &reply[..4] != b"GHOK" || u16::from_le_bytes([reply[4], reply[5]]) != 1 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "incompatible gallery-hid GHOK",
        ));
    }
    Ok(stream)
}

fn normalize(pixel: u32, extent: u32) -> u16 {
    if extent <= 1 {
        return 0;
    }
    let p = pixel.min(extent - 1) as u64;
    ((p * 32767 + (extent as u64 - 1) / 2) / (extent as u64 - 1)) as u16
}

fn pointer_frame(event: PointerAbs) -> Frame {
    let mut out = [0u8; RECORD_BYTES];
    out[0] = 0x01;
    // Host sequence is required to be zero; QEMU assigns the ring sequence.
    out[4..6].copy_from_slice(&normalize(event.x, event.width).to_le_bytes());
    out[6..8].copy_from_slice(&normalize(event.y, event.height).to_le_bytes());
    out[8..10].copy_from_slice(&(event.buttons & 0x1f).to_le_bytes());
    out[10] = event.wheel_v as u8;
    out[11] = event.wheel_h as u8;
    out[12..16].copy_from_slice(&crate::clock::now_us().to_le_bytes());
    Frame(out)
}

fn key_frame(event: KeyEvent) -> Frame {
    let mut out = [0u8; RECORD_BYTES];
    out[0] = 0x02;
    out[1] = u8::from(event.down) | (u8::from(event.repeat) << 1);
    out[4..6].copy_from_slice(&event.key.to_le_bytes());
    out[6..8].copy_from_slice(&event.modifiers.to_le_bytes());
    out[12..16].copy_from_slice(&crate::clock::now_us().to_le_bytes());
    Frame(out)
}

fn release_all_frame() -> [u8; RECORD_BYTES] {
    let mut out = [0u8; RECORD_BYTES];
    out[0] = 0x03;
    out[1] = 0x02; // backend disconnect/reconnect recovery
    out[12..16].copy_from_slice(&crate::clock::now_us().to_le_bytes());
    out
}

fn restamp(mut frame: Frame) -> Frame {
    frame.0[12..16].copy_from_slice(&crate::clock::now_us().to_le_bytes());
    frame
}

struct WarpdSink {
    client: Arc<crate::warpd::WarpdClient>,
    buttons: Mutex<u16>,
}

impl WarpdSink {
    fn new(cfg: &Config) -> Arc<Self> {
        Arc::new(Self {
            client: crate::warpd::WarpdClient::new_paced(cfg.warpd_addr.clone(), cfg.warpd_pace_ms),
            buttons: Mutex::new(0),
        })
    }
}

impl RealtimeInputSink for WarpdSink {
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject> {
        let mut previous = self.buttons.try_lock().map_err(|_| {
            crate::input_telemetry::record_router_drop("warpd");
            Reject::Busy
        })?;
        let changed = *previous ^ event.buttons;
        if changed == 0 && event.wheel_v == 0 {
            self.client.send(format!("M {} {}\n", event.x, event.y));
        } else {
            for bit in 0..3u16 {
                let mask = 1u16 << bit;
                if changed & mask != 0 {
                    let verb = if event.buttons & mask != 0 { "P" } else { "R" };
                    self.client
                        .send(format!("{verb} {} {} {}\n", bit + 1, event.x, event.y));
                }
            }
            if event.wheel_v != 0 {
                let button = if event.wheel_v < 0 { 4 } else { 5 };
                self.client
                    .send(format!("B {button} {} {}\n", event.x, event.y));
            }
        }
        *previous = event.buttons;
        Ok(AcceptedSeq(event.seq))
    }

    fn health(&self) -> SinkHealth {
        SinkHealth::Healthy
    }

    fn backend_name(&self) -> &'static str {
        "warpd"
    }
}

#[derive(Clone, Copy)]
struct RouterState {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    buttons: u16,
    /// Modifier mask carried on every KeyEvent. The mamecmd sink does not need it
    /// (the browser sends real Shift/Ctrl make/break, which the matrix presses like
    /// any other key); gallery-hid's wire format does.
    modifiers: u16,
}

pub struct InputRouter {
    sink: Arc<dyn RealtimeInputSink>,
    seq: AtomicU64,
    state: Mutex<RouterState>,
}

impl InputRouter {
    pub fn from_config(cfg: &Config) -> Option<Arc<Self>> {
        let sink: Arc<dyn RealtimeInputSink> = match cfg.input_backend {
            InputBackend::Disabled | InputBackend::DbusAbs | InputBackend::DbusRel => return None,
            InputBackend::Warpd => WarpdSink::new(cfg),
            InputBackend::GalleryHid => GalleryHidSink::new(cfg.ghid_socket.clone()),
            InputBackend::MameCmd => crate::mame_input::MameCmdSink::new(
                &cfg.x11_cmd_file,
                cfg.mamecmd_abs,
                crate::mame_input::KeyMap::from_env(),
            ),
            InputBackend::MameSock => crate::mame_sock::MameSockSink::new(
                cfg.mamectl_sock.clone(),
                crate::ptr_grid::PtrGrid::from_env(),
                crate::mame_input::KeyMap::from_env(),
            ),
            InputBackend::ViceSock => crate::vice_sock::ViceSockSink::new(
                cfg.vicectl_sock.clone(),
                crate::vice_keymap::ViceKeyMap::from_env(),
            ),
            InputBackend::X11Test => {
                match crate::x11_input::X11TestSink::new(&cfg.x11_display, &cfg.x11_cmd_file) {
                    Ok(sink) => sink,
                    Err(e) => {
                        eprintln!("[input-router] x11test sink init failed: {e:#}; input disabled");
                        return None;
                    }
                }
            }
        };
        eprintln!(
            "[input-router] backend={} process-wide health={:?}",
            sink.backend_name(),
            sink.health(),
        );
        Some(Arc::new(Self {
            sink,
            seq: AtomicU64::new(1),
            state: Mutex::new(RouterState {
                x: 0,
                y: 0,
                width: 1,
                height: 1,
                buttons: 0,
                modifiers: 0,
            }),
        }))
    }

    pub fn backend(&self) -> &'static str {
        self.sink.backend_name()
    }

    pub fn health(&self) -> SinkHealth {
        self.sink.health()
    }

    /// try_lock the router state, counting a telemetry drop on contention (these
    /// samples were previously discarded silently, uncounted).
    ///
    /// MOVES ONLY. Dropping a move under contention is free — another one is
    /// always right behind it — but dropping a button EDGE loses the click
    /// outright, and nothing retries it. Edges take `lock_state_ordered`.
    fn lock_state(&self) -> Result<std::sync::MutexGuard<'_, RouterState>, Reject> {
        self.state.try_lock().map_err(|_| {
            crate::input_telemetry::record_router_drop(self.backend());
            Reject::Busy
        })
    }

    /// Block for the router state, for events that MUST NOT be dropped: button
    /// edges, wheel, keys. The lock is held for a handful of field writes plus
    /// one non-blocking sink offer and is never held across an await, so waiting
    /// costs microseconds and cannot deadlock — while losing an edge costs the
    /// visitor a click, or strands a button DOWN in the guest until they find
    /// their way out of a drag they never started (measured on IRIX, 2026-08-05:
    /// a hover stream at ~25/s beat every press to this lock, and every one of
    /// those presses was silently discarded).
    fn lock_state_ordered(&self) -> std::sync::MutexGuard<'_, RouterState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn try_move(&self, x: u32, y: u32, width: u32, height: u32) -> Result<AcceptedSeq, Reject> {
        let mut state = self.lock_state()?;
        state.x = x.min(width.saturating_sub(1));
        state.y = y.min(height.saturating_sub(1));
        state.width = width.max(1);
        state.height = height.max(1);
        self.offer_pointer(&state, 0, 0, false)
    }

    /// A button edge, optionally AT a position the client carried with it.
    ///
    /// Position and edge are applied under ONE acquisition and leave as ONE
    /// ordered event, so nothing — not a concurrent move, not a lock race — can
    /// get between a press and the point it was aimed at.
    pub fn try_button_at(
        &self,
        button: u8,
        down: bool,
        at: Option<(u32, u32, u32, u32)>,
    ) -> Result<AcceptedSeq, Reject> {
        if button >= 5 {
            return Err(Reject::Unsupported);
        }
        let mut state = self.lock_state_ordered();
        if let Some((x, y, width, height)) = at {
            state.x = x.min(width.saturating_sub(1));
            state.y = y.min(height.saturating_sub(1));
            state.width = width.max(1);
            state.height = height.max(1);
        }
        let mask = 1u16 << button;
        if down {
            state.buttons |= mask;
        } else {
            state.buttons &= !mask;
        }
        self.offer_pointer(&state, 0, 0, true)
    }

    pub fn try_button(&self, button: u8, down: bool) -> Result<AcceptedSeq, Reject> {
        self.try_button_at(button, down, None)
    }

    pub fn try_wheel(&self, dx: i32, dy: i32) -> Result<AcceptedSeq, Reject> {
        let state = self.lock_state_ordered();
        let wheel_v = dy.clamp(-127, 127) as i8;
        let wheel_h = dx.clamp(-127, 127) as i8;
        self.offer_pointer(&state, wheel_v, wheel_h, true)
    }

    pub fn try_key(&self, key: u16, down: bool, repeat: bool) -> Result<AcceptedSeq, Reject> {
        let mut state = self.state.try_lock().map_err(|_| Reject::Busy)?;
        if let Some(bit) = modifier_bit(key) {
            if down {
                state.modifiers |= 1 << bit;
            } else {
                state.modifiers &= !(1 << bit);
            }
        }
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        self.sink.try_key(KeyEvent {
            seq,
            key,
            down,
            repeat,
            modifiers: state.modifiers,
        })
    }

    fn offer_pointer(
        &self,
        state: &RouterState,
        wheel_v: i8,
        wheel_h: i8,
        ordered: bool,
    ) -> Result<AcceptedSeq, Reject> {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        self.sink.try_pointer_abs(PointerAbs {
            seq,
            x: state.x,
            y: state.y,
            width: state.width,
            height: state.height,
            buttons: state.buttons,
            wheel_v,
            wheel_h,
            ordered,
        })
    }
}

fn modifier_bit(key: u16) -> Option<u8> {
    match key {
        0x002a => Some(0),
        0x0036 => Some(1),
        0x001d => Some(2),
        0xe01d => Some(3),
        0x0038 => Some(4),
        0xe038 => Some(5),
        0xe05b => Some(6),
        0xe05c => Some(7),
        _ => None,
    }
}

#[cfg(test)]
#[path = "realtime_input_tests.rs"]
mod tests;
