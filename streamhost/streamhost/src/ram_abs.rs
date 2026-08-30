//! `ramabs/1` pointer sink: the wire to a QEMU-side absolute-write control
//! object. First station on it: `rhapsody` (Rhapsody 5.1 DR2 for Intel).
//!
//! This is NOT a closed loop, and must not be read as `mga_ctl`'s sibling in
//! that sense. The guest OS keeps its own pointer coordinate in a known
//! guest-RAM structure; the control object on the QEMU side WRITES the
//! commanded coordinate into that structure and then performs whatever
//! guest-specific step makes the write take effect ("publishes" it). There is
//! no control loop, no gain, no convergence criterion and no hotspot anywhere
//! in this path — the hotspot is a property of the drawn sprite only.
//!
//! The wire is shared by more than one station. Everything guest-specific —
//! the address of the structure, its field layout, the publish step, the
//! verification probe — is a property of the QEMU-side control object, never
//! of this wire. This module carries coordinates and button edges; it knows
//! nothing about where they land.
//!
//! The control object verifies its address at connect time and FAILS CLOSED
//! when the structure is not where it expects it. `STAT` may therefore
//! legitimately answer that the position is not known; this sink must not
//! treat "unknown" as an error, nor as a converged position.
//!
//! Wire contract, a deliberate subset of `mamectl/1` — identical in shape to
//! `mgaptr/1` so the stations read the same way:
//!
//! ```text
//!   <- HELLO ramabs/1 caps=movea,btn,sync,stat surf=1024x768
//!   -> <seq> MOVEA <x> <y>        <- <seq> OK      (acks on accept)
//!   -> <seq> DOWN1|UP1|DOWN2|...  <- <seq> OK      (acks when the edge applies)
//!   -> <seq> SYNC | STAT          <- <seq> OK [k=v ...]
//! ```
//!
//! **Pointer only.** Keys are NOT routed here (`InputRouter::routes_keys`):
//! the guest has a working QEMU/dbus keyboard path and there is no reason to
//! move it. Wheel deltas emit nothing.
//!
//! **Single injector (BINDING).** While this socket is connected the control
//! object owns the guest's pointer completely. Nothing else — no `dbus-rel`
//! bridge, no `input-send-event` over QMP, no `labctl` pointer helper — may
//! push motion or button edges at that mouse, or the two injectors will fight
//! over the guest's pointer state and neither will know where the cursor is.
//!
//! Shape is `MgaCtlSink`'s (itself `MameSockSink`'s), proven: browser receive
//! paths only `try_lock` and offer; connect/HELLO/write/ack-read/reconnect all
//! live in one background task. Move-only targets coalesce latest-wins; button
//! edges ride a bounded ordered queue and flush the pending move ahead of
//! themselves, so restate-before-edge survives the queueing.

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
/// base only has to cover the control object's window; a button edge may be
/// deferred behind its target plus the edge pacer, hence the per-paced
/// allowance.
const ACK_BASE: Duration = Duration::from_secs(5);
const ACK_PER_PACED: Duration = Duration::from_millis(200);

/// `SH_RAMABS_TRACE=on|1`: per-event wire tracing — ingress, every tx line and
/// every ack with its RTT. journald supplies the timestamps.
static TRACE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();

fn trace_on() -> bool {
    *TRACE.get_or_init(|| {
        std::env::var("SH_RAMABS_TRACE")
            .map(|v| v == "on" || v == "1")
            .unwrap_or(false)
    })
}

/// `SH_RAMABS_SOCK`, defaulting to the station directory's `ramabs.sock` — the
/// path QEMU's own `-chardev socket,...` serves for this station.
///
/// Read here rather than carried on `Config`: `config/mod.rs` is at its hard
/// file-size budget, and a sink owning its own knob is the same shape as
/// `mga_ctl::socket_from_env` and `KeyMap::from_env` next door.
pub fn socket_from_env(tile: &str) -> String {
    std::env::var("SH_RAMABS_SOCK")
        .unwrap_or_else(|_| format!("/data/vms/streamhost/stations/{tile}/ramabs.sock"))
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

pub struct RamAbsSink {
    shared: Arc<Shared>,
}

impl RamAbsSink {
    pub fn new(path: String) -> Arc<Self> {
        eprintln!("[input-router] ramabs sink socket={path}");
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
        tokio::spawn(ramabs_task(path, shared.clone()));
        let log_shared = shared.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(10));
            loop {
                tick.tick().await;
                if log_shared.closed.load(Ordering::Relaxed) {
                    break;
                }
                eprintln!("[input-router] ramabs {}", log_shared.counters.line());
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

impl RealtimeInputSink for RamAbsSink {
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
                "[ramabs-trace] rx seq={} raw={},{} clamped={},{} btn={} ordered={}",
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
            // restate-before-edge is what keeps an edge tied to the target it
            // belongs to, on this wire exactly as on the closed-loop ones.
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
        "ramabs"
    }
}

impl Drop for RamAbsSink {
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

/// Route one control-object line. OK/ERR acks retire their outstanding entry;
/// anything else (an unsolicited notice) is not an ack and is ignored.
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
            eprintln!("[ramabs-trace] ack {seq} rtt_us={rtt_us}");
        }
        crate::input_telemetry::record_inject("ramabs", 1, rtt_us, None);
    }
    // An ERR is an ack for liveness (the control object processed the verb)
    // but the verb did not apply; surface it, it should never happen on this
    // wire.
    if kind == "ERR" {
        eprintln!("[ramabs] control object replied {line}");
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
        eprintln!("[ramabs-trace] tx {} {}", *seq, cmd.line);
    }
    outstanding.push_back(Sent {
        seq: *seq,
        at: Instant::now(),
        paced: cmd.paced,
    });
    Ok(())
}

type EngineLines = Lines<BufReader<OwnedReadHalf>>;

/// Connect and verify the control object's banner. The HELLO must arrive
/// within 1 s and parse as `ramabs/1`, else the peer is not a compatible
/// control object — which on these stations means the QEMU binary predates it,
/// and a silent fallback would leave the pointer dead with no explanation.
/// (The control object verifies its guest-RAM address itself and fails closed;
/// this end only verifies the protocol.)
async fn connect_ramabs(path: &str) -> std::io::Result<(EngineLines, OwnedWriteHalf)> {
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
    if !hello.starts_with("HELLO ramabs/1 ") {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("incompatible banner: {hello:?}"),
        ));
    }
    Ok((lines, wr))
}

async fn ramabs_task(path: String, shared: Arc<Shared>) {
    let mut backoff_ms = 50u64;
    let mut seq = 0u64;
    while !shared.closed.load(Ordering::Acquire) {
        shared.health.store(HEALTH_STARTING, Ordering::Release);
        match connect_ramabs(&path).await {
            Ok((mut lines, mut wr)) => {
                eprintln!("[ramabs] connected, HELLO verified {path}");
                backoff_ms = 50;
                run_connection(&shared, &mut lines, &mut wr, &mut seq).await;
            }
            Err(e) => {
                eprintln!("[ramabs] connect/HELLO {path} failed: {e}; retry {backoff_ms}ms");
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
            eprintln!("[ramabs] resync write failed: {e}; reconnecting");
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
                eprintln!("[ramabs] write failed: {e}; reconnecting");
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
                    eprintln!("[ramabs] control object closed the socket; reconnecting");
                    return;
                }
                Err(e) => {
                    eprintln!("[ramabs] read failed: {e}; reconnecting");
                    return;
                }
            },
            _ = tokio::time::sleep_until(deadline.unwrap_or_else(Instant::now)),
                    if deadline.is_some() => {
                eprintln!(
                    "[ramabs] ack timeout ({} outstanding); reconnecting",
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

    const HELLO: &[u8] = b"HELLO ramabs/1 caps=movea,btn,sync,stat surf=1024x768\n";

    fn bind(tag: &str) -> (std::path::PathBuf, UnixListener) {
        let dir = std::env::temp_dir().join(format!("ramabs-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("ramabs.sock");
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

    async fn wait_healthy(sink: &RamAbsSink) {
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
        let sink = RamAbsSink::new(path.to_string_lossy().into_owned());

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
        // ahead of the edge — the duplicate keeps the edge tied to the target
        // it belongs to.
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
        let sink = RamAbsSink::new(path.to_string_lossy().into_owned());

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
        let sink = RamAbsSink::new(path.to_string_lossy().into_owned());

        let (stream, _) = listener.accept().await.unwrap();
        let (_rd, mut wr) = stream.into_split();
        wr.write_all(b"HELLO mgaptr/1 something\n").await.unwrap();
        // The connection is dropped rather than used: an engine that cannot
        // speak ramabs/1 must not be mistaken for one that can.
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_ne!(sink.health(), SinkHealth::Healthy);
    }
}
