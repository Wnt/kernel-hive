//! Test-only stand-in for an emulator control module that PACES its acks the
//! way the real ones do (`vicectl.c`, `ctlsock.cpp`): it reads its socket
//! freely into an unbounded queue, acks a non-paced verb on receipt, and acks
//! a paced verb only when its pacing slot comes round — one per `pace`, in
//! order. That shape is the whole of the 2026-10-04 vic20 incident: a pasted
//! line arrives as one burst, the module drains it at ~8 keys/s, and the
//! daemon must neither drop the burst nor mistake a busy module for a dead one.
//!
//! `ack_limit` makes the module stop acking after that many acks on a
//! connection while it keeps reading and logging — a wedged module, the case
//! the liveness check exists for.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::mpsc;

/// What the mock saw: every verb line in arrival order (seq stripped), and how
/// many connections it accepted. A reconnect is visible as `connections > 1`.
#[derive(Default)]
pub(crate) struct ModuleLog {
    pub(crate) verbs: Mutex<Vec<String>>,
    pub(crate) connections: AtomicUsize,
    /// Acks written, across every connection.
    pub(crate) acked: AtomicUsize,
}

impl ModuleLog {
    pub(crate) fn verbs(&self) -> Vec<String> {
        self.verbs.lock().unwrap().clone()
    }

    pub(crate) fn connections(&self) -> usize {
        self.connections.load(Ordering::SeqCst)
    }

    pub(crate) fn acked(&self) -> usize {
        self.acked.load(Ordering::SeqCst)
    }
}

enum Ack {
    Now(String),
    Paced(String),
}

pub(crate) fn spawn_paced_module(
    listener: UnixListener,
    banner: &'static [u8],
    pace: Duration,
    is_paced: fn(&str) -> bool,
    ack_limit: Option<usize>,
) -> Arc<ModuleLog> {
    let log: Arc<ModuleLog> = Arc::default();
    let out = log.clone();
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                return;
            };
            log.connections.fetch_add(1, Ordering::SeqCst);
            let (rd, mut wr) = stream.into_split();
            if wr.write_all(banner).await.is_err() {
                continue;
            }
            let (tx, mut rx) = mpsc::unbounded_channel::<Ack>();
            // Acker: immediate acks as they come, paced acks one per `pace`.
            let acks = log.clone();
            tokio::spawn(async move {
                let mut queue: VecDeque<String> = VecDeque::new();
                let mut acked = 0usize;
                let mut tick = tokio::time::interval(pace);
                tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                loop {
                    let seq = tokio::select! {
                        msg = rx.recv() => match msg {
                            Some(Ack::Now(seq)) => seq,
                            Some(Ack::Paced(seq)) => {
                                queue.push_back(seq);
                                continue;
                            }
                            None => return,
                        },
                        _ = tick.tick(), if !queue.is_empty() => queue.pop_front().unwrap(),
                    };
                    if ack_limit.is_some_and(|limit| acked >= limit) {
                        continue;
                    }
                    acked += 1;
                    if wr
                        .write_all(format!("{seq} OK\n").as_bytes())
                        .await
                        .is_err()
                    {
                        return;
                    }
                    acks.acked.fetch_add(1, Ordering::SeqCst);
                }
            });
            let log = log.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(rd).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let Some((seq, verb)) = line.split_once(' ') else {
                        continue;
                    };
                    log.verbs.lock().unwrap().push(verb.to_string());
                    let ack = if is_paced(verb) {
                        Ack::Paced(seq.to_string())
                    } else {
                        Ack::Now(seq.to_string())
                    };
                    if tx.send(ack).is_err() {
                        return;
                    }
                }
            });
        }
    });
    out
}

/// A unix listener in a per-test temp dir.
pub(crate) fn bind(tag: &str) -> (std::path::PathBuf, UnixListener) {
    let dir = std::env::temp_dir().join(format!("sinkmock-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sock = dir.join("ctl.sock");
    let _ = std::fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock).unwrap();
    (dir, listener)
}

/// Poll `cond` on the (possibly paused) tokio clock; `limit` is clock time.
pub(crate) async fn wait_until(what: &str, limit: Duration, mut cond: impl FnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + limit;
    while tokio::time::Instant::now() < deadline {
        if cond() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    panic!("timeout waiting for {what}");
}
