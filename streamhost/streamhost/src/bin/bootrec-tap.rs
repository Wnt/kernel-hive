// bootrec-tap — the one box-only companion for scripts/coldboot/record-boot.sh.
//
// It is the streamhost daemon's QEMU dbus display + audio tap, MINUS the encoder:
// it reuses `streamhost::capture::connect()` (BGRA scanout over the p2p D-Bus
// listener) and `streamhost::audio::start_raw()` (s16le PCM over the same p2p
// AudioOutListener), and instead of libx264/Opus it writes RAW frames to two fifos
// that record-boot.sh's single-pass ffmpeg muxes into boot.mp4.
//
//   SH_DBUS_TAP contract (record-boot.sh):
//     bootrec-tap <qmp.sock> <video.fifo> <audio.fifo|""> <WxH> <fps> <arate> <ach>
//
//   video: every scanout is letterbox/scaled to a CONSTANT <WxH> BGRA canvas and
//          written to <video.fifo> PACED to <fps> (the last frame is duplicated
//          between damage). Constant size + rate is what lets the downstream
//          `ffmpeg -f rawvideo` avoid a mid-boot SPS/resolution change (spec §2.3).
//   audio: s16le interleaved-stereo PCM at <arate>/<ach> to <audio.fifo>, paced in
//          real time. Real guest PCM is muxed when present; gaps are padded with
//          silence so the audio stream stays as long as the video (no -shortest
//          truncation) and ffmpeg NEVER blocks on a missing writer — the fifo is
//          opened even when the guest has an audiodev but produces no sound.
//
// Ordering note: ffmpeg opens its inputs in order (video input 0, then audio input
// 1). Opening a fifo for write blocks until the reader appears, so we open the
// VIDEO fifo first, then the AUDIO fifo — matching ffmpeg — to avoid a deadlock.
//
// Exit: clean on SIGTERM/SIGINT (record-boot.sh kills the tap), or when a fifo write
// returns EPIPE (ffmpeg gone). Dropping the files closes the write ends => ffmpeg EOF.

use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use streamhost::{audio, capture, clock};

fn parse_wxh(s: &str) -> Option<(u32, u32)> {
    let (w, h) = s.split_once(['x', 'X'])?;
    Some((w.trim().parse().ok()?, h.trim().parse().ok()?))
}

/// Nearest-neighbour letterbox of a src BGRA frame (sw x sh) into a constant BGRA
/// canvas (cw x ch), preserving aspect and centring on opaque black. Exact-size
/// frames are a straight memcpy (the common case: canvas == live scanout).
fn letterbox(src: &[u8], sw: u32, sh: u32, cw: u32, ch: u32, out: &mut [u8]) {
    // opaque black background (A=255 so `format=yuv420p` sees solid black)
    for px in out.chunks_exact_mut(4) {
        px[0] = 0;
        px[1] = 0;
        px[2] = 0;
        px[3] = 255;
    }
    if sw == 0 || sh == 0 {
        return;
    }
    let need = (cw as usize) * (ch as usize) * 4;
    if sw == cw && sh == ch && src.len() >= need {
        out[..need].copy_from_slice(&src[..need]);
        return;
    }
    let scale = (cw as f64 / sw as f64).min(ch as f64 / sh as f64);
    let dw = ((sw as f64 * scale).round() as u32).clamp(1, cw) as usize;
    let dh = ((sh as f64 * scale).round() as u32).clamp(1, ch) as usize;
    let ox = (cw as usize - dw) / 2;
    let oy = (ch as usize - dh) / 2;
    let (sw_u, sh_u, cw_u) = (sw as usize, sh as usize, cw as usize);
    // Precompute source column indices ONCE (O(dw)); the inner loop is then pure
    // index+copy. Turns per-pixel f64 division into ~dw+dh divisions per frame.
    let xmap: Vec<usize> = (0..dw)
        .map(|dx| (((dx as f64 + 0.5) / scale) as usize).min(sw_u - 1))
        .collect();
    for dy in 0..dh {
        let sy = (((dy as f64 + 0.5) / scale) as usize).min(sh_u - 1);
        let srow = sy * sw_u * 4;
        let drow = ((oy + dy) * cw_u + ox) * 4;
        for (dx, &sx) in xmap.iter().enumerate() {
            let si = srow + sx * 4;
            let di = drow + dx * 4;
            if si + 4 <= src.len() && di + 4 <= out.len() {
                out[di..di + 4].copy_from_slice(&src[si..si + 4]);
            }
        }
    }
}

/// Block until the fifo has a reader, then return the write handle. Errors surface
/// (bad path) rather than hang forever.
fn open_fifo_write(path: &str) -> std::io::Result<std::fs::File> {
    OpenOptions::new().write(true).open(path)
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> anyhow::Result<()> {
    clock::init();
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 8 {
        eprintln!(
            "usage: bootrec-tap <qmp.sock> <video.fifo> <audio.fifo|\"\"> <WxH> <fps> <arate> <ach>"
        );
        std::process::exit(2);
    }
    let qmp = a[1].clone();
    let vfifo = a[2].clone();
    let afifo = a[3].clone(); // "" => no audio
    let (cw, ch) = parse_wxh(&a[4]).unwrap_or_else(|| {
        eprintln!("[bootrec-tap] bad WxH '{}'", a[4]);
        std::process::exit(2);
    });
    let fps: u32 = a[5].parse().unwrap_or(30).max(1);
    let arate: u32 = a[6].parse().unwrap_or(48_000).max(8_000);
    let ach: u32 = a[7].parse().unwrap_or(2).clamp(1, 8);
    let want_audio = !afifo.is_empty();

    eprintln!(
        "[bootrec-tap] qmp={qmp} canvas={cw}x{ch}@{fps}fps audio={} arate={arate} ach={ach}",
        if want_audio { afifo.as_str() } else { "off" }
    );

    // 1. wire up the dbus display capture (same path the daemon uses).
    let cap = capture::connect(&qmp).await?;
    eprintln!("[bootrec-tap] capture connected");

    // 2. register the audio tap (raw s16le). If the guest has no dbus audiodev this
    //    errors and we fall through to silence — but we STILL open the audio fifo.
    let pcm_buf: Arc<Mutex<VecDeque<u8>>> = Arc::new(Mutex::new(VecDeque::new()));
    let real_pcm_bytes = Arc::new(AtomicU64::new(0));
    // bootrec-tap always uses the QEMU capture backend, so main_conn is Some.
    if let (true, Some(conn)) = (want_audio, cap.main_conn.clone()) {
        match audio::start_raw(conn).await {
            Ok(mut rx) => {
                eprintln!("[bootrec-tap] audio tap registered (s16le @48k stereo)");
                let buf = pcm_buf.clone();
                let cnt = real_pcm_bytes.clone();
                tokio::spawn(async move {
                    while let Some(chunk) = rx.recv().await {
                        cnt.fetch_add(chunk.len() as u64, Ordering::Relaxed);
                        buf.lock().unwrap().extend(chunk);
                    }
                });
            }
            Err(e) => {
                eprintln!("[bootrec-tap] no dbus audio ({e:#}) — emitting silence to the fifo");
            }
        }
    }

    let stop = Arc::new(AtomicBool::new(false));

    // 3. Open fifos + start pacers in ffmpeg's input order. CRITICAL ordering: ffmpeg
    //    opens input 0 (video) and READS frames to probe it BEFORE it opens input 1
    //    (audio). So we must open the VIDEO fifo and start the video pacer (frames
    //    flowing) FIRST; only then does ffmpeg proceed to open the audio-read end,
    //    which unblocks our blocking audio-fifo open. Opening audio before frames flow
    //    deadlocks (tap waits for ffmpeg to open audio-read; ffmpeg waits for video
    //    frames that the not-yet-started pacer would produce).
    let vf = tokio::task::spawn_blocking({
        let p = vfifo.clone();
        move || open_fifo_write(&p)
    })
    .await??;
    eprintln!("[bootrec-tap] video fifo open");

    // 4. VIDEO pacer (std thread; blocking writes). Snapshot -> letterbox -> canvas,
    //    fps-paced in real time; duplicate the last canvas between damage.
    let vid = std::thread::spawn({
        let state = cap.state.clone();
        let stop = stop.clone();
        let mut vf = vf;
        move || {
            let need = (cw as usize) * (ch as usize) * 4;
            let mut canvas = vec![0u8; need];
            for px in canvas.chunks_exact_mut(4) {
                px[3] = 255;
            }
            let frame = Duration::from_nanos(1_000_000_000u64 / fps as u64);
            let mut next = Instant::now();
            let mut frames: u64 = 0;
            while !stop.load(Ordering::Relaxed) {
                let snap = {
                    let s = state.lock().unwrap();
                    s.snapshot_bgra()
                };
                if let Some((buf, w, h)) = snap {
                    letterbox(&buf, w, h, cw, ch, &mut canvas);
                }
                if vf.write_all(&canvas).is_err() {
                    eprintln!("[bootrec-tap] video fifo EPIPE — ffmpeg gone, stopping");
                    stop.store(true, Ordering::Relaxed);
                    break;
                }
                frames += 1;
                next += frame;
                let now = Instant::now();
                if next > now {
                    std::thread::sleep(next - now);
                } else {
                    next = now; // fell behind; don't spiral
                }
            }
            let _ = vf.flush();
            eprintln!("[bootrec-tap] video pacer exit: {frames} frames");
        }
    });

    // 4b. Now that video frames are flowing, ffmpeg will finish probing input 0 and
    //     open the audio-read end — so this blocking open returns. (No card => the
    //     fifo still opens and the pacer below writes silence; on exit we close it so
    //     ffmpeg gets EOF and never blocks on a missing writer.)
    let af = if want_audio {
        let f = tokio::task::spawn_blocking({
            let p = afifo.clone();
            move || open_fifo_write(&p)
        })
        .await??;
        eprintln!("[bootrec-tap] audio fifo open");
        Some(f)
    } else {
        None
    };

    // 5. AUDIO pacer (std thread). Every 20 ms emit exactly arate/50 frames: real PCM
    //    from the buffer first, padded with silence. Guarantees a continuous s16le
    //    stream at least as long as the video (no -shortest truncation).
    let aud = af.map(|mut af| {
        let buf = pcm_buf.clone();
        let stop = stop.clone();
        std::thread::spawn(move || {
            let bytes_per_tick = (arate as usize / 50) * ach as usize * 2; // 20 ms, s16
            let tick = Duration::from_millis(20);
            let mut next = Instant::now();
            let mut chunk = vec![0u8; bytes_per_tick];
            while !stop.load(Ordering::Relaxed) {
                for b in chunk.iter_mut() {
                    *b = 0;
                }
                {
                    let mut q = buf.lock().unwrap();
                    let n = bytes_per_tick.min(q.len());
                    for slot in chunk.iter_mut().take(n) {
                        *slot = q.pop_front().unwrap();
                    }
                }
                if af.write_all(&chunk).is_err() {
                    eprintln!("[bootrec-tap] audio fifo EPIPE — stopping");
                    stop.store(true, Ordering::Relaxed);
                    break;
                }
                next += tick;
                let now = Instant::now();
                if next > now {
                    std::thread::sleep(next - now);
                } else {
                    next = now;
                }
            }
            let _ = af.flush();
            eprintln!("[bootrec-tap] audio pacer exit");
        })
    });

    // 6. run until SIGTERM/SIGINT (record-boot.sh kills us) or a fifo EPIPE.
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut term = signal(SignalKind::terminate())?;
        let mut intr = signal(SignalKind::interrupt())?;
        let stopc = stop.clone();
        let poll = tokio::spawn(async move {
            loop {
                if stopc.load(Ordering::Relaxed) {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        });
        tokio::select! {
            _ = term.recv() => eprintln!("[bootrec-tap] SIGTERM"),
            _ = intr.recv() => eprintln!("[bootrec-tap] SIGINT"),
            _ = poll => eprintln!("[bootrec-tap] pacer stopped (EPIPE)"),
        }
    }
    stop.store(true, Ordering::Relaxed);

    // 7. join pacers (closes the fifos => ffmpeg EOF), report audio verdict.
    let _ = vid.join();
    if let Some(h) = aud {
        let _ = h.join();
    }
    let real = real_pcm_bytes.load(Ordering::Relaxed);
    eprintln!(
        "[bootrec-tap] done. real guest PCM captured: {real} bytes ({})",
        if real > 0 { "HAD AUDIO" } else { "SILENT" }
    );
    Ok(())
}
