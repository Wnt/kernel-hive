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
//! hold/gap-paced (~150 ms per key in a burst) and edge acks can defer behind
//! an in-flight MOVEA up to the chooser's give-up cap (~1.6 s), so the oldest
//! unacked write is declared dead only after 5 s plus 200 ms per outstanding
//! paced verb (keys + edges). MOVEA acks on ACCEPT and needs no allowance; a
//! PAUSED machine services verbs from the frame drain (~40-50 ms), well inside
//! the base. On breach or any read/write error: health Down, close, drop both
//! queues — unacked motion is never replayed — and reconnect forever with
//! 50 ms..1 s backoff. Each (re)connect verifies the HELLO banner, then
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

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::sync::Notify;
use tokio::time::Instant;

use crate::mame_input::{key_for, KeyMap};
use crate::ptr_grid::{GridReckon, GridStep, PtrGrid};
use crate::realtime_input::{
    AcceptedSeq, KeyEvent, PointerAbs, RealtimeInputSink, Reject, SinkHealth,
};

const ORDERED_CAPACITY: usize = 64;
const HEALTH_STARTING: u8 = 0;
const HEALTH_HEALTHY: u8 = 1;
const HEALTH_DOWN: u8 = 2;
/// Ack deadline for the oldest unacked write: base covers MOVEA (acks on
/// accept) plus paused-machine frame-drain pickup; the per-paced allowance
/// covers KEY hold/gap pacing (~150 ms/key) and edges deferred behind an
/// in-flight MOVEA (give-up cap ~1.6 s).
const ACK_BASE: Duration = Duration::from_secs(5);
const ACK_PER_PACED: Duration = Duration::from_millis(200);

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
    notify: Notify,
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
        // onto a neighbouring key (same rule as MameCmdSink).
        let Some((port, field)) = key_for(&self.shared.keymap, event.key) else {
            return Err(Reject::Unsupported);
        };
        let mut p = self.lock_pending()?;
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
            self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
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
}

impl Drop for MameSockSink {
    fn drop(&mut self) {
        self.shared.closed.store(true, Ordering::Release);
        self.shared.notify.notify_waiters();
    }
}

/// One in-flight seq-stamped write awaiting its OK/ERR ack.
struct Sent {
    seq: u64,
    at: Instant,
    paced: bool,
}

/// Deadline for the OLDEST unacked write. Removals keep the deque in send
/// order, so the front is always the oldest; the paced allowance is recomputed
/// from the CURRENT outstanding set each loop iteration.
fn ack_deadline(outstanding: &VecDeque<Sent>) -> Option<Instant> {
    let oldest = outstanding.front()?;
    let paced = outstanding.iter().filter(|s| s.paced).count() as u32;
    Some(oldest.at + ACK_BASE + ACK_PER_PACED * paced)
}

/// Route one module line: OK/ERR acks retire their outstanding entry (the
/// measured receipt->ack RTT feeds telemetry — the A2 evidence path); async
/// `EV` lines (MOVEA convergence, STATS) are not acks and are ignored.
fn on_reply(line: &str, outstanding: &mut VecDeque<Sent>) {
    if line.starts_with("EV ") {
        if trace_on() {
            eprintln!("[mamesock-trace] {line}");
        }
        return;
    }
    let mut tok = line.splitn(3, ' ');
    let (Some(seq), Some(kind)) = (tok.next(), tok.next()) else {
        return;
    };
    let Ok(seq) = seq.parse::<u64>() else { return };
    if kind != "OK" && kind != "ERR" {
        return;
    }
    if let Some(i) = outstanding.iter().position(|s| s.seq == seq) {
        let sent = outstanding.remove(i).unwrap();
        let rtt_us = sent.at.elapsed().as_micros() as u64;
        if trace_on() {
            eprintln!("[mamesock-trace] ack {seq} rtt_us={rtt_us}");
        }
        crate::input_telemetry::record_inject("mamesock", 1, rtt_us, None);
    }
    // An ERR is an ack for liveness (the module processed the verb) but the
    // verb did not apply; surface it, it should never happen on this wire.
    if kind == "ERR" {
        eprintln!("[mamesock] module replied {line}");
    }
}

async fn send_cmd(
    wr: &mut OwnedWriteHalf,
    seq: &mut u64,
    cmd: Cmd,
    outstanding: &mut VecDeque<Sent>,
) -> std::io::Result<()> {
    *seq += 1;
    wr.write_all(format!("{} {}\n", *seq, cmd.line).as_bytes())
        .await?;
    if trace_on() {
        eprintln!("[mamesock-trace] tx {} {}", *seq, cmd.line);
    }
    outstanding.push_back(Sent {
        seq: *seq,
        at: Instant::now(),
        paced: cmd.paced,
    });
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
    let mut outstanding: VecDeque<Sent> = VecDeque::new();
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
        if shared.closed.load(Ordering::Acquire) {
            return;
        }
        let deadline = ack_deadline(&outstanding);
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
mod tests {
    use super::*;
    use tokio::net::UnixListener;

    const HELLO: &[u8] = b"HELLO mamectl/1 test indy_4610 caps=natkbd,savest screen=1288x1024\n";

    fn key(seq: u64, code: u16, down: bool) -> KeyEvent {
        KeyEvent {
            seq,
            key: code,
            down,
            repeat: false,
            modifiers: 0,
        }
    }

    fn ev(seq: u64, x: u32, y: u32, buttons: u16) -> PointerAbs {
        PointerAbs {
            seq,
            x,
            y,
            width: 1288,
            height: 1024,
            buttons,
            wheel_v: 0,
            wheel_h: 0,
            ordered: false,
        }
    }

    /// Mock ctlsock module: accept forever, banner each connection, log every
    /// verb line (seq stripped) and ack it `<seq> OK`. `drop_after` drops the
    /// FIRST connection after acking that many lines (the reconnect fixture);
    /// later connections run until the peer goes away.
    fn spawn_module(
        listener: UnixListener,
        log: Arc<Mutex<Vec<String>>>,
        drop_after: Option<usize>,
    ) {
        tokio::spawn(async move {
            let mut first = true;
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    return;
                };
                let (rd, mut wr) = stream.split();
                if wr.write_all(HELLO).await.is_err() {
                    continue;
                }
                let mut lines = BufReader::new(rd).lines();
                let mut n = 0usize;
                while let Ok(Some(line)) = lines.next_line().await {
                    let Some((seq, verb)) = line.split_once(' ') else {
                        continue;
                    };
                    log.lock().unwrap().push(verb.to_string());
                    if wr
                        .write_all(format!("{seq} OK\n").as_bytes())
                        .await
                        .is_err()
                    {
                        break;
                    }
                    n += 1;
                    if first && drop_after == Some(n) {
                        break; // drop the connection: the sink must resync
                    }
                }
                first = false;
            }
        });
    }

    async fn wait_until(what: &str, mut cond: impl FnMut() -> bool) {
        for _ in 0..2500 {
            if cond() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        panic!("timeout waiting for {what}");
    }

    fn bind(tag: &str) -> (std::path::PathBuf, UnixListener) {
        let dir = std::env::temp_dir().join(format!("mamesock-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("ctl.sock");
        let _ = std::fs::remove_file(&sock);
        let listener = UnixListener::bind(&sock).unwrap();
        (dir, listener)
    }

    /// The full MameCmdSink abs-mode contract on the mamectl wire: the resync
    /// preamble, clamped MOVEA targets, the deliberate restate-before-edge
    /// duplicate for right/middle press+release, a wheel event restating the
    /// target and emitting nothing else, the Shift+'-' and Ctrl-C matrix
    /// chords — and never a MOVEP.
    #[tokio::test]
    async fn wire_contract_matches_mamecmd_abs_mode() {
        let (dir, listener) = bind("wire");
        let log: Arc<Mutex<Vec<String>>> = Arc::default();
        spawn_module(listener, log.clone(), None);

        let sink = MameSockSink::new(
            dir.join("ctl.sock").to_str().unwrap().to_string(),
            None,
            None,
        );
        wait_until("healthy after HELLO", || {
            sink.health() == SinkHealth::Healthy
        })
        .await;
        wait_until("resync preamble", || log.lock().unwrap().len() >= 4).await;

        // Clamps to the last addressable pixel of the 1288x1024 surface. Each
        // step waits for the wire so the latest-wins slot is drained before the
        // next offer — the transcript below is deterministic, not racy.
        sink.try_pointer_abs(ev(1, 9999, 9999, 0)).unwrap();
        wait_until("clamped move", || log.lock().unwrap().len() >= 5).await;
        sink.try_pointer_abs(ev(2, 500, 500, 0)).unwrap();
        wait_until("plain move", || log.lock().unwrap().len() >= 6).await;
        sink.try_pointer_abs(ev(3, 500, 500, 0b100)).unwrap();
        wait_until("right press", || log.lock().unwrap().len() >= 8).await;
        sink.try_pointer_abs(ev(4, 500, 500, 0)).unwrap();
        wait_until("right release", || log.lock().unwrap().len() >= 10).await;
        sink.try_pointer_abs(ev(5, 500, 500, 0b010)).unwrap();
        wait_until("middle press", || log.lock().unwrap().len() >= 12).await;
        sink.try_pointer_abs(ev(6, 500, 500, 0)).unwrap();
        wait_until("middle release", || log.lock().unwrap().len() >= 14).await;
        // Wheel: ignored (no verb), but the ordered path still restates.
        let mut wheel = ev(7, 500, 500, 0);
        wheel.wheel_v = 3;
        wheel.ordered = true;
        sink.try_pointer_abs(wheel).unwrap();
        wait_until("wheel restate", || log.lock().unwrap().len() >= 15).await;
        // Shift+'-' => '_', then Ctrl-C: plain matrix edges, chords are the
        // browser's own make/break stream.
        for (code, down) in [
            (0x2au16, true),
            (0x0c, true),
            (0x0c, false),
            (0x2a, false),
            (0x1d, true),
            (0x2e, true),
            (0x2e, false),
            (0x1d, false),
        ] {
            sink.try_key(key(8, code, down)).unwrap();
        }
        wait_until("key chords", || log.lock().unwrap().len() >= 23).await;

        let lines = log.lock().unwrap().clone();
        assert_eq!(
            lines,
            vec![
                "UP1",
                "UP2",
                "UP3",
                "MOVEA 0 0", // preamble: no held buttons, initial target
                "MOVEA 1287 1023",
                "MOVEA 500 500",
                "MOVEA 500 500",
                "DOWN2",
                "MOVEA 500 500",
                "UP2",
                "MOVEA 500 500",
                "DOWN3",
                "MOVEA 500 500",
                "UP3",
                "MOVEA 500 500", // wheel event: restate only, no wheel verb
                "KEY 1 P1.7 Left Shift",
                "KEY 1 P2.2 -",
                "KEY 0 P2.2 -",
                "KEY 0 P1.7 Left Shift",
                "KEY 1 P1.1 Left Ctrl",
                "KEY 1 P1.4 C",
                "KEY 0 P1.4 C",
                "KEY 0 P1.1 Left Ctrl",
            ]
        );
        assert!(
            lines.iter().all(|l| !l.starts_with("MOVEP")),
            "MOVEP must never reach this wire"
        );
        // Unmapped scancode: rejected without touching the queue.
        assert_eq!(
            sink.try_key(key(99, 0xe011, true)),
            Err(Reject::Unsupported)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The module drops the connection; the sink must go Down, reject (not
    /// queue) offers while down, reconnect, and resync from CURRENT router
    /// truth — never replaying motion that was queued or unacked at the drop.
    /// Deterministic on the current-thread test runtime: between our health
    /// poll and the offer no background task can run.
    #[tokio::test]
    async fn reconnect_resyncs_and_never_replays_motion() {
        let (dir, listener) = bind("reconn");
        let log: Arc<Mutex<Vec<String>>> = Arc::default();
        // Drop connection 1 after the 4-line preamble + 1 move.
        spawn_module(listener, log.clone(), Some(5));

        let sink = MameSockSink::new(
            dir.join("ctl.sock").to_str().unwrap().to_string(),
            None,
            None,
        );
        wait_until("healthy", || sink.health() == SinkHealth::Healthy).await;
        sink.try_pointer_abs(ev(1, 100, 50, 0)).unwrap();
        wait_until("first move on the wire", || log.lock().unwrap().len() >= 5).await;
        wait_until("down after drop", || sink.health() == SinkHealth::Down).await;
        // Down: rejected and NOT queued, but still updates the resync truth.
        assert_eq!(
            sink.try_pointer_abs(ev(2, 200, 80, 0)),
            Err(Reject::BackendDown)
        );
        wait_until("reconnect preamble", || log.lock().unwrap().len() >= 9).await;
        wait_until("healthy again", || sink.health() == SinkHealth::Healthy).await;
        sink.try_pointer_abs(ev(3, 300, 300, 0)).unwrap();
        wait_until("post-reconnect move", || log.lock().unwrap().len() >= 10).await;

        let lines = log.lock().unwrap().clone();
        assert_eq!(
            lines,
            vec![
                "UP1",
                "UP2",
                "UP3",
                "MOVEA 0 0",
                "MOVEA 100 50",
                // Connection 2: the preamble restates the target updated WHILE
                // down; the dropped connection's motion is not replayed.
                "UP1",
                "UP2",
                "UP3",
                "MOVEA 200 80",
                "MOVEA 300 300",
            ]
        );
        assert_eq!(lines.iter().filter(|l| *l == "MOVEA 100 50").count(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Count-grid mode (`SH_MAMESOCK_PTR_GRID`): targets are stated in guest
    /// mouse COUNTS, the first sample homes with a MOVEP slam and a restated
    /// origin, plain motion still coalesces latest-wins, and entering a screen
    /// edge carries a one-shot full-axis slam so a clamping guest and the
    /// module's open-loop belief cannot drift apart.
    #[tokio::test]
    async fn count_grid_homes_states_counts_and_slams_each_edge_once() {
        let (dir, listener) = bind("grid");
        let log: Arc<Mutex<Vec<String>>> = Arc::default();
        spawn_module(listener, log.clone(), None);

        // The live Atari ST arm's measured map: surface x 134..891, y 63..692,
        // on a 79 x 52 count grid.
        let grid = PtrGrid::parse("134,63,891,692,79,52");
        assert!(grid.is_some());
        let sink = MameSockSink::new(
            dir.join("ctl.sock").to_str().unwrap().to_string(),
            grid,
            None,
        );
        wait_until("healthy after HELLO", || {
            sink.health() == SinkHealth::Healthy
        })
        .await;
        wait_until("resync preamble", || log.lock().unwrap().len() >= 4).await;

        // Mid-screen: homes, restates the origin, then the grid target.
        sink.try_pointer_abs(ev(1, 502, 209, 0)).unwrap();
        wait_until("home + target", || log.lock().unwrap().len() >= 7).await;
        // A plain move states a count target and nothing else.
        sink.try_pointer_abs(ev(2, 307, 209, 0)).unwrap();
        wait_until("plain move", || log.lock().unwrap().len() >= 8).await;
        // Into the left edge: target, then the one-shot slam.
        sink.try_pointer_abs(ev(3, 0, 209, 0)).unwrap();
        wait_until("edge entry", || log.lock().unwrap().len() >= 10).await;
        // Parked on it: no second slam.
        sink.try_pointer_abs(ev(4, 0, 260, 0)).unwrap();
        wait_until("parked on edge", || log.lock().unwrap().len() >= 11).await;

        let lines = log.lock().unwrap().clone();
        assert_eq!(
            lines,
            vec![
                "UP1",
                "UP2",
                "UP3",
                "MOVEA 0 0", // preamble
                "MOVEP -87 -60",
                "MOVEA 0 0", // origin restated after the relative slam
                "MOVEA 38 12",
                "MOVEA 18 12",
                "MOVEA 0 12",
                "MOVEP -79 0",
                "MOVEA 0 16",
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Edge verbs keep MameCmdSink's order and bit mapping (bit0=left -> 1,
    /// bit2=right -> 2, bit1=middle -> 3), and all edges are ack-paced. The
    /// (0, held) form is also the resync preamble's re-press builder.
    #[test]
    fn edge_cmds_keep_mamecmd_order_and_bits() {
        let lines = |prev, next| {
            let mut v = Vec::new();
            edge_cmds(prev, next, &mut v);
            assert!(v.iter().all(|c| c.paced));
            v.into_iter().map(|c| c.line).collect::<Vec<_>>()
        };
        assert_eq!(lines(0, 0b111), vec!["DOWN1", "DOWN2", "DOWN3"]);
        assert_eq!(lines(0b111, 0), vec!["UP1", "UP2", "UP3"]);
        assert_eq!(lines(0b001, 0b101), vec!["DOWN2"]); // right press, left held
        assert!(lines(0b010, 0b010).is_empty());
    }

    /// The paced allowance extends the oldest write's deadline per outstanding
    /// KEY/edge; a lone MOVEA carries the 5 s base only.
    #[test]
    fn ack_deadline_extends_per_paced_outstanding() {
        let at = Instant::now();
        let mut q = VecDeque::new();
        assert!(ack_deadline(&q).is_none());
        q.push_back(Sent {
            seq: 1,
            at,
            paced: false,
        });
        assert_eq!(ack_deadline(&q), Some(at + ACK_BASE));
        for seq in 2..=4 {
            q.push_back(Sent {
                seq,
                at,
                paced: true,
            });
        }
        assert_eq!(ack_deadline(&q), Some(at + ACK_BASE + ACK_PER_PACED * 3));
    }
}
