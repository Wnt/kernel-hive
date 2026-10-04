//! Unit tests for `mame_sock` — split into a sibling file purely for the
//! per-file line budget; `#[path]` keeps them the same inline `mod tests`, with
//! the same access to the module's private items.
use super::*;
use tokio::io::AsyncWriteExt;
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
fn spawn_module(listener: UnixListener, log: Arc<Mutex<Vec<String>>>, drop_after: Option<usize>) {
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

/// ctlsock's per-field KEY pacing under EXCL applies about one edge per
/// 60 ms on the keyboard stations.
const PACE: Duration = Duration::from_millis(60);

fn is_key(verb: &str) -> bool {
    verb.starts_with("KEY ")
}

/// A pasted text as browser make/break edges (real Shift edges round a
/// shifted character) and the exact wire lines they must become.
fn paste(text: &str) -> (Vec<KeyEvent>, Vec<String>) {
    let irix: Option<Arc<KeyMap>> = None;
    let mut edges = Vec::new();
    let mut wire = Vec::new();
    for ch in text.chars() {
        let strokes: &[(u16, bool)] = match ch {
            'a' => &[(0x1e, true), (0x1e, false)],
            'c' => &[(0x2e, true), (0x2e, false)],
            '-' => &[(0x0c, true), (0x0c, false)],
            '_' => &[(0x2a, true), (0x0c, true), (0x0c, false), (0x2a, false)],
            '\n' => &[(0x1c, true), (0x1c, false)],
            _ => unreachable!("no test mapping for {ch:?}"),
        };
        for &(code, down) in strokes {
            edges.push(key(edges.len() as u64 + 1, code, down));
            let (port, field) = key_for(&irix, code).unwrap();
            wire.push(format!("KEY {} {port} {field}", u8::from(down)));
        }
    }
    (edges, wire)
}

/// 15 lines, 390 edges: a short listing pasted in one go.
fn listing() -> (Vec<KeyEvent>, Vec<String>) {
    paste(&"aacc__a-_\n".repeat(15))
}

const PREAMBLE: [&str; 4] = ["UP1", "UP2", "UP3", "MOVEA 0 0"];

async fn settle(log: &crate::sink_mock::ModuleLog, want_acks: usize) {
    crate::sink_mock::wait_until("every edge acked (or a reconnect)", PACE * 2000, || {
        log.acked() >= want_acks || log.connections() > 1
    })
    .await;
}

/// The vic20 incident's shape on the MAME wire: a paste delivered as ONE
/// synchronous batch is accepted whole and reaches the module in order,
/// on one connection.
#[tokio::test(start_paused = true)]
async fn a_pasted_burst_is_accepted_whole_and_written_in_order() {
    let (dir, listener) = crate::sink_mock::bind("mame-burst");
    let log = crate::sink_mock::spawn_paced_module(listener, HELLO, PACE, is_key, None);
    let sink = MameSockSink::new(
        dir.join("ctl.sock").to_str().unwrap().to_string(),
        None,
        None,
    );
    crate::sink_mock::wait_until("healthy + preamble", Duration::from_secs(5), || {
        sink.health() == SinkHealth::Healthy && log.acked() >= PREAMBLE.len()
    })
    .await;

    let (edges, wire) = listing();
    let rejected: Vec<Reject> = edges
        .iter()
        .filter_map(|e| sink.try_key(*e).err())
        .collect();
    assert!(
        rejected.is_empty(),
        "{} of {} edges rejected: first {:?}",
        rejected.len(),
        edges.len(),
        rejected.first()
    );
    settle(&log, PREAMBLE.len() + wire.len()).await;

    assert_eq!(log.connections(), 1, "the sink reconnected");
    let mut want: Vec<String> = PREAMBLE.iter().map(|s| s.to_string()).collect();
    want.extend(wire);
    assert_eq!(log.verbs(), want);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A module working through a long KEY backlog is busy, not dead: no
/// reconnect while it keeps acking at its own pace.
#[tokio::test(start_paused = true)]
async fn a_module_draining_a_long_backlog_is_not_declared_dead() {
    let (dir, listener) = crate::sink_mock::bind("mame-busy");
    let log = crate::sink_mock::spawn_paced_module(listener, HELLO, PACE, is_key, None);
    let sink = MameSockSink::new(
        dir.join("ctl.sock").to_str().unwrap().to_string(),
        None,
        None,
    );
    crate::sink_mock::wait_until("healthy + preamble", Duration::from_secs(5), || {
        sink.health() == SinkHealth::Healthy && log.acked() >= PREAMBLE.len()
    })
    .await;

    let (edges, wire) = listing();
    for chunk in edges.chunks(40) {
        for e in chunk {
            sink.try_key(*e).unwrap();
        }
        crate::sink_mock::wait_until("hand-off queue drained", Duration::from_secs(1), || {
            sink.shared.pending.lock().unwrap().ordered.is_empty()
        })
        .await;
    }
    settle(&log, PREAMBLE.len() + wire.len()).await;

    assert_eq!(log.connections(), 1, "a busy module was declared dead");
    let mut want: Vec<String> = PREAMBLE.iter().map(|s| s.to_string()).collect();
    want.extend(wire);
    assert_eq!(log.verbs(), want);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A module that stops acking is still detected and reconnected, and the
/// new connection is re-preambled.
#[tokio::test(start_paused = true)]
async fn a_module_that_stops_acking_is_reconnected() {
    let (dir, listener) = crate::sink_mock::bind("mame-dead");
    let log = crate::sink_mock::spawn_paced_module(
        listener,
        HELLO,
        PACE,
        is_key,
        Some(PREAMBLE.len() + 10),
    );
    let sink = MameSockSink::new(
        dir.join("ctl.sock").to_str().unwrap().to_string(),
        None,
        None,
    );
    crate::sink_mock::wait_until("healthy + preamble", Duration::from_secs(5), || {
        sink.health() == SinkHealth::Healthy && log.acked() >= PREAMBLE.len()
    })
    .await;
    let (edges, _) = paste("ac_\n");
    for e in edges.iter().cycle().take(40) {
        sink.try_key(*e).unwrap();
    }
    let t0 = Instant::now();
    crate::sink_mock::wait_until("reconnect", Duration::from_secs(30), || {
        log.connections() >= 2
    })
    .await;
    assert!(
        t0.elapsed() < Duration::from_secs(12),
        "took {:?}",
        t0.elapsed()
    );
    crate::sink_mock::wait_until("second preamble", Duration::from_secs(5), || {
        log.verbs().iter().filter(|v| *v == "UP1").count() == 2
    })
    .await;
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
