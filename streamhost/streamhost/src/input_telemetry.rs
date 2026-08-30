//! Process-global pointer-input telemetry (SH_INPUT_TELEMETRY). DIAGNOSTIC ONLY.
//!
//! One streamhost process serves one station, so a process-global singleton ==
//! per-station telemetry. It answers two questions about the server pointer path:
//!   1. Is the SERVER coalescing many move samples into one guest inject?
//!      `batch_len > 1` proves it — the "curved drag becomes a straight LINE in
//!      Paint" (win98se) and the "skip stale positions to cut latency" theory.
//!   2. How long does each guest inject take, and how stale is the OLDEST
//!      coalesced sample when it finally lands (inject RTT + age)?
//!
//! Three coalescers feed `record_inject`, tagged by backend:
//!   - "dbus"        transport/mod.rs move coalescer   (win98se dbus-abs/rel)
//!   - "warpd"       warpd.rs drain-coalesce writer     (win95 + the six agents)
//!   - "gallery-hid" realtime_input.rs latest-wins slot (Solaris/QNX)
//!
//! InputRouter/WarpdSink `try_lock` contention drops feed `record_router_drop`.
//!
//! Cost when OFF (default): `enabled()` is one relaxed atomic load; every timing
//! (Instant::now) and record_* body early-returns, and the 1 s summary task is
//! never spawned. Hot-path callers additionally gate their Instant::now on
//! `enabled()`, so the fleet pays nothing until a station turns telemetry on.

use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::OnceLock;
use std::time::Duration;

static LEVEL: AtomicU8 = AtomicU8::new(0);
static TEL: OnceLock<InputTelemetry> = OnceLock::new();
/// Live guest button mask (bit b = button b held), updated by `set_button`. Used to
/// answer the circle→line question: are moves injected WHILE a button is held?
static BTN: AtomicU8 = AtomicU8::new(0);
/// Monotonic guest-move counter (one per inject). Stamped into level-2 per-move
/// lines and into each button transition so the button events can be located
/// EXACTLY within the move stream ("button went down at move N, up at move M").
static MOVE_SEQ: AtomicU64 = AtomicU64::new(0);

/// Button edges by the PATH that carried them — NOT gated on
/// SH_INPUT_TELEMETRY, because these exist to contradict a healthy-looking
/// sink line: the mgactl incident logged plausible counters every 10 s for 85
/// minutes while ZERO edges reached the sink, and no number could say so.
/// Named for what is OBSERVED at the count site: `sink-accepted` is the
/// router sink ACCEPTING the ordered offer (not the guest applying it);
/// `dbus-sent` is the edge being written to the QEMU/dbus PS/2 path (which
/// has no ack at all). Reported on the router's 10 s `[input-router] edges`
/// line (realtime_input.rs).
static EDGE_SINK_ACCEPTED: AtomicU64 = AtomicU64::new(0);
static EDGE_DBUS_SENT: AtomicU64 = AtomicU64::new(0);

/// Count one button edge: `to_sink` = accepted by the routed sink as one
/// ordered position+edge event; else = sent down the classic D-Bus PS/2 path.
pub fn record_edge(to_sink: bool) {
    if to_sink {
        EDGE_SINK_ACCEPTED.fetch_add(1, Ordering::Relaxed);
    } else {
        EDGE_DBUS_SENT.fetch_add(1, Ordering::Relaxed);
    }
}

pub fn edge_path_line() -> String {
    format!(
        "sink-accepted={} dbus-sent={}",
        EDGE_SINK_ACCEPTED.load(Ordering::Relaxed),
        EDGE_DBUS_SENT.load(Ordering::Relaxed)
    )
}

/// True once SH_INPUT_TELEMETRY >= 1. Cheap hot-path guard (one relaxed load).
#[inline]
pub fn enabled() -> bool {
    LEVEL.load(Ordering::Relaxed) >= 1
}
/// The configured level (0/1/2), for callers that emit their own per-event line.
#[inline]
pub fn level() -> u8 {
    LEVEL.load(Ordering::Relaxed)
}

/// Wall-clock epoch milliseconds — the SAME clock the ctlsock module's
/// CTLTRACE lines stamp, so a daemon `[key-tel]` line and a module
/// `CTLTRACE ... applied` line for the same edge subtract directly.
pub fn epoch_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// One key edge as the daemon RECEIVED it from the browser (input.rs type=3),
/// before any routing, remap having already run. The keyboard-lag evidence
/// chain starts here: client keyRecorder row -> this line -> the sink's
/// `tx`/`ack` lines -> the module's CTLTRACE `applied` line. No-op when off.
pub fn key_recv(backend: &str, code: u32, down: bool) {
    if !enabled() {
        return;
    }
    eprintln!(
        "[key-tel {backend}] recv ms={} code=0x{code:04x} down={}",
        epoch_ms(),
        u8::from(down),
    );
}

/// One key verb WRITTEN to a control socket (mamesock/vicesock), seq-stamped
/// so the matching `ack` line names the same edge. No-op when off.
pub fn key_tx(backend: &str, seq: u64, line: &str) {
    if !enabled() {
        return;
    }
    eprintln!("[key-tel {backend}] tx ms={} seq={seq} {line}", epoch_ms());
}

/// The module's OK/ERR for a key verb. `rtt_us` covers the module's whole
/// hold/gap/exclusive-scan pacing queue: a key the visitor is still waiting
/// on shows up here as seconds, not the wire's microseconds. No-op when off.
pub fn key_ack(backend: &str, seq: u64, rtt_us: u64) {
    if !enabled() {
        return;
    }
    eprintln!(
        "[key-tel {backend}] ack ms={} seq={seq} rttMs={}",
        epoch_ms(),
        rtt_us / 1000,
    );
}

/// A key edge injected on the QEMU/dbus path, AFTER the SH_KEY_MIN_* gate let
/// it through — the recv->sent delta IS that gate's queue delay. No-op when off.
pub fn key_sent(code: u32, down: bool) {
    if !enabled() {
        return;
    }
    eprintln!(
        "[key-tel dbus] sent ms={} code=0x{code:04x} down={}",
        epoch_ms(),
        u8::from(down),
    );
}

/// One backend's rolling 1 s window. All fields reset (swap 0) each summary tick.
#[derive(Default)]
struct BackendWindow {
    /// Sum of batch_len — total input samples drained across all injects.
    recv: AtomicU64,
    /// Number of guest injects (one per coalescer wakeup/write).
    inject: AtomicU64,
    /// Largest single batch_len seen this window.
    batch_max: AtomicU64,
    rtt_sum_us: AtomicU64,
    rtt_max_us: AtomicU64,
    age_max_us: AtomicU64,
    /// Of `recv` samples this window, how many were injected while a guest button
    /// was held (BTN != 0). held≈recv ⇒ the drag IS a held-button drag server-side
    /// (so a straight LINE result is guest-side); held≈0 ⇒ button/move de-sync.
    held: AtomicU64,
    /// Router/sink `try_lock` contention drops (samples discarded uncounted before).
    drops: AtomicU64,
}

struct InputTelemetry {
    tile: String,
    dbus: BackendWindow,
    warpd: BackendWindow,
    gallery_hid: BackendWindow,
}

impl InputTelemetry {
    fn window(&self, backend: &str) -> Option<&BackendWindow> {
        match backend {
            "dbus" => Some(&self.dbus),
            "warpd" => Some(&self.warpd),
            "gallery-hid" => Some(&self.gallery_hid),
            _ => None,
        }
    }

    fn backends(&self) -> [(&'static str, &BackendWindow); 3] {
        [
            ("dbus", &self.dbus),
            ("warpd", &self.warpd),
            ("gallery-hid", &self.gallery_hid),
        ]
    }
}

/// Initialize the singleton from the parsed config level + station name, and (when
/// level >= 1) spawn the once-per-process 1 s summary task. Idempotent: a second
/// call re-sets the level but leaves the already-installed singleton in place.
pub fn init(level: u8, tile: &str) {
    LEVEL.store(level.min(2), Ordering::Relaxed);
    let _ = TEL.set(InputTelemetry {
        tile: tile.to_string(),
        dbus: BackendWindow::default(),
        warpd: BackendWindow::default(),
        gallery_hid: BackendWindow::default(),
    });
    if level >= 1 {
        tokio::spawn(summary_loop());
    }
}

/// Record ONE guest inject at a coalescer: `batch_len` samples were drained and
/// collapsed into this inject, which took `inj_rtt_us` to apply; `age_us` is how
/// long the OLDEST drained sample waited before it landed (None when the backend
/// does not thread a receive timestamp). No-op when telemetry is off.
pub fn record_inject(backend: &str, batch_len: u64, inj_rtt_us: u64, age_us: Option<u64>) {
    let level = LEVEL.load(Ordering::Relaxed);
    if level == 0 {
        return;
    }
    let seq = MOVE_SEQ.fetch_add(1, Ordering::Relaxed) + 1;
    let mask = BTN.load(Ordering::Relaxed);
    let Some(w) = TEL.get().and_then(|t| t.window(backend)) else {
        return;
    };
    w.recv.fetch_add(batch_len, Ordering::Relaxed);
    w.inject.fetch_add(1, Ordering::Relaxed);
    w.batch_max.fetch_max(batch_len, Ordering::Relaxed);
    w.rtt_sum_us.fetch_add(inj_rtt_us, Ordering::Relaxed);
    w.rtt_max_us.fetch_max(inj_rtt_us, Ordering::Relaxed);
    if mask != 0 {
        w.held.fetch_add(batch_len, Ordering::Relaxed);
    }
    if let Some(age) = age_us {
        w.age_max_us.fetch_max(age, Ordering::Relaxed);
    }
    if level >= 2 {
        // Per-move line: the button mask THAT was live for this inject. mask=0x00
        // while the client is dragging = the guest got a HOVER-move (button lost).
        let age = age_us
            .map(|a| a.to_string())
            .unwrap_or_else(|| "-".to_string());
        eprintln!(
            "[input-tel {backend}] seq={seq} mask=0x{mask:02x} \
             batch={batch_len} rtt={inj_rtt_us} age={age}"
        );
    }
}

/// Record a guest button transition (type-2 press/release), updating the live
/// mask and logging the event. `held` in the next summary then reveals whether
/// the drag's moves were injected while this button stayed down. No-op when off.
pub fn set_button(btn: u8, down: bool) {
    if LEVEL.load(Ordering::Relaxed) == 0 {
        return;
    }
    let bit = 1u8 << (btn & 0x7);
    let mask = if down {
        BTN.fetch_or(bit, Ordering::Relaxed) | bit
    } else {
        BTN.fetch_and(!bit, Ordering::Relaxed) & !bit
    };
    let tile = TEL.get().map(|t| t.tile.as_str()).unwrap_or("");
    let dir = if down { "DOWN" } else { "UP" };
    let seq = MOVE_SEQ.load(Ordering::Relaxed);
    eprintln!("[input-tel BTN {tile}] {dir} btn={btn} mask=0x{mask:02x} atMove={seq}");
}

/// Record one router/sink `try_lock` contention drop (an input sample discarded
/// before it reached the sink). No-op when telemetry is off.
pub fn record_router_drop(backend: &str) {
    if LEVEL.load(Ordering::Relaxed) == 0 {
        return;
    }
    if let Some(w) = TEL.get().and_then(|t| t.window(backend)) {
        w.drops.fetch_add(1, Ordering::Relaxed);
    }
}

async fn summary_loop() {
    let Some(tel) = TEL.get() else {
        return;
    };
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tick.tick().await;
        for (name, w) in tel.backends() {
            let recv = w.recv.swap(0, Ordering::Relaxed);
            if recv == 0 {
                // Idle backend: stay silent and let any router drops accumulate
                // into the next active window rather than log a spurious line.
                continue;
            }
            let inject = w.inject.swap(0, Ordering::Relaxed).max(1);
            let batch_max = w.batch_max.swap(0, Ordering::Relaxed);
            let rtt_sum = w.rtt_sum_us.swap(0, Ordering::Relaxed);
            let rtt_max = w.rtt_max_us.swap(0, Ordering::Relaxed);
            let age_max = w.age_max_us.swap(0, Ordering::Relaxed);
            let held = w.held.swap(0, Ordering::Relaxed);
            let drops = w.drops.swap(0, Ordering::Relaxed);
            let batch_avg = recv as f64 / inject as f64;
            let rtt_avg = rtt_sum as f64 / inject as f64;
            eprintln!(
                "[input-tel {name} {tile}] recv={recv} inject={inject} coalesced={coalesced} \
                 held={held} batch(avg={batch_avg:.1} max={batch_max}) injRttUs(avg={rtt_avg:.1} max={rtt_max}) \
                 ageUs(max={age_max}) drops={drops} window=1000ms",
                tile = tel.tile,
                coalesced = recv.saturating_sub(inject),
            );
        }
    }
}
