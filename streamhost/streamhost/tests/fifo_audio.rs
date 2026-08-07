// Integration: the paced FIFO PCM source end-to-end — a temp named pipe plus a
// synthetic writer must yield AudioOut Opus packets at the 20 ms tick cadence,
// proving the DAEMON (not the writer) is the clock. #[ignore]d because it needs
// a real fifo in the temp dir and ~1 s of wall clock; run explicitly:
//   cargo test --test fifo_audio -- --ignored

use std::io::Write;
use std::time::{Duration, Instant};

/// s16le stereo 48 kHz, one 20 ms tick = 960 frames = 3840 B — must match
/// audio.rs FIFO_TICK_BYTES or the cadence assertion below is meaningless.
const TICK_BYTES: usize = 960 * 2 * 2;

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs a real fifo + ~1 s wall clock; not for the default CI lane"]
async fn fifo_packets_arrive_at_20ms_cadence() {
    // Unique per-process path: concurrent agents share the box temp dir.
    let path = std::env::temp_dir().join(format!("sh-fifo-audio-{}.fifo", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let cpath = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(
        unsafe { libc::mkfifo(cpath.as_ptr(), 0o600) },
        0,
        "mkfifo {path:?}"
    );

    // Synthetic producer: a loud square wave (amplitude 8000, far above the
    // silence threshold, so the gate stays open) written as fast as the pipe
    // accepts it — backpressure is what paces it, exactly like SDL's disk
    // driver with SDL_DISKAUDIODELAY=0. O_WRONLY open blocks until the daemon
    // thread opens the read side, so no start-order coordination is needed.
    let wpath = path.clone();
    let writer = std::thread::spawn(move || {
        let mut f = match std::fs::OpenOptions::new().write(true).open(&wpath) {
            Ok(f) => f,
            Err(_) => return, // fifo unlinked before we opened: test is over
        };
        let mut chunk = Vec::with_capacity(TICK_BYTES);
        for i in 0..960u32 {
            let s: i16 = if (i / 24) % 2 == 0 { 8000 } else { -8000 }; // ~1 kHz
            chunk.extend_from_slice(&s.to_le_bytes()); // L
            chunk.extend_from_slice(&s.to_le_bytes()); // R
        }
        // 100 ticks = 2 s of audio, comfortably more than the test consumes;
        // the final (blocked) write dies with the process.
        for _ in 0..100 {
            if f.write_all(&chunk).is_err() {
                return;
            }
        }
    });

    let out = streamhost::audio::start_fifo(path.to_str().unwrap().to_string(), 96_000, 4)
        .expect("start_fifo");
    let mut rx = out.tx.subscribe();

    // The first packet absorbs fifo open + drain + writer start — anchor the
    // clock on it rather than timing it.
    let first = tokio::time::timeout(Duration::from_secs(10), rx.recv())
        .await
        .expect("timed out waiting for the first Opus packet")
        .expect("audio broadcast closed");
    assert!(!first.data.is_empty());
    let t0 = Instant::now();
    let mut seq = first.seq;

    const N: u32 = 25; // 25 packets at one per 20 ms tick = 500 ms nominal
    for _ in 0..N {
        let pkt = tokio::time::timeout(Duration::from_secs(2), rx.recv())
            .await
            .expect("timed out mid-stream")
            .expect("audio broadcast closed");
        assert_eq!(
            pkt.seq,
            seq.wrapping_add(1),
            "seq gap: paced 50/s output must never lag the 256-slot broadcast ring"
        );
        seq = pkt.seq;
        assert!(!pkt.data.is_empty());
    }
    let elapsed = t0.elapsed();
    // The writer outruns the reader (the pipe is kept full), so only the
    // daemon's deadline ticks set the cadence: meaningfully faster than the
    // 500 ms nominal means the writer became the clock (pacing broken); the
    // slow bound is generous for a loaded box.
    assert!(
        elapsed >= Duration::from_millis(400),
        "{N} packets in {elapsed:?}: faster than the 20 ms tick — pacing broken"
    );
    assert!(
        elapsed <= Duration::from_millis(1500),
        "{N} packets in {elapsed:?}: cadence collapsed"
    );

    let _ = std::fs::remove_file(&path);
    drop(writer); // detached: its blocked write ends with the process
}
