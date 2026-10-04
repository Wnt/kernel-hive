//! Unit tests for `vice_sock` — split into a sibling file purely for the
//! per-file line budget; `#[path]` keeps them the same inline `mod tests`, with
//! the same access to the module's private items.
use super::*;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixListener;

const BANNER: &[u8] = b"vicectl/1 machine=VIC20 rows=16 cols=8 keys=132\n";
/// Shift_L, '2', 'a', Return — enough to prove substitution and passthrough.
const MAP: &str = "0x002a\t0xffe1\t0xffe1\t# Shift_L\n\
                   0x0003\t0x0032\t0x0040\t# 2 at\n\
                   0x001e\t0x0061\t0x0041\t# a A\n\
                   0x001c\t0xff0d\t0xff0d\t# Return\n";

fn key(seq: u64, code: u16, down: bool, modifiers: u16) -> KeyEvent {
    KeyEvent {
        seq,
        key: code,
        down,
        repeat: false,
        modifiers,
    }
}

fn write_map(dir: &std::path::Path, text: &str) -> Arc<ViceKeyMap> {
    let path = dir.join("us-layout.keysyms");
    std::fs::write(&path, text).unwrap();
    Arc::new(ViceKeyMap::load(path.to_str().unwrap()).unwrap())
}

/// Mock `vicectl` module: banner each connection, log every verb line (seq
/// stripped) and ack it `<seq> OK`. `drop_after` drops the FIRST connection
/// after acking that many lines (the reconnect fixture).
fn spawn_module(listener: UnixListener, log: Arc<Mutex<Vec<String>>>, drop_after: Option<usize>) {
    tokio::spawn(async move {
        let mut first = true;
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            let (rd, mut wr) = stream.split();
            if wr.write_all(BANNER).await.is_err() {
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
                    break;
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
    let dir = std::env::temp_dir().join(format!("vicesock-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let sock = dir.join("ctl.sock");
    let _ = std::fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock).unwrap();
    (dir, listener)
}

/// The wire contract: a KEYCLEAR preamble, then one `KEY <0|1> <keysym>` per
/// edge — with the SHIFT LEVEL SUBSTITUTED (Shift+2 is keysym `at`, 0x40 =
/// 64, not `2` plus a shift the guest would have to resolve), Shift_L still
/// forwarded as itself, and the release repeating the pressed keysym even
/// though Shift was let go first.
#[tokio::test]
async fn substitutes_the_shift_level_and_releases_what_it_pressed() {
    let (dir, listener) = bind("wire");
    let log: Arc<Mutex<Vec<String>>> = Arc::default();
    spawn_module(listener, log.clone(), None);
    let map = write_map(&dir, MAP);

    let sink = ViceSockSink::new(dir.join("ctl.sock").to_str().unwrap().to_string(), map);
    wait_until("healthy after banner", || {
        sink.health() == SinkHealth::Healthy
    })
    .await;
    wait_until("KEYCLEAR preamble", || !log.lock().unwrap().is_empty()).await;

    // Shift+2 -> '"' on a C64 (keysym `at` on the host layout), with the
    // visitor releasing Shift BEFORE the digit.
    sink.try_key(key(1, 0x2a, true, 0b01)).unwrap();
    sink.try_key(key(2, 0x03, true, 0b01)).unwrap();
    sink.try_key(key(3, 0x2a, false, 0b00)).unwrap();
    sink.try_key(key(4, 0x03, false, 0b00)).unwrap();
    // A plain letter, then Return.
    sink.try_key(key(5, 0x1e, true, 0)).unwrap();
    sink.try_key(key(6, 0x1e, false, 0)).unwrap();
    sink.try_key(key(7, 0x1c, true, 0)).unwrap();
    sink.try_key(key(8, 0x1c, false, 0)).unwrap();
    wait_until("all edges on the wire", || log.lock().unwrap().len() >= 9).await;

    assert_eq!(
        log.lock().unwrap().clone(),
        vec![
            "KEYCLEAR",
            "KEY 1 65505", // Shift_L 0xffe1, forwarded as itself
            "KEY 1 64",    // '@' — the SHIFTED keysym for scancode 0x03
            "KEY 0 65505",
            "KEY 0 64", // ...and the release repeats it, Shift long gone
            "KEY 1 97", // 'a'
            "KEY 0 97",
            "KEY 1 65293", // Return
            "KEY 0 65293",
        ]
    );
    // A scancode the table does not carry is rejected, never folded onto a
    // neighbour.
    assert_eq!(
        sink.try_key(key(99, 0xe011, true, 0)),
        Err(Reject::Unsupported)
    );
    // Keyboard-only: pointer records are refused.
    assert_eq!(
        sink.try_pointer_abs(PointerAbs {
            seq: 100,
            x: 10,
            y: 10,
            width: 768,
            height: 544,
            buttons: 0,
            wheel_v: 0,
            wheel_h: 0,
            ordered: false,
        }),
        Err(Reject::Unsupported)
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The module drops the connection: the sink goes Down, REJECTS offers while
/// down rather than queueing them, reconnects, and re-preambles with a
/// KEYCLEAR — never re-pressing a key that was held at the drop.
#[tokio::test]
async fn reconnect_clears_and_never_replays_a_held_key() {
    let (dir, listener) = bind("reconn");
    let log: Arc<Mutex<Vec<String>>> = Arc::default();
    spawn_module(listener, log.clone(), Some(2)); // KEYCLEAR + one KEY
    let map = write_map(&dir, MAP);

    let sink = ViceSockSink::new(dir.join("ctl.sock").to_str().unwrap().to_string(), map);
    wait_until("healthy", || sink.health() == SinkHealth::Healthy).await;
    sink.try_key(key(1, 0x1e, true, 0)).unwrap(); // 'a' pressed and HELD
    wait_until("first key on the wire", || log.lock().unwrap().len() >= 2).await;
    wait_until("down after drop", || sink.health() == SinkHealth::Down).await;
    assert_eq!(
        sink.try_key(key(2, 0x1c, true, 0)),
        Err(Reject::BackendDown)
    );
    wait_until("reconnect preamble", || log.lock().unwrap().len() >= 3).await;
    wait_until("healthy again", || sink.health() == SinkHealth::Healthy).await;
    sink.try_key(key(3, 0x1c, true, 0)).unwrap();
    wait_until("post-reconnect key", || log.lock().unwrap().len() >= 4).await;

    assert_eq!(
        log.lock().unwrap().clone(),
        vec!["KEYCLEAR", "KEY 1 97", "KEYCLEAR", "KEY 1 65293"]
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The module's pace: VICE_CTL_KEY_HOLD/_GAP 60/60 with EXCL applies one
/// edge per ~60 ms (measured 7.8 keys/s on vic20).
const PACE: Duration = Duration::from_millis(60);

fn is_key(verb: &str) -> bool {
    verb.starts_with("KEY ")
}

/// A pasted text as the browser delivers it — one make and one break per
/// character, real Shift edges round each shifted one — and the exact wire
/// lines it must become, in order.
fn paste(text: &str) -> (Vec<KeyEvent>, Vec<String>) {
    let mut edges = Vec::new();
    let mut wire = Vec::new();
    for ch in text.chars() {
        let (strokes, lines): (&[(u16, bool, u16)], &[&str]) = match ch {
            'a' => (
                &[(0x1e, true, 0), (0x1e, false, 0)],
                &["KEY 1 97", "KEY 0 97"],
            ),
            '2' => (
                &[(0x03, true, 0), (0x03, false, 0)],
                &["KEY 1 50", "KEY 0 50"],
            ),
            '@' => (
                &[
                    (0x2a, true, 1),
                    (0x03, true, 1),
                    (0x03, false, 1),
                    (0x2a, false, 0),
                ],
                &["KEY 1 65505", "KEY 1 64", "KEY 0 64", "KEY 0 65505"],
            ),
            '\n' => (
                &[(0x1c, true, 0), (0x1c, false, 0)],
                &["KEY 1 65293", "KEY 0 65293"],
            ),
            _ => unreachable!("no test mapping for {ch:?}"),
        };
        for &(code, down, mods) in strokes {
            edges.push(key(edges.len() as u64 + 1, code, down, mods));
        }
        wire.extend(lines.iter().map(|l| l.to_string()));
    }
    (edges, wire)
}

/// 15 lines, 390 edges: a short listing pasted in one go.
fn listing() -> (Vec<KeyEvent>, Vec<String>) {
    paste(&"aa22@@a2@\n".repeat(15))
}

/// Wait until the module has acked everything or the sink reconnected —
/// whichever comes first — on the paused clock.
async fn settle(log: &crate::sink_mock::ModuleLog, want_acks: usize) {
    crate::sink_mock::wait_until("every edge acked (or a reconnect)", PACE * 2000, || {
        log.acked() >= want_acks || log.connections() > 1
    })
    .await;
}

/// THE 2026-10-04 INCIDENT, part 1: a pasted line reaches `try_key` as ONE
/// synchronous batch — the receive task does not yield between records, so
/// the writer task cannot drain the hand-off queue in between. Every edge
/// must be accepted, and the module must get every one of them, in order,
/// on ONE connection.
#[tokio::test(start_paused = true)]
async fn a_pasted_burst_is_accepted_whole_and_written_in_order() {
    let (dir, listener) = crate::sink_mock::bind("vice-burst");
    let log = crate::sink_mock::spawn_paced_module(listener, BANNER, PACE, is_key, None);
    let sink = ViceSockSink::new(
        dir.join("ctl.sock").to_str().unwrap().to_string(),
        write_map(&dir, MAP),
    );
    crate::sink_mock::wait_until("healthy + KEYCLEAR", Duration::from_secs(5), || {
        sink.health() == SinkHealth::Healthy && log.acked() >= 1
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
    settle(&log, 1 + wire.len()).await;

    assert_eq!(
        log.connections(),
        1,
        "the sink reconnected (and KEYCLEARed)"
    );
    let mut want = vec!["KEYCLEAR".to_string()];
    want.extend(wire);
    assert_eq!(log.verbs(), want);
    let _ = std::fs::remove_dir_all(&dir);
}

/// THE 2026-10-04 INCIDENT, part 2: a module working through a long backlog
/// at its own pace is BUSY, not dead. The oldest unacked edge has waited
/// behind hundreds of others, so its age says nothing; a reconnect here
/// KEYCLEARs the module and throws the rest of the paste away. Offered in
/// chunks the hand-off queue can always take, so only liveness is tested.
#[tokio::test(start_paused = true)]
async fn a_module_draining_a_long_backlog_is_not_declared_dead() {
    let (dir, listener) = crate::sink_mock::bind("vice-busy");
    let log = crate::sink_mock::spawn_paced_module(listener, BANNER, PACE, is_key, None);
    let sink = ViceSockSink::new(
        dir.join("ctl.sock").to_str().unwrap().to_string(),
        write_map(&dir, MAP),
    );
    crate::sink_mock::wait_until("healthy + KEYCLEAR", Duration::from_secs(5), || {
        sink.health() == SinkHealth::Healthy && log.acked() >= 1
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
    settle(&log, 1 + wire.len()).await;

    assert_eq!(log.connections(), 1, "a busy module was declared dead");
    let mut want = vec!["KEYCLEAR".to_string()];
    want.extend(wire);
    assert_eq!(log.verbs(), want);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The other half of the liveness contract: a module that STOPS acking
/// (wedged drain, frozen emulator) must still be detected, and the sink
/// must reconnect and re-preamble with KEYCLEAR.
#[tokio::test(start_paused = true)]
async fn a_module_that_stops_acking_is_reconnected() {
    let (dir, listener) = crate::sink_mock::bind("vice-dead");
    // KEYCLEAR + 10 edges acked, then silence on that connection.
    let log = crate::sink_mock::spawn_paced_module(listener, BANNER, PACE, is_key, Some(11));
    let sink = ViceSockSink::new(
        dir.join("ctl.sock").to_str().unwrap().to_string(),
        write_map(&dir, MAP),
    );
    crate::sink_mock::wait_until("healthy + KEYCLEAR", Duration::from_secs(5), || {
        sink.health() == SinkHealth::Healthy && log.acked() >= 1
    })
    .await;
    let (edges, _) = paste("a2@\n");
    for e in edges.iter().cycle().take(40) {
        sink.try_key(*e).unwrap();
    }
    let t0 = Instant::now();
    crate::sink_mock::wait_until("reconnect", Duration::from_secs(30), || {
        log.connections() >= 2
    })
    .await;
    // Detected, and boundedly: the old age-based deadline took 11 s here,
    // the progress-based one ~5.8 s (5 s + one paced allowance after the
    // last ack, ~10 x 60 ms in).
    assert!(
        t0.elapsed() < Duration::from_secs(12),
        "took {:?}",
        t0.elapsed()
    );
    crate::sink_mock::wait_until("second KEYCLEAR", Duration::from_secs(5), || {
        log.verbs().iter().filter(|v| *v == "KEYCLEAR").count() == 2
    })
    .await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// Only a `vicectl/1` peer is spoken to, with or without the HELLO prefix.
#[test]
fn banner_must_name_vicectl_1() {
    assert!(banner_ok("vicectl/1 machine=C64SC rows=16 cols=8 keys=129"));
    assert!(banner_ok("HELLO vicectl/1 machine=VIC20"));
    assert!(banner_ok("vicectl/1"));
    assert!(!banner_ok("HELLO mamectl/1 test indy_4610"));
    assert!(!banner_ok("vicectl/2 machine=C64SC"));
    assert!(!banner_ok("vicectl/10"));
}
