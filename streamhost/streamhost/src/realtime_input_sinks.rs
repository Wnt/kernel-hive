//! The two sinks that predate the socket-sink family: `GalleryHidSink` (the
//! gallery HID wire) and `WarpdSink` (the frozen warpd guest agents). Split
//! out of `realtime_input.rs` purely for the per-file line budget; `#[path]`
//! keeps this a private child module, so the router and its tests keep the
//! same access to these items they had inline. The router, its traits and
//! `backend_routes_buttons` stay in `realtime_input.rs`.
use super::*;

#[derive(Default)]
pub(super) struct Counters {
    pub(super) accepted: AtomicU64,
    pub(super) coalesced: AtomicU64,
    pub(super) dropped: AtomicU64,
    pub(super) overflow: AtomicU64,
    pub(super) backend_down: AtomicU64,
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
pub(super) struct Frame(pub(super) [u8; RECORD_BYTES]);

pub(super) struct Pending {
    pub(super) latest_pointer: Option<Frame>,
    pub(super) ordered: VecDeque<Frame>,
    pub(super) current_pointer: Frame,
}

pub(super) struct GalleryShared {
    pub(super) pending: Mutex<Pending>,
    pub(super) notify: Notify,
    pub(super) control: Notify,
    pub(super) health: AtomicU8,
    pub(super) counters: Counters,
    pub(super) closed: AtomicBool,
    pub(super) paused: AtomicBool,
}

pub(super) struct GalleryHidSink {
    pub(super) shared: Arc<GalleryShared>,
}

impl GalleryHidSink {
    pub(super) fn new(path: String) -> Arc<Self> {
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

pub(super) fn normalize(pixel: u32, extent: u32) -> u16 {
    if extent <= 1 {
        return 0;
    }
    let p = pixel.min(extent - 1) as u64;
    ((p * 32767 + (extent as u64 - 1) / 2) / (extent as u64 - 1)) as u16
}

pub(super) fn pointer_frame(event: PointerAbs) -> Frame {
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

pub(super) fn key_frame(event: KeyEvent) -> Frame {
    let mut out = [0u8; RECORD_BYTES];
    out[0] = 0x02;
    out[1] = u8::from(event.down) | (u8::from(event.repeat) << 1);
    out[4..6].copy_from_slice(&event.key.to_le_bytes());
    out[6..8].copy_from_slice(&event.modifiers.to_le_bytes());
    out[12..16].copy_from_slice(&crate::clock::now_us().to_le_bytes());
    Frame(out)
}

pub(super) fn release_all_frame() -> [u8; RECORD_BYTES] {
    let mut out = [0u8; RECORD_BYTES];
    out[0] = 0x03;
    out[1] = 0x02; // backend disconnect/reconnect recovery
    out[12..16].copy_from_slice(&crate::clock::now_us().to_le_bytes());
    out
}

pub(super) fn restamp(mut frame: Frame) -> Frame {
    frame.0[12..16].copy_from_slice(&crate::clock::now_us().to_le_bytes());
    frame
}

pub(super) struct WarpdSink {
    pub(super) client: Arc<crate::warpd::WarpdClient>,
    pub(super) buttons: Mutex<u16>,
}

impl WarpdSink {
    pub(super) fn new(cfg: &Config) -> Arc<Self> {
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
        crate::probes::probe!(INPUT_ABS_WARPD);
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
