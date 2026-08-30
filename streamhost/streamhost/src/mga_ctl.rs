//! `mgaptr/1` pointer sink: the client half of the aix432 closed loop.
//!
//! Every other relative-pointer station in the fleet reckons absolute
//! coordinates by DEAD RECKONING — pin the guest cursor into a corner once,
//! then push deltas from where the daemon *believes* it is (`rel_bridge`).
//! The belief is wrong the moment the guest accelerates, clamps at a screen
//! edge or warps the pointer, and only the visitor shoving the cursor into a
//! corner ever re-syncs the two.
//!
//! `aix432` does not have to believe anything. AIX's GXT130P X server drives
//! the emulated Matrox HARDWARE cursor, so the guest writes the pointer
//! position into the DAC's CURPOSX/CURPOSY registers on every move — and the
//! device model reads them. The closed loop therefore lives INSIDE QEMU, at
//! the emulator's own rate and with direct register access, exactly as `irix`
//! runs its MOVEA engine inside MAME over the Newport VC2's cursor registers
//! (`docs/IO-PATHS.md`, the `mamesock (closed loop)` row). This module is only
//! the wire to it.
//!
//! Wire contract (`hw/display/mga.c`, "Closed-loop 1:1 pointer"), a deliberate
//! subset of `mamectl/1` so the two closed-loop stations read the same way:
//!
//! ```text
//!   <- HELLO mgaptr/1 caps=movea,btn,sync,stat surf=1024x768
//!   -> <seq> MOVEA <x> <y>        <- <seq> OK      (acks on target-ACCEPT)
//!   -> <seq> DOWN1|UP1|DOWN2|...  <- <seq> OK      (acks when the edge APPLIES)
//!   -> <seq> SYNC | STAT          <- <seq> OK [k=v ...]
//! ```
//!
//! A target acks on accept, never on convergence: the browser streams targets
//! far faster than any pointer converges, and a client that waited for one
//! would stall the whole stream. Button edges ack when they apply, which is
//! after the target they were restated behind has landed — that deferral is
//! the engine's, and it is what makes a click land where the visitor aimed it.
//!
//! **Pointer only.** Keys are NOT routed here (`InputRouter::routes_keys`):
//! this guest has a working QEMU/dbus keyboard path and there is no reason to
//! move it. Wheel deltas emit nothing — the guest has a 3-button PS/2 mouse.
//!
//! **Single injector (BINDING).** While this socket is connected the engine
//! owns the guest's pointer completely. Nothing else — no `dbus-rel` bridge,
//! no `input-send-event` over QMP, no `labctl` pointer helper — may push
//! motion or button edges at that mouse, or the two injectors will fight over
//! the guest's PS/2 accumulator and neither will know where the cursor is.
//!
//! Shape is `MameSockSink`'s, proven: browser receive paths only `try_lock`
//! and offer; connect/HELLO/write/ack-read/reconnect all live in one
//! background task. Move-only targets coalesce latest-wins; button edges ride
//! a bounded ordered queue and flush the pending move ahead of themselves, so
//! restate-before-edge survives the queueing.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, TryLockError};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::sync::Notify;
use tokio::time::Instant;

use crate::realtime_input::{AcceptedSeq, PointerAbs, RealtimeInputSink, Reject, SinkHealth};

const ORDERED_CAPACITY: usize = 64;
const HEALTH_STARTING: u8 = 0;
const HEALTH_HEALTHY: u8 = 1;
const HEALTH_DOWN: u8 = 2;

/// Ack deadline for the OLDEST unacked write. MOVEA acks on accept, so the
/// base only has to cover the engine's window; a button edge can wait for the
/// target ahead of it to converge or hit its give-up cap (`ptr-tries` windows
/// of `ptr-window-ms`, ~0.7 s at the defaults) plus the edge pacer, hence the
/// per-paced allowance.
const ACK_BASE: Duration = Duration::from_secs(5);
const ACK_PER_PACED: Duration = Duration::from_millis(200);

/// `SH_MGACTL_TRACE=on|1`: per-event wire tracing — ingress, every tx line and
/// every ack with its RTT. journald supplies the timestamps.
static TRACE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();

fn trace_on() -> bool {
    *TRACE.get_or_init(|| {
        std::env::var("SH_MGACTL_TRACE")
            .map(|v| v == "on" || v == "1")
            .unwrap_or(false)
    })
}

/// `SH_MGACTL_SOCK`, defaulting to the station directory's `ptr.sock` — the
/// path QEMU's own `-chardev socket,...` serves for this station.
///
/// Read here rather than carried on `Config`: `config/mod.rs` is at its hard
/// file-size budget, and a sink owning its own knob is the same shape as
/// `PtrGrid::from_env` and `KeyMap::from_env` next door.
pub fn socket_from_env(tile: &str) -> String {
    std::env::var("SH_MGACTL_SOCK")
        .unwrap_or_else(|_| format!("/data/vms/streamhost/stations/{tile}/ptr.sock"))
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

/// One wire verb, formatted without its seq stamp: the background task stamps
/// seqs at send time so a reconnect renumbers cleanly and a queued command
/// never carries a stale seq across connections.
struct Cmd {
    line: String,
    /// Pace-delayed ack class (button edges): extends the ack deadline.
    paced: bool,
}

impl Cmd {
    fn movea(x: u32, y: u32) -> Self {
        Self {
            line: format!("MOVEA {x} {y}"),
            paced: false,
        }
    }

    fn edge(verb: &str) -> Self {
        Self {
            line: verb.to_string(),
            paced: true,
        }
    }
}

/// Button edge verbs for a mask change, in the fleet's wire bit mapping:
/// bit0=left -> 1, bit2=right -> 2, bit1=middle -> 3.
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
    /// Browser-truth target + held mask, kept fresh even while the backend is
    /// down: they seed the reconnect resync preamble.
    cur_x: u32,
    cur_y: u32,
    cur_buttons: u16,
    /// Mask as of the last successfully ENQUEUED transition. Edges diff
    /// against this rather than `cur_buttons`, so an Overflow-rejected edge is
    /// re-derived by the next accepted transition instead of silently lost.
    queued_buttons: u16,
}

struct Shared {
    pending: Mutex<Pending>,
    notify: Notify,
    health: AtomicU8,
    counters: Counters,
    closed: AtomicBool,
}

pub struct MgaCtlSink {
    shared: Arc<Shared>,
}

impl MgaCtlSink {
    pub fn new(path: String) -> Arc<Self> {
        eprintln!("[input-router] mgactl sink socket={path}");
        let shared = Arc::new(Shared {
            pending: Mutex::new(Pending {
                latest_move: None,
                ordered: VecDeque::with_capacity(ORDERED_CAPACITY),
                cur_x: 0,
                cur_y: 0,
                cur_buttons: 0,
                queued_buttons: 0,
            }),
            notify: Notify::new(),
            health: AtomicU8::new(HEALTH_STARTING),
            counters: Counters::default(),
            closed: AtomicBool::new(false),
        });
        tokio::spawn(mgactl_task(path, shared.clone()));
        let log_shared = shared.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(10));
            loop {
                tick.tick().await;
                if log_shared.closed.load(Ordering::Relaxed) {
                    break;
                }
                eprintln!("[input-router] mgactl {}", log_shared.counters.line());
            }
        });
        Arc::new(Self { shared })
    }

    /// Blocking take. Only the offer path and the writer task hold it, both for
    /// a few pushes and neither across an await — so a button edge can wait for
    /// it instead of being thrown away.
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

impl RealtimeInputSink for MgaCtlSink {
    fn try_pointer_abs(&self, event: PointerAbs) -> Result<AcceptedSeq, Reject> {
        // An ORDERED event (a button edge) waits for the queue; a move does
        // not. A dropped move is replaced by the next one; a dropped edge is a
        // click the visitor never gets.
        let mut p = if event.ordered {
            self.lock_pending_ordered()
        } else {
            self.lock_pending()?
        };
        let tx = event.x.min(event.width.saturating_sub(1));
        let ty = event.y.min(event.height.saturating_sub(1));
        if trace_on() {
            eprintln!(
                "[mgactl-trace] rx seq={} raw={},{} clamped={},{} btn={} ordered={}",
                event.seq, event.x, event.y, tx, ty, event.buttons, event.ordered
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

        let mut edges = Vec::new();
        edge_cmds(p.queued_buttons, event.buttons, &mut edges);
        if edges.is_empty() && !event.ordered {
            if p.latest_move.replace((tx, ty)).is_some() {
                self.shared
                    .counters
                    .coalesced
                    .fetch_add(1, Ordering::Relaxed);
            }
        } else {
            let needed = usize::from(p.latest_move.is_some()) + 1 + edges.len();
            if p.ordered.len() + needed > ORDERED_CAPACITY {
                self.shared
                    .counters
                    .overflow
                    .fetch_add(1, Ordering::Relaxed);
                self.shared.counters.dropped.fetch_add(1, Ordering::Relaxed);
                return Err(Reject::Overflow);
            }
            // Flush the pending move ahead, then a fresh MOVEA of THIS event's
            // target ahead of its edges. The duplicate MOVEA is deliberate:
            // restate-before-edge is what lets the engine hold the edge until
            // the pointer has actually landed on the target it belongs to.
            if let Some((mx, my)) = p.latest_move.take() {
                p.ordered.push_back(Cmd::movea(mx, my));
            }
            p.ordered.push_back(Cmd::movea(tx, ty));
            p.ordered.extend(edges);
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

    fn health(&self) -> SinkHealth {
        match self.shared.health.load(Ordering::Acquire) {
            HEALTH_HEALTHY => SinkHealth::Healthy,
            HEALTH_DOWN => SinkHealth::Down,
            _ => SinkHealth::Starting,
        }
    }

    fn backend_name(&self) -> &'static str {
        "mgactl"
    }
}

impl Drop for MgaCtlSink {
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
/// order, so the front is always the oldest.
fn ack_deadline(outstanding: &VecDeque<Sent>) -> Option<Instant> {
    let oldest = outstanding.front()?;
    let paced = outstanding.iter().filter(|s| s.paced).count() as u32;
    Some(oldest.at + ACK_BASE + ACK_PER_PACED * paced)
}

/// Route one engine line. OK/ERR acks retire their outstanding entry; anything
/// else (an unsolicited notice) is not an ack and is ignored.
fn on_reply(line: &str, outstanding: &mut VecDeque<Sent>) {
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
            eprintln!("[mgactl-trace] ack {seq} rtt_us={rtt_us}");
        }
        crate::input_telemetry::record_inject("mgactl", 1, rtt_us, None);
    }
    // An ERR is an ack for liveness (the engine processed the verb) but the
    // verb did not apply; surface it, it should never happen on this wire.
    if kind == "ERR" {
        eprintln!("[mgactl] engine replied {line}");
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
        eprintln!("[mgactl-trace] tx {} {}", *seq, cmd.line);
    }
    outstanding.push_back(Sent {
        seq: *seq,
        at: Instant::now(),
        paced: cmd.paced,
    });
    Ok(())
}

type EngineLines = Lines<BufReader<OwnedReadHalf>>;

/// Connect and verify the engine's banner. The HELLO must arrive within 1 s and
/// parse as `mgaptr/1`, else the peer is not a compatible closed-loop engine —
/// which on this station means the QEMU binary predates it, and a silent
/// fallback would leave the pointer dead with no explanation.
async fn connect_mgaptr(path: &str) -> std::io::Result<(EngineLines, OwnedWriteHalf)> {
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
    if !hello.starts_with("HELLO mgaptr/1 ") {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("incompatible banner: {hello:?}"),
        ));
    }
    Ok((lines, wr))
}

async fn mgactl_task(path: String, shared: Arc<Shared>) {
    let mut backoff_ms = 50u64;
    let mut seq = 0u64;
    while !shared.closed.load(Ordering::Acquire) {
        shared.health.store(HEALTH_STARTING, Ordering::Release);
        match connect_mgaptr(&path).await {
            Ok((mut lines, mut wr)) => {
                eprintln!("[mgactl] connected, HELLO verified {path}");
                backoff_ms = 50;
                run_connection(&shared, &mut lines, &mut wr, &mut seq).await;
            }
            Err(e) => {
                eprintln!("[mgactl] connect/HELLO {path} failed: {e}; retry {backoff_ms}ms");
            }
        }
        // Down between connections; drop both queues — unacked motion is never
        // replayed, the resync preamble re-establishes state instead.
        shared.health.store(HEALTH_DOWN, Ordering::Release);
        {
            let mut p = shared
                .pending
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            p.ordered.clear();
            p.latest_move = None;
        }
        tokio::time::sleep(Duration::from_millis(backoff_ms)).await;
        backoff_ms = (backoff_ms * 2).min(1000);
    }
}

async fn run_connection(
    shared: &Shared,
    lines: &mut EngineLines,
    wr: &mut OwnedWriteHalf,
    seq: &mut u64,
) {
    // Snapshot router truth and reset the queues under ONE lock, so edges
    // enqueued from here on diff against exactly the mask the preamble states.
    let (cx, cy, buttons) = {
        let mut p = shared
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        p.ordered.clear();
        p.latest_move = None;
        p.queued_buttons = p.cur_buttons;
        (p.cur_x, p.cur_y, p.cur_buttons)
    };
    shared.health.store(HEALTH_HEALTHY, Ordering::Release);

    // Resync preamble: releases first (a release of an already-released button
    // is a no-op on the guest), a fresh statement of the current target, then
    // re-press whatever the visitor is still holding.
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
            eprintln!("[mgactl] resync write failed: {e}; reconnecting");
            return;
        }
    }

    loop {
        loop {
            let next = {
                let mut p = shared
                    .pending
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                p.ordered
                    .pop_front()
                    .or_else(|| p.latest_move.take().map(|(x, y)| Cmd::movea(x, y)))
            };
            let Some(cmd) = next else { break };
            if let Err(e) = send_cmd(wr, seq, cmd, &mut outstanding).await {
                eprintln!("[mgactl] write failed: {e}; reconnecting");
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
                    eprintln!("[mgactl] engine closed the socket; reconnecting");
                    return;
                }
                Err(e) => {
                    eprintln!("[mgactl] read failed: {e}; reconnecting");
                    return;
                }
            },
            _ = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now)),
                    if deadline.is_some() => {
                eprintln!(
                    "[mgactl] ack timeout ({} outstanding); reconnecting",
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

    const HELLO: &[u8] = b"HELLO mgaptr/1 caps=movea,btn,sync,stat surf=1024x768\n";

    fn bind(tag: &str) -> (std::path::PathBuf, UnixListener) {
        let dir = std::env::temp_dir().join(format!("mgactl-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("ptr.sock");
        let _ = std::fs::remove_file(&sock);
        let listener = UnixListener::bind(&sock).unwrap();
        (sock, listener)
    }

    fn ev(seq: u64, x: u32, y: u32, buttons: u16) -> PointerAbs {
        PointerAbs {
            seq,
            x,
            y,
            width: 1024,
            height: 768,
            buttons,
            wheel_v: 0,
            wheel_h: 0,
            ordered: buttons != 0,
        }
    }

    async fn wait_healthy(sink: &MgaCtlSink) {
        for _ in 0..200 {
            if sink.health() == SinkHealth::Healthy {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("sink never reached Healthy");
    }

    /// Read `n` lines from the accepted connection, acking each one, and return
    /// them stripped of their seq stamp.
    async fn drain(
        rd: &mut Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
        wr: &mut OwnedWriteHalf,
        n: usize,
    ) -> Vec<String> {
        let mut out = Vec::new();
        for _ in 0..n {
            let line = tokio::time::timeout(Duration::from_secs(2), rd.next_line())
                .await
                .expect("verb timeout")
                .unwrap()
                .unwrap();
            let (seq, rest) = line.split_once(' ').unwrap();
            wr.write_all(format!("{seq} OK\n").as_bytes())
                .await
                .unwrap();
            out.push(rest.to_string());
        }
        out
    }

    #[tokio::test]
    async fn restates_the_target_before_every_edge() {
        let (path, listener) = bind("restate");
        let sink = MgaCtlSink::new(path.to_string_lossy().into_owned());

        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut rd = BufReader::new(rd).lines();
        wr.write_all(HELLO).await.unwrap();
        wait_healthy(&sink).await;

        // The resync preamble: three releases and the current target.
        assert_eq!(
            drain(&mut rd, &mut wr, 4).await,
            vec!["UP1", "UP2", "UP3", "MOVEA 0 0"]
        );

        sink.try_pointer_abs(ev(1, 400, 300, 0)).unwrap();
        sink.try_pointer_abs(ev(2, 401, 301, 0b001)).unwrap();
        // The pending move is flushed, then the press's own target is restated
        // ahead of the edge — that duplicate is what lets the engine hold the
        // click until the pointer has landed.
        assert_eq!(
            drain(&mut rd, &mut wr, 3).await,
            vec!["MOVEA 400 300", "MOVEA 401 301", "DOWN1"]
        );

        sink.try_pointer_abs(ev(3, 401, 301, 0)).unwrap();
        assert_eq!(
            drain(&mut rd, &mut wr, 2).await,
            vec!["MOVEA 401 301", "UP1"]
        );
    }

    #[tokio::test]
    async fn moves_coalesce_latest_wins() {
        let (path, listener) = bind("coalesce");
        let sink = MgaCtlSink::new(path.to_string_lossy().into_owned());

        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut rd = BufReader::new(rd).lines();
        wr.write_all(HELLO).await.unwrap();
        wait_healthy(&sink).await;
        drain(&mut rd, &mut wr, 4).await;

        // Offer a burst without letting the writer task run in between: only
        // the newest target may reach the wire.
        {
            let mut p = sink.lock_pending_ordered();
            p.latest_move = Some((10, 10));
            p.latest_move = Some((20, 20));
            p.latest_move = Some((30, 30));
        }
        sink.shared.notify.notify_one();
        assert_eq!(drain(&mut rd, &mut wr, 1).await, vec!["MOVEA 30 30"]);
    }

    #[tokio::test]
    async fn a_wrong_banner_is_refused() {
        let (path, listener) = bind("banner");
        let sink = MgaCtlSink::new(path.to_string_lossy().into_owned());

        let (stream, _) = listener.accept().await.unwrap();
        let (_rd, mut wr) = stream.into_split();
        wr.write_all(b"HELLO mamectl/1 something\n").await.unwrap();
        // The connection is dropped rather than used: an engine that cannot
        // speak mgaptr/1 must not be mistaken for one that can.
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_ne!(sink.health(), SinkHealth::Healthy);
    }
}
