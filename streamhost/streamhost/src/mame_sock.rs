//! Native mamectl/1 input sink for the MAME station (issue #45 Stage 2).
//!
//! Same wire contract as `MameCmdSink` abs mode — surface-clamped `MOVEA x y`
//! targets restated before every button edge, `DOWN1/UP1` (left) `DOWN2/UP2`
//! (right) `DOWN3/UP3` (middle), `KEY <0|1> <port> <field>` matrix edges, wheel
//! ignored (3-button PS/2 mouse, no wheel), `MOVEP` never — but carried over
//! the ctlsock OSD module's unix control socket (guest `MAME_CTL_SOCK`, host
//! `SH_MAMECTL_SOCK`) instead of an append-only file tailed by the Lua agent.
//! The socket gives what the file could not: per-verb OK/ERR acks, so backend
//! health is MEASURED (ack liveness) instead of assumed, and a wedged emulator
//! stops accepting input rather than silently spooling it into a file.
//!
//! Architecture is `GalleryHidSink`'s proven shape: browser receive paths only
//! `try_lock` and offer; connect/HELLO/write/ack-read/reconnect all live in one
//! background task. Move-only targets coalesce latest-wins; transitions (button
//! edges, keys) ride a bounded ordered queue and flush the pending move ahead
//! of themselves, so the restate-before-edge property survives the queueing.
//!
//! Ack liveness must not false-trip on the module's pacing: KEY acks apply
//! hold/gap-paced (~60-150 ms per edge in a burst, and a pasted listing is
//! hundreds of edges deep in the module's own unbounded queue) and edge acks
//! can defer behind an in-flight MOVEA up to the chooser's give-up cap
//! (~1.6 s). So the module is judged by PROGRESS — the head of the outstanding
//! list gets 5 s (+200 ms if paced) from the moment it became the head, never
//! a budget counted from when it was sent (`sink_feed` has the incident). MOVEA
//! acks on ACCEPT; a PAUSED machine services verbs from the frame drain
//! (~40-50 ms), well inside the base. On breach or any read/write error:
//! health Down, close, drop both queues — unacked motion is never replayed —
//! and reconnect forever with 50 ms..1 s backoff. Each (re)connect verifies the HELLO banner, then
//! resynchronizes the guest from router truth: UP1..UP3 (the module coalesces
//! redundant releases), a fresh MOVEA of the current target, then DOWNn for
//! each held button.
//!
//! Single-injector rule (BINDING): a station launched with MAME_CTL_SOCK set must
//! NOT also run `-autoboot_script irixagent.lua` — two injectors fight over the
//! module's pacing budgets and accumulators.
//!
//! COUNT-GRID MODE (`SH_MAMESOCK_PTR_GRID`, unset by default and unset on irix,
//! so everything above is exactly what irix still does). A guest with no
//! hardware cursor gives the module nothing to read, and its MOVEA engine
//! degrades to open loop: one ioport COUNT per pixel of target delta. That is
//! an order of magnitude too many counts on a quadrature-encoder pointer like
//! the Atari ST's, and with no reading to correct against the pointer runs away.
//! Set the knob and targets are stated in COUNTS instead — see `ptr_grid` for
//! the measurement and the arithmetic — with `MAME_CTL_SCREEN` set to the same
//! grid so the module clamps where the guest does. The motion still rides
//! `MOVEA` (absolute, acked on accept, safe to coalesce); only the homing slam
//! and the edge slams that keep an open loop from drifting ride `MOVEP`, and
//! those take the ordered queue so they can never be coalesced away.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, TryLockError};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader, Lines};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::sync::Notify;
use tokio::time::Instant;

use crate::mame_input::{key_for, KeyMap};
use crate::ptr_grid::{GridReckon, GridStep, PtrGrid};
use crate::realtime_input::{
    AcceptedSeq, KeyEvent, PointerAbs, RealtimeInputSink, Reject, SinkHealth,
};
use crate::sink_feed::{parse_ack, write_verb, AckLedger, ORDERED_CAPACITY};

const HEALTH_STARTING: u8 = 0;
const HEALTH_HEALTHY: u8 = 1;
const HEALTH_DOWN: u8 = 2;

/// SH_MAMESOCK_TRACE=on|1: per-event wire tracing for the #45 live pointer
/// debugging campaign — browser-event ingress, every tx line, every ack with
/// its RTT, every module EV. journald supplies timestamps. Temporary: the
/// campaign removes the knob and these lines with it.
static TRACE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();

fn trace_on() -> bool {
    *TRACE.get_or_init(|| {
        std::env::var("SH_MAMESOCK_TRACE")
            .map(|v| v == "on" || v == "1")
            .unwrap_or(false)
    })
}

#[derive(Default)]
struct Counters {
    accepted: AtomicU64,
    coalesced: AtomicU64,
    dropped: AtomicU64,
    /// Offers refused because the hand-off queue was full. A pointer edge
    /// refused here is lost (and counted in `dropped` too); a key is re-offered
    /// by `InputRouter::key` once the writer signals `room`.
    overflow: AtomicU64,
    backend_down: AtomicU64,
    /// Key edges whose scancode has no keymap row. Counted AND logged per
    /// edge: a silent unmapped reject was the one loss the 2026-08-12 typing
    /// investigation could not see in any counter.
    unmapped: AtomicU64,
}

impl Counters {
    fn line(&self) -> String {
        format!(
            "accepted={} coalesced={} dropped={} overflow={} backend-down={} unmapped={}",
            self.accepted.load(Ordering::Relaxed),
            self.coalesced.load(Ordering::Relaxed),
            self.dropped.load(Ordering::Relaxed),
            self.overflow.load(Ordering::Relaxed),
            self.backend_down.load(Ordering::Relaxed),
            self.unmapped.load(Ordering::Relaxed),
        )
    }
}

/// One wire verb line, formatted without the seq stamp: the background task
/// stamps seqs at send time so a reconnect renumbers cleanly and a queued
/// command never carries a stale seq across connections.
struct Cmd {
    line: String,
    /// Pace-delayed ack class (KEY and button edges): extends the ack deadline.
    paced: bool,
}

impl Cmd {
    fn movea(x: u32, y: u32) -> Self {
        Self {
            line: format!("MOVEA {x} {y}"),
            paced: false,
        }
    }

    /// Relative counts. Only the count-grid slams use this; it is `paced`
    /// because the module acks a MOVEP when its entry is fully DRAINED, and the
    /// drain runs at the emulated device's own rate (~125 counts/s on the ST),
    /// so a full-grid slam is comfortably over a second of ack latency.
    fn movep(dx: i32, dy: i32) -> Self {
        Self {
            line: format!("MOVEP {dx} {dy}"),
            paced: true,
        }
    }

    fn edge(verb: &str) -> Self {
        Self {
            line: verb.to_string(),
            paced: true,
        }
    }

    fn key(down: bool, port: &str, field: &str) -> Self {
        Self {
            line: format!("KEY {} {port} {field}", u8::from(down)),
            paced: true,
        }
    }
}

/// Button edge verbs for a mask change, in `MameCmdSink`'s exact order and wire
/// bit mapping: bit0=left -> 1, bit2=right -> 2, bit1=middle -> 3.
fn edge_cmds(prev: u16, next: u16, out: &mut Vec<Cmd>) {
    let changed = prev ^ next;
    if changed & 0b001 != 0 {
        out.push(Cmd::edge(if next & 0b001 != 0 { "DOWN1" } else { "UP1" }));
    }
    if changed & 0b100 != 0 {
        out.push(Cmd::edge(if next & 0b100 != 0 { "DOWN2" } else { "UP2" }));
    }
    if changed & 0b010 != 0 {
        out.push(Cmd::edge(if next & 0b010 != 0 { "DOWN3" } else { "UP3" }));
    }
}

struct Pending {
    /// Latest-wins MOVEA target; move-only events coalesce here.
    latest_move: Option<(u32, u32)>,
    ordered: VecDeque<Cmd>,
    /// Browser-truth pointer target + held mask, kept fresh even while the
    /// backend is down: they seed the reconnect resync preamble.
    cur_x: u32,
    cur_y: u32,
    cur_buttons: u16,
    /// Mask as of the last successfully ENQUEUED transition. Edges diff against
    /// this rather than `cur_buttons`, so an Overflow-rejected edge is
    /// re-derived by the next accepted transition instead of silently lost —
    /// the guest's button state must never drift from the browser's.
    queued_buttons: u16,
    /// Count-grid mode only: home/edge bookkeeping. Inert while `Shared::grid`
    /// is None, which is every station that does not set `SH_MAMESOCK_PTR_GRID`.
    grid: GridReckon,
}

struct Shared {
    pending: Mutex<Pending>,
    /// Work for the writer task.
    notify: Notify,
    /// The writer drained the ordered queue (or dropped it on a disconnect):
    /// a key refused as Overflow may be re-offered (`InputRouter::key`).
    room: Notify,
    health: AtomicU8,
    counters: Counters,
    closed: AtomicBool,
    /// `SH_MAMESOCK_PTR_GRID`, frozen at construction. None = state targets in
    /// surface pixels, exactly as before this knob existed.
    grid: Option<PtrGrid>,
    /// `SH_MAMESOCK_KEYMAP`, frozen at construction. None = the IRIX matrix.
    keymap: Option<Arc<KeyMap>>,
}

pub struct MameSockSink {
    shared: Arc<Shared>,
}

impl MameSockSink {
    pub fn new(path: String, grid: Option<PtrGrid>, keymap: Option<Arc<KeyMap>>) -> Arc<Self> {
        match grid {
            Some(g) => eprintln!(
                "[input-router] mamesock sink socket={path} count-grid {}x{}",
                g.cols, g.rows
            ),
            None => eprintln!("[input-router] mamesock sink socket={path}"),
        }
        let shared = Arc::new(Shared {
            pending: Mutex::new(Pending {
                latest_move: None,
                ordered: VecDeque::with_capacity(ORDERED_CAPACITY),
                cur_x: 0,
                cur_y: 0,
                cur_buttons: 0,
                queued_buttons: 0,
                grid: GridReckon::default(),
            }),
            notify: Notify::new(),
            room: Notify::new(),
            health: AtomicU8::new(HEALTH_STARTING),
            counters: Counters::default(),
            closed: AtomicBool::new(false),
            grid,
            keymap,
        });
        tokio::spawn(mamesock_task(path, shared.clone()));
        let log_shared = shared.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(10));
            loop {
                tick.tick().await;
                if log_shared.closed.load(Ordering::Relaxed) {
                    break;
                }
                eprintln!("[input-router] mamesock {}", log_shared.counters.line());
            }
        });
        Arc::new(Self { shared })
    }

    /// Block for the pending queue. Only the offer path and the writer task take
    /// it, both for a few pushes, and neither holds it across an await — so a
    /// button edge can wait for it instead of being thrown away.
    fn lock_pending_ordered(&self) -> std::sync::MutexGuard<'_, Pending> {
        self.shared
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn lock_pending(&self) -> Result<std::sync::MutexGuard<'_, Pending>, Reject> {
        match self.shared.pending.try_lock() {
            Ok(p) => Ok(p),
            Err(TryLockError::WouldBlock) => {
                self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
                Err(Reject::Busy)
            }
            Err(TryLockError::Poisoned(_)) => {
                self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
                Err(Reject::BackendDown)
            }
        }
    }
}

impl RealtimeInputSink for MameSockSink {
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject> {
        // An ORDERED event (a button edge) waits for the queue; a move does not.
        // Same rule as the router's state lock: a dropped move is replaced by the
        // next one, a dropped edge is a click the visitor never gets.
        let mut p = if event.ordered {
            self.lock_pending_ordered()
        } else {
            self.lock_pending()?
        };
        // Surface-clamped target, exactly like MameCmdSink abs mode — or, in
        // count-grid mode, the grid cell the surface point falls in. Retained
        // even while the backend is down: it seeds the resync preamble.
        let (tx, ty) = match self.shared.grid {
            Some(g) => g.map(event.x, event.y),
            None => (
                event.x.min(event.width.saturating_sub(1)),
                event.y.min(event.height.saturating_sub(1)),
            ),
        };
        if trace_on() {
            eprintln!(
                "[mamesock-trace] rx seq={} raw={},{} clamped={},{} btn={} wheel={},{} ordered={}",
                event.seq,
                event.x,
                event.y,
                tx,
                ty,
                event.buttons,
                event.wheel_v,
                event.wheel_h,
                event.ordered
            );
        }
        p.cur_x = tx;
        p.cur_y = ty;
        p.cur_buttons = event.buttons;
        if self.health() != SinkHealth::Healthy {
            self.shared
                .counters
                .backend_down
                .fetch_add(1, Ordering::Relaxed);
            return Err(Reject::BackendDown);
        }

        // Count-grid home/edge bookkeeping. Advanced for EVERY sample, whether
        // or not this one reaches the wire: which edge the pointer is on is a
        // property of where it IS, not of what we happened to send.
        let step = match self.shared.grid {
            Some(g) => p.grid.step(tx, ty, g.cols, g.rows),
            None => GridStep::default(),
        };

        // Wheel deltas emit nothing (matching MameCmdSink), but a wheel event
        // still restates the target below via the ordered path.
        let mut edges = Vec::new();
        edge_cmds(p.queued_buttons, event.buttons, &mut edges);
        if edges.is_empty() && !event.ordered && step.is_plain() {
            if p.latest_move.replace((tx, ty)).is_some() {
                self.shared
                    .counters
                    .coalesced
                    .fetch_add(1, Ordering::Relaxed);
            }
        } else {
            // Homing supersedes any queued target outright: the slam is about
            // to pin the guest into the corner, so spending the pending move's
            // counts first would only delay it.
            let mut pre: Vec<Cmd> = Vec::new();
            if let (true, Some(g)) = (step.home, self.shared.grid) {
                p.latest_move = None;
                let (hx, hy) = g.home_slam();
                pre.push(Cmd::movep(hx, hy));
                // The slam is RELATIVE, and the module's own last-target belief
                // cannot see it. Restate the origin so the target below is
                // differenced from where the guest now actually is.
                pre.push(Cmd::movea(0, 0));
            }
            let mut post: Vec<Cmd> = Vec::new();
            if step.slam_x != 0 || step.slam_y != 0 {
                post.push(Cmd::movep(step.slam_x, step.slam_y));
            }
            let needed =
                usize::from(p.latest_move.is_some()) + pre.len() + 1 + edges.len() + post.len();
            if p.ordered.len() + needed > ORDERED_CAPACITY {
                self.shared
                    .counters
                    .overflow
                    .fetch_add(1, Ordering::Relaxed);
                self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
                return Err(Reject::Overflow);
            }
            // Flush the pending move ahead, then a fresh MOVEA of THIS event's
            // target ahead of its edges — the deliberate duplicate MOVEA of the
            // mamecmd abs contract (restate-before-edge; see its abs_mode tests).
            if let Some((mx, my)) = p.latest_move.take() {
                p.ordered.push_back(Cmd::movea(mx, my));
            }
            p.ordered.extend(pre);
            p.ordered.push_back(Cmd::movea(tx, ty));
            p.ordered.extend(edges);
            p.ordered.extend(post);
            p.queued_buttons = event.buttons;
        }
        self.shared
            .counters
            .accepted
            .fetch_add(1, Ordering::Relaxed);
        drop(p);
        self.shared.notify.notify_one();
        Ok(AcceptedSeq(event.seq))
    }

    fn try_key(&self, event: KeyEvent) -> Result<AcceptedSeq, Reject> {
        // Unmapped scancode: rejected before touching any state, never folded
        // onto a neighbouring key (same rule as MameCmdSink) — but counted
        // and NAMED, so a visitor key the map cannot deliver is evidence,
        // not a silent hole in the telemetry.
        let Some((port, field)) = key_for(&self.shared.keymap, event.key) else {
            self.shared
                .counters
                .unmapped
                .fetch_add(1, Ordering::Relaxed);
            eprintln!(
                "[mamesock] unmapped scancode 0x{:04x} down={}",
                event.key, event.down
            );
            return Err(Reject::Unsupported);
        };
        // A key WAITS for the queue lock, like a button edge: the writer holds
        // it for one pop, and a `try_lock` here was a silent `Busy` drop
        // whenever the two collided on the multi-threaded runtime.
        let mut p = self.lock_pending_ordered();
        if self.health() != SinkHealth::Healthy {
            self.shared
                .counters
                .backend_down
                .fetch_add(1, Ordering::Relaxed);
            return Err(Reject::BackendDown);
        }
        let needed = usize::from(p.latest_move.is_some()) + 1;
        if p.ordered.len() + needed > ORDERED_CAPACITY {
            self.shared
                .counters
                .overflow
                .fetch_add(1, Ordering::Relaxed);
            return Err(Reject::Overflow);
        }
        if let Some((mx, my)) = p.latest_move.take() {
            p.ordered.push_back(Cmd::movea(mx, my));
        }
        p.ordered.push_back(Cmd::key(event.down, port, field));
        self.shared
            .counters
            .accepted
            .fetch_add(1, Ordering::Relaxed);
        drop(p);
        self.shared.notify.notify_one();
        Ok(AcceptedSeq(event.seq))
    }

    fn health(&self) -> SinkHealth {
        match self.shared.health.load(Ordering::Acquire) {
            HEALTH_HEALTHY => SinkHealth::Healthy,
            HEALTH_DOWN => SinkHealth::Down,
            _ => SinkHealth::Starting,
        }
    }

    fn backend_name(&self) -> &'static str {
        "mamesock"
    }

    fn room(&self) -> Option<&Notify> {
        Some(&self.shared.room)
    }
}

impl Drop for MameSockSink {
    fn drop(&mut self) {
        self.shared.closed.store(true, Ordering::Release);
        self.shared.notify.notify_waiters();
    }
}

/// Route one module line: OK/ERR acks retire their outstanding entry (the
/// measured receipt->ack RTT feeds telemetry — the A2 evidence path); async
/// `EV` lines (MOVEA convergence, STATS) are not acks and are ignored.
fn on_reply(line: &str, outstanding: &mut AckLedger) {
    if line.starts_with("EV ") {
        if trace_on() {
            eprintln!("[mamesock-trace] {line}");
        }
        return;
    }
    let Some((seq, err)) = parse_ack(line) else {
        return;
    };
    if let Some(sent) = outstanding.ack(seq) {
        let rtt_us = sent.at.elapsed().as_micros() as u64;
        if trace_on() {
            eprintln!("[mamesock-trace] ack {seq} rtt_us={rtt_us}");
        }
        if sent.key {
            // For a KEY this RTT is the module's whole pacing queue — the
            // number the visitor experiences as keyboard lag.
            crate::input_telemetry::key_ack("mamesock", seq, rtt_us);
        }
        crate::input_telemetry::record_inject("mamesock", 1, rtt_us, None);
    }
    // An ERR is an ack for liveness (the module processed the verb) but the
    // verb did not apply; surface it, it should never happen on this wire.
    if err {
        eprintln!("[mamesock] module replied {line}");
    }
}

async fn send_cmd(
    wr: &mut OwnedWriteHalf,
    seq: &mut u64,
    cmd: Cmd,
    outstanding: &mut AckLedger,
) -> std::io::Result<()> {
    *seq += 1;
    write_verb(wr, *seq, &cmd.line).await?;
    if trace_on() {
        eprintln!("[mamesock-trace] tx {} {}", *seq, cmd.line);
    }
    let key = cmd.line.starts_with("KEY ");
    if key {
        crate::input_telemetry::key_tx("mamesock", *seq, &cmd.line);
    }
    outstanding.sent(*seq, cmd.paced, key);
    Ok(())
}

type ModuleLines = Lines<BufReader<OwnedReadHalf>>;

/// Connect and verify the module's banner. The HELLO must arrive within 1 s and
/// parse as mamectl/1, else the peer is not (a compatible) ctlsock module.
async fn connect_mamectl(path: &str) -> std::io::Result<(ModuleLines, OwnedWriteHalf)> {
    let stream = tokio::time::timeout(Duration::from_secs(1), UnixStream::connect(path))
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "connect timeout"))??;
    let (rd, wr) = stream.into_split();
    let mut lines = BufReader::new(rd).lines();
    let hello = tokio::time::timeout(Duration::from_secs(1), lines.next_line())
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "HELLO timeout"))??
        .ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "EOF before HELLO")
        })?;
    if !hello.starts_with("HELLO mamectl/1 ") {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("incompatible banner: {hello:?}"),
        ));
    }
    Ok((lines, wr))
}

async fn mamesock_task(path: String, shared: Arc<Shared>) {
    let mut backoff_ms = 50u64;
    let mut seq = 0u64;
    while !shared.closed.load(Ordering::Acquire) {
        shared.health.store(HEALTH_STARTING, Ordering::Release);
        match connect_mamectl(&path).await {
            Ok((mut lines, mut wr)) => {
                eprintln!("[mamesock] connected, HELLO verified {path}");
                backoff_ms = 50;
                run_connection(&shared, &mut lines, &mut wr, &mut seq).await;
            }
            Err(e) => {
                eprintln!("[mamesock] connect/HELLO {path} failed: {e}; retry {backoff_ms}ms");
            }
        }
        // Down between connections; drop both queues — unacked motion is never
        // replayed, the resync preamble re-establishes state instead.
        shared.health.store(HEALTH_DOWN, Ordering::Release);
        {
            let mut p = shared.pending.lock().unwrap();
            p.ordered.clear();
            p.latest_move = None;
        }
        // A key waiting for room re-offers now and is refused as BackendDown.
        shared.room.notify_waiters();
        tokio::time::sleep(Duration::from_millis(backoff_ms)).await;
        backoff_ms = (backoff_ms * 2).min(1000);
    }
}

async fn run_connection(
    shared: &Shared,
    lines: &mut ModuleLines,
    wr: &mut OwnedWriteHalf,
    seq: &mut u64,
) {
    // Snapshot router truth and reset the queues under ONE lock, so edges
    // enqueued from here on diff against exactly the mask the preamble states.
    let (cx, cy, buttons) = {
        let mut p = shared.pending.lock().unwrap();
        p.ordered.clear();
        p.latest_move = None;
        p.queued_buttons = p.cur_buttons;
        // A new connection is a new module (or at least one whose open-loop
        // last-target belief we cannot vouch for), so count-grid mode forgets
        // its origin and the next sample re-homes.
        p.grid.reset();
        (p.cur_x, p.cur_y, p.cur_buttons)
    };
    shared.health.store(HEALTH_HEALTHY, Ordering::Release);

    // Resync preamble: releases first (the module coalesces a release of an
    // already-released button away), a fresh statement of the current target,
    // then re-press whatever the visitor is still holding.
    let mut outstanding = AckLedger::default();
    let mut preamble = vec![
        Cmd::edge("UP1"),
        Cmd::edge("UP2"),
        Cmd::edge("UP3"),
        Cmd::movea(cx, cy),
    ];
    edge_cmds(0, buttons, &mut preamble);
    for cmd in preamble {
        if let Err(e) = send_cmd(wr, seq, cmd, &mut outstanding).await {
            eprintln!("[mamesock] resync write failed: {e}; reconnecting");
            return;
        }
    }

    loop {
        loop {
            let next = {
                let mut p = shared.pending.lock().unwrap();
                p.ordered
                    .pop_front()
                    .or_else(|| p.latest_move.take().map(|(x, y)| Cmd::movea(x, y)))
            };
            let Some(cmd) = next else { break };
            if let Err(e) = send_cmd(wr, seq, cmd, &mut outstanding).await {
                eprintln!("[mamesock] write failed: {e}; reconnecting");
                return;
            }
        }
        shared.room.notify_waiters();
        if shared.closed.load(Ordering::Acquire) {
            return;
        }
        let deadline = outstanding.deadline();
        tokio::select! {
            _ = shared.notify.notified() => {}
            line = lines.next_line() => match line {
                Ok(Some(line)) => on_reply(&line, &mut outstanding),
                Ok(None) => {
                    eprintln!("[mamesock] module closed the socket; reconnecting");
                    return;
                }
                Err(e) => {
                    eprintln!("[mamesock] read failed: {e}; reconnecting");
                    return;
                }
            },
            _ = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now)),
                    if deadline.is_some() => {
                eprintln!(
                    "[mamesock] ack timeout ({} outstanding); reconnecting",
                    outstanding.len()
                );
                return;
            }
        }
    }
}

#[cfg(test)]
#[path = "mame_sock_tests.rs"]
mod tests;
