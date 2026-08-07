// Guest AUDIO capture -> Opus (low-latency) -> broadcast for the transport.
//
// This is the biggest addition over the video+input prototype. It reuses the
// EXACT same p2p D-Bus mechanism the video listener uses: QEMU, launched with
// `-audiodev dbus,id=snd0 -device <sound-dev>,audiodev=snd0`, exports an
// `org.qemu.Display1.Audio` object on the same peer connection we already hold
// (Capture.main_conn). We:
//   1. socketpair(); export our AudioOutListener on one end (p2p server conn);
//   2. call Audio.RegisterOutListener(fd) passing the other end;
//   3. QEMU calls Init(format...) then Write(pcm) repeatedly with guest PCM;
//   4. we convert to 48 kHz / stereo / i16, slice into 20 ms frames, Opus-encode
//      (Application::LowDelay), stamp each packet with clock::now_us() (shared
//      with video capture ts for A/V sync), and broadcast it.
//
// No host audio stack (PulseAudio/PipeWire) is required — PCM comes straight out
// of QEMU over D-Bus. If the guest/QEMU has no dbus audiodev, RegisterOutListener
// errors and main.rs simply runs video-only.
//
// A second PCM source exists for tiles with no QEMU at all: `start_fifo` (see
// its section below) reads raw s16le stereo 48 kHz out of a named pipe written
// by MAME's SDL "disk" audio driver and feeds the SAME encode_loop, so the wire
// format (48 k stereo Opus) is identical on both paths.
//
// D-Bus interface (from dbus-display1.xml, QEMU 11):
//   org.qemu.Display1.Audio.RegisterOutListener(h fd); prop NSamples u
//   client-side org.qemu.Display1.AudioOutListener:
//     Init(t id, y bits, b is_signed, b is_float, u freq, y nchannels,
//          u bytes_per_frame, u bytes_per_second, b be)
//     Fini(t id); SetEnabled(t id, b enabled); SetVolume(t id, b mute, ay volume)
//     Write(t id, ay data)

use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, RawFd};
use std::os::unix::net::UnixStream as StdUnixStream;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nix::sys::socket::{socketpair, AddressFamily, SockFlag, SockType};
use tokio::sync::{broadcast, mpsc};
use zbus::zvariant::Fd;

use crate::clock;

pub const AUDIO_OBJ: &str = "/org/qemu/Display1/Audio";
pub const I_AUDIO: &str = "org.qemu.Display1.Audio";
pub const AUDIO_OUT_LISTENER_PATH: &str = "/org/qemu/Display1/AudioOutListener";

const OUT_RATE: u32 = 48_000; // Opus clock
const FRAME_MS: usize = 20; // 20 ms per Opus packet -> 960 samples/ch @48k
const SAMPLES_PER_CH: usize = OUT_RATE as usize * FRAME_MS / 1000; // 960

#[derive(Clone)]
pub struct AudioPacket {
    pub data: Arc<Vec<u8>>,
    pub seq: u32,
    pub ts_us: u32,
}

#[derive(Clone)]
pub struct AudioOut {
    // The wire format is fixed: 48 kHz stereo Opus (OUT_RATE); the client hardcodes it.
    pub tx: broadcast::Sender<AudioPacket>,
}

#[derive(Clone, Copy, Debug)]
struct Fmt {
    bits: u8,
    is_signed: bool,
    is_float: bool,
    freq: u32,
    channels: u8,
}

#[derive(Clone)]
struct OutListener {
    fmt: Arc<Mutex<Option<Fmt>>>,
    pcm_tx: mpsc::UnboundedSender<Vec<u8>>,
}

#[zbus::interface(name = "org.qemu.Display1.AudioOutListener")]
impl OutListener {
    #[allow(clippy::too_many_arguments)]
    async fn init(
        &self,
        _id: u64,
        bits: u8,
        is_signed: bool,
        is_float: bool,
        freq: u32,
        nchannels: u8,
        _bytes_per_frame: u32,
        _bytes_per_second: u32,
        _be: bool,
    ) {
        let f = Fmt {
            bits,
            is_signed,
            is_float,
            freq,
            channels: nchannels,
        };
        *self.fmt.lock().unwrap() = Some(f);
        eprintln!(
            "[audio] Init bits={bits} signed={is_signed} float={is_float} freq={freq} ch={nchannels}"
        );
    }

    async fn fini(&self, _id: u64) {
        eprintln!("[audio] Fini");
    }

    // QEMU signals playback start/stop here; we don't need to track it — Write()
    // simply stops arriving while the guest isn't playing. (Method must exist to
    // satisfy the dbus interface.)
    async fn set_enabled(&self, _id: u64, _enabled: bool) {}

    async fn set_volume(&self, _id: u64, _mute: bool, _volume: Vec<u8>) {}

    async fn write(&self, _id: u64, data: Vec<u8>) {
        if !data.is_empty() {
            let _ = self.pcm_tx.send(data);
        }
    }

    #[zbus(property)]
    async fn interfaces(&self) -> Vec<String> {
        vec![]
    }
}

async fn build_audio_server(fd: RawFd, listener: OutListener) -> zbus::Result<zbus::Connection> {
    let std_stream = unsafe { StdUnixStream::from_raw_fd(fd) };
    std_stream.set_nonblocking(true).unwrap();
    let tok = tokio::net::UnixStream::from_std(std_stream).unwrap();
    zbus::connection::Builder::unix_stream(tok)
        .p2p()
        .serve_at(AUDIO_OUT_LISTENER_PATH, listener)?
        .build()
        .await
}

/// Register an AudioOutListener on the existing QEMU p2p connection and start the
/// Opus encode loop. Returns a broadcast source of Opus packets.
pub async fn start(main_conn: zbus::Connection, bitrate: u32) -> anyhow::Result<AudioOut> {
    let (tx, _rx) = broadcast::channel::<AudioPacket>(256);
    let (pcm_tx, pcm_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let fmt = Arc::new(Mutex::new(None));
    let listener = OutListener {
        fmt: fmt.clone(),
        pcm_tx,
    };

    let (a, b) = socketpair(
        AddressFamily::Unix,
        SockType::Stream,
        None,
        SockFlag::empty(),
    )?;
    let a_fd = a.into_raw_fd();
    let server_task = tokio::spawn(async move { build_audio_server(a_fd, listener).await });
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    // If the guest/QEMU was launched without `-display dbus,...,audiodev=<id>` the
    // Audio object won't exist and this errors — abort the server task (no panic)
    // and let main.rs run video-only.
    if let Err(e) = main_conn
        .call_method(
            None::<&str>,
            AUDIO_OBJ,
            Some(I_AUDIO),
            "RegisterOutListener",
            &(Fd::from(&b),),
        )
        .await
    {
        server_task.abort();
        return Err(e.into());
    }
    let server_conn = server_task.await??;
    drop(b);

    let txc = tx.clone();
    tokio::spawn(async move {
        // hold server_conn for the whole session; if it drops QEMU stops pushing PCM
        let _hold = server_conn;
        if let Err(e) = encode_loop(fmt, pcm_rx, txc, bitrate).await {
            eprintln!("[audio] encode loop exited: {e:?}");
        }
    });

    Ok(AudioOut { tx })
}

// ---- FIFO PCM source (SH_AUDIO_SOURCE=fifo) ---------------------------------
//
// The shm-capture IRIX/MAME tile has no QEMU and no dbus audiodev, but MAME's
// SDL port has a "disk" audio driver that writes the mixed output as raw PCM to
// a path — pointed at a named pipe (`-sound sdl -audiodriver disk` +
// SDL_DISKAUDIOFILE=<tile>/audio.fifo, SDL_DISKAUDIODELAY=0), that PCM is live.
// Probed on the tile before this design was approved: the disk driver writes
// real PCM including the PROM boot chime, the golden savestate loads with the
// sound flags changed, and emulation survives reader stalls.
//
// THE DAEMON IS THE CLOCK. With SDL_DISKAUDIODELAY=0 the SDL audio thread
// writes with no pacing of its own, so this reader takes exactly one Opus
// frame — FIFO_TICK_BYTES (3840 B) of s16le stereo @48 k = 192,000 B/s — per
// 20 ms deadline tick, and pipe backpressure paces SDL's writer. The pipe is
// shrunk to 16 KiB (F_SETPIPE_SZ), which bounds standing latency at ~85 ms and
// is also the teardown story: a dead daemon lets the pipe fill for ~85 ms and
// then SDL's audio thread blocks on write() while emulation continues.

/// One tick = one Opus frame of s16le stereo: 960 samples x 2 ch x 2 B.
const FIFO_TICK_BYTES: usize = SAMPLES_PER_CH * 2 * 2; // 3840 B => 192,000 B/s
const FIFO_TICK: Duration = Duration::from_millis(FRAME_MS as u64);
/// F_SETPIPE_SZ bound: 16 KiB / 192,000 B/s ≈ 85 ms of standing latency.
const FIFO_PIPE_BYTES: libc::c_int = 16 * 1024;
/// Lateness beyond this is a producer stall (savevm/loadvm pause, MAME
/// restart), not a scheduling hiccup the ≤85 ms pipe could cover — resnap the
/// schedule instead of bursting a catch-up. See `advance_deadline`.
const FIFO_STALL: Duration = Duration::from_millis(250);
/// Consecutive ≤threshold ticks before the silence gate mutes: 500 ms.
const SILENCE_HOLD_TICKS: u32 = (500 / FRAME_MS) as u32; // 25
/// (Re)open retry cadence — mirrors the shm capture backend's producer wait.
const REOPEN_DELAY: Duration = Duration::from_millis(200);

/// The producer format is fixed by the launcher contract (the SDL disk driver
/// is opened at 48 kHz/2ch/s16), so there is no Init() handshake — Fmt is set
/// once and `encode_loop`'s conversion is an identity pass-through.
const FIFO_FMT: Fmt = Fmt {
    bits: 16,
    is_signed: true,
    is_float: false,
    freq: OUT_RATE,
    channels: 2,
};

/// Like `start`, but the PCM source is the named pipe described above. Never
/// touches D-Bus, so it is the one audio source that works on capture backends
/// with no `main_conn` (SH_CAPTURE=shm/x11). Reuses `encode_loop` verbatim:
/// transports and the SPA see exactly what the dbus path produces.
pub fn start_fifo(path: String, bitrate: u32, silence_thresh: u16) -> anyhow::Result<AudioOut> {
    let (tx, _rx) = broadcast::channel::<AudioPacket>(256);
    let (pcm_tx, pcm_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    std::thread::Builder::new()
        .name("audiofifo".into())
        .spawn(move || fifo_read_loop(&path, &pcm_tx, silence_thresh))?;
    let txc = tx.clone();
    let fmt = Arc::new(Mutex::new(Some(FIFO_FMT)));
    tokio::spawn(async move {
        if let Err(e) = encode_loop(fmt, pcm_rx, txc, bitrate).await {
            eprintln!("[audio] encode loop exited: {e:?}");
        }
    });
    Ok(AudioOut { tx })
}

/// Advance the pacing schedule after one tick's read completed at `now`.
/// Lateness up to `stall` keeps the original grid: those ticks run back-to-back
/// (no sleep) and drain what the pipe buffered, so a scheduling hiccup loses no
/// audio — the 16 KiB pipe holds at most ~85 ms, which such catch-up recovers.
/// Lateness beyond `stall` cannot have come from the pipe (it was empty and the
/// producer idle), so the schedule RESNAPS to `now`: burning down a seconds-old
/// grid would push packets far faster than 50/s (a burst the client cannot
/// place on its timeline) for audio that is stale anyway.
fn advance_deadline(
    deadline: Instant,
    now: Instant,
    tick: Duration,
    stall: Duration,
) -> (Instant, bool) {
    if now > deadline + stall {
        (now + tick, true)
    } else {
        (deadline + tick, false)
    }
}

/// Largest |sample| in an interleaved s16le buffer, as u16 because
/// |i16::MIN| = 32768 does not fit in i16 (`unsigned_abs` keeps it exact where
/// `abs()` would panic/wrap). An odd trailing byte cannot occur on tick-sized
/// reads and would be ignored.
fn peak_abs_s16le(buf: &[u8]) -> u16 {
    buf.chunks_exact(2)
        .map(|c| i16::from_le_bytes([c[0], c[1]]).unsigned_abs())
        .max()
        .unwrap_or(0)
}

/// Silence-gate hysteresis over 20 ms ticks. After `SILENCE_HOLD_TICKS`
/// consecutive ticks whose peak stays at or under the threshold the gate MUTES
/// — frames stop reaching the encoder, so no Opus packets go out, which the
/// client already treats exactly like the dbus path's guest-stopped-playing
/// packet gap. Any single louder tick unmutes instantly and is itself pushed,
/// so no audible onset is lost. The gate STARTS muted: a daemon (re)start
/// against an idle desktop must not ship 500 ms of pure-silence Opus.
struct SilenceGate {
    thresh: u16,
    silent_ticks: u32,
    muted: bool,
}

impl SilenceGate {
    fn new(thresh: u16) -> Self {
        Self {
            thresh,
            silent_ticks: SILENCE_HOLD_TICKS,
            muted: true,
        }
    }

    /// Feed one tick's peak; returns whether that frame should reach the encoder.
    fn observe(&mut self, peak: u16) -> bool {
        if peak > self.thresh {
            self.silent_ticks = 0;
            self.muted = false;
            return true;
        }
        self.silent_ticks = self.silent_ticks.saturating_add(1);
        if self.silent_ticks >= SILENCE_HOLD_TICKS {
            self.muted = true;
        }
        !self.muted
    }
}

/// Open the producer FIFO for one paced-read session. The non-blocking open
/// succeeds on a FIFO with or without a writer (the tile launcher holds a
/// persistent O_RDWR fd as reader-of-last-resort, but clone rigs may not); the
/// fd is switched back to blocking for the paced reads so an empty pipe parks
/// the thread instead of spinning it. Refuses a non-FIFO loudly — a regular
/// file at this path would replay stale bytes at 192 kB/s forever.
fn open_fifo(path: &str) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::{FileTypeExt, OpenOptionsExt};
    let f = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)?;
    if !f.metadata()?.file_type().is_fifo() {
        return Err(std::io::Error::other(format!("{path} is not a FIFO")));
    }
    let fd = f.as_raw_fd();
    // Bound the pipe at 16 KiB (~85 ms at 192 kB/s). The pipe IS the latency
    // budget: its standing occupancy is audio the viewer has not heard yet, and
    // its capacity is how long a dead daemon lets SDL write before blocking.
    // The kernel rounds to whole pages (16 KiB = 4 exact); shrinking needs no
    // privilege, and failure merely widens the bound to the 64 KiB default —
    // log and continue.
    if unsafe { libc::fcntl(fd, libc::F_SETPIPE_SZ, FIFO_PIPE_BYTES) } < 0 {
        eprintln!(
            "[audio] fifo F_SETPIPE_SZ({FIFO_PIPE_BYTES}) failed: {} (default pipe size stays)",
            std::io::Error::last_os_error()
        );
    }
    // Drain-stale gulp: anything buffered before this reader existed is stale
    // by definition (the launcher's O_RDWR holder keeps the pipe alive across
    // daemon restarts, PROM chime included) — junk it rather than play it late.
    let mut junk = [0u8; 4096];
    while unsafe { libc::read(fd, junk.as_mut_ptr() as *mut libc::c_void, junk.len()) } > 0 {}
    let fl = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    unsafe { libc::fcntl(fd, libc::F_SETFL, fl & !libc::O_NONBLOCK) };
    Ok(f)
}

/// Paced FIFO reader — the CLOCK of the fifo audio path (see the section
/// comment). Runs on a dedicated thread for the process lifetime; exits only
/// when the encode loop is gone (process shutdown).
fn fifo_read_loop(path: &str, pcm_tx: &mpsc::UnboundedSender<Vec<u8>>, silence_thresh: u16) {
    use std::io::Read;
    let mut gate = SilenceGate::new(silence_thresh);
    let mut announced_missing = false;
    loop {
        let mut f = match open_fifo(path) {
            Ok(f) => f,
            Err(e) => {
                // The launcher creates the fifo; it may legitimately race us
                // (exactly like the shm mapping). Retry forever — audio coming
                // up late is strictly better than a tile without audio.
                if !announced_missing {
                    eprintln!("[audio] fifo {path} not readable yet: {e} (retrying)");
                    announced_missing = true;
                }
                std::thread::sleep(REOPEN_DELAY);
                continue;
            }
        };
        announced_missing = false;
        eprintln!("[audio] fifo open: {path} (paced {FIFO_TICK_BYTES} B / {FRAME_MS} ms)");
        let mut buf = vec![0u8; FIFO_TICK_BYTES];
        let mut deadline = Instant::now() + FIFO_TICK;
        'session: loop {
            let now = Instant::now();
            if deadline > now {
                std::thread::sleep(deadline - now);
            }
            let mut got = 0;
            while got < FIFO_TICK_BYTES {
                match f.read(&mut buf[got..]) {
                    // EOF = every writer closed. With the launcher's persistent
                    // O_RDWR holder this never fires (a dead MAME just leaves
                    // the pipe empty and read() parked); without one (clone
                    // rigs) we reopen after a beat. A partial tick at the
                    // boundary is <20 ms of teardown audio — dropped, not
                    // padded.
                    Ok(0) => break 'session,
                    Ok(n) => got += n,
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(e) => {
                        eprintln!("[audio] fifo read error: {e} (reopening)");
                        break 'session;
                    }
                }
            }
            let (next, resnapped) =
                advance_deadline(deadline, Instant::now(), FIFO_TICK, FIFO_STALL);
            deadline = next;
            if resnapped {
                eprintln!(
                    "[audio] fifo stalled >{} ms; schedule resnapped (no catch-up burst)",
                    FIFO_STALL.as_millis()
                );
            }
            if gate.observe(peak_abs_s16le(&buf)) && pcm_tx.send(buf.clone()).is_err() {
                return; // encode loop gone — the process is going down
            }
        }
        // A fifo with no writer EOFs instantly on a blocking read after a
        // non-blocking open; don't turn that into a hot reopen loop.
        std::thread::sleep(REOPEN_DELAY);
    }
}

/// Convert one QEMU PCM buffer into interleaved-stereo i16 @ OUT_RATE and append
/// to `pending`. Handles s16/f32/s8/u8, mono->stereo upmix, and naive linear
/// resampling to 48 kHz when the guest rate differs (rare — we ask QEMU for 48k).
fn append_converted(pending: &mut Vec<i16>, data: &[u8], f: Fmt) {
    let ch = f.channels.max(1) as usize;
    // 1. decode to f32 per-sample interleaved at source rate
    let mut src: Vec<f32> = Vec::new();
    if f.is_float && f.bits == 32 {
        for c in data.chunks_exact(4) {
            src.push(f32::from_le_bytes([c[0], c[1], c[2], c[3]]));
        }
    } else if f.bits == 16 {
        for c in data.chunks_exact(2) {
            let v = i16::from_le_bytes([c[0], c[1]]);
            src.push(v as f32 / 32768.0);
        }
    } else if f.bits == 8 {
        for &c in data {
            let v = if f.is_signed {
                c as i8 as f32
            } else {
                c as f32 - 128.0
            };
            src.push(v / 128.0);
        }
    } else if f.bits == 32 {
        for c in data.chunks_exact(4) {
            let v = i32::from_le_bytes([c[0], c[1], c[2], c[3]]);
            src.push(v as f32 / 2_147_483_648.0);
        }
    } else {
        return;
    }

    // 2. frames (per-channel groups) at source rate
    let src_frames = src.len() / ch;
    if src_frames == 0 {
        return;
    }
    // fetch L/R from a source frame (upmix mono, downmix >2 to first two)
    let lr = |frame: usize| -> (f32, f32) {
        let base = frame * ch;
        if ch == 1 {
            (src[base], src[base])
        } else {
            (src[base], src[base + 1])
        }
    };

    let push = |pending: &mut Vec<i16>, l: f32, r: f32| {
        let cv = |x: f32| (x.clamp(-1.0, 1.0) * 32767.0) as i16;
        pending.push(cv(l));
        pending.push(cv(r));
    };

    if f.freq == OUT_RATE {
        for i in 0..src_frames {
            let (l, r) = lr(i);
            push(pending, l, r);
        }
    } else {
        // linear resample to OUT_RATE
        let out_frames = (src_frames as u64 * OUT_RATE as u64 / f.freq as u64) as usize;
        for o in 0..out_frames {
            let pos = o as f64 * f.freq as f64 / OUT_RATE as f64;
            let i0 = pos.floor() as usize;
            let frac = (pos - i0 as f64) as f32;
            let i1 = (i0 + 1).min(src_frames - 1);
            let (l0, r0) = lr(i0.min(src_frames - 1));
            let (l1, r1) = lr(i1);
            push(pending, l0 + (l1 - l0) * frac, r0 + (r1 - r0) * frac);
        }
    }
}

/// Like `start`, but forwards RAW interleaved-stereo s16le PCM at OUT_RATE (48 kHz)
/// instead of Opus-encoding. Used by the `bootrec-tap` boot-recorder sidecar, which
/// muxes raw PCM straight into a single-pass ffmpeg encode. Registers the SAME
/// AudioOutListener over the SAME p2p connection (no duplicated SCM_RIGHTS/register
/// logic) and runs `append_converted` (guest format -> 48 k stereo i16) exactly like
/// the Opus path. Returns a receiver of little-endian s16 byte buffers, or an error
/// (same condition as `start`) when the guest/QEMU has no dbus audiodev — in which
/// case the caller emits silence so downstream ffmpeg still gets a writer.
#[allow(dead_code)] // reached only via the lib crate (src/bin/bootrec-tap.rs); the daemon bin never calls it
pub async fn start_raw(
    main_conn: zbus::Connection,
) -> anyhow::Result<mpsc::UnboundedReceiver<Vec<u8>>> {
    let (pcm_tx, mut pcm_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let fmt = Arc::new(Mutex::new(None));
    let listener = OutListener {
        fmt: fmt.clone(),
        pcm_tx,
    };

    let (a, b) = socketpair(
        AddressFamily::Unix,
        SockType::Stream,
        None,
        SockFlag::empty(),
    )?;
    let a_fd = a.into_raw_fd();
    let server_task = tokio::spawn(async move { build_audio_server(a_fd, listener).await });
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    if let Err(e) = main_conn
        .call_method(
            None::<&str>,
            AUDIO_OBJ,
            Some(I_AUDIO),
            "RegisterOutListener",
            &(Fd::from(&b),),
        )
        .await
    {
        server_task.abort();
        return Err(e.into());
    }
    let server_conn = server_task.await??;
    drop(b);

    let (out_tx, out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    tokio::spawn(async move {
        let _hold = server_conn; // hold the p2p conn for the session, else QEMU stops PCM
        while let Some(data) = pcm_rx.recv().await {
            let f = { *fmt.lock().unwrap() };
            let Some(f) = f else { continue };
            let mut pending: Vec<i16> = Vec::new();
            append_converted(&mut pending, &data, f);
            if pending.is_empty() {
                continue;
            }
            let mut bytes = Vec::with_capacity(pending.len() * 2);
            for s in pending {
                bytes.extend_from_slice(&s.to_le_bytes());
            }
            if out_tx.send(bytes).is_err() {
                break; // receiver (bootrec-tap) gone
            }
        }
    });

    Ok(out_rx)
}

async fn encode_loop(
    fmt: Arc<Mutex<Option<Fmt>>>,
    mut pcm_rx: mpsc::UnboundedReceiver<Vec<u8>>,
    tx: broadcast::Sender<AudioPacket>,
    bitrate: u32,
) -> anyhow::Result<()> {
    let mut enc = opus::Encoder::new(
        OUT_RATE,
        opus::Channels::Stereo,
        opus::Application::LowDelay,
    )?;
    let _ = enc.set_bitrate(opus::Bitrate::Bits(bitrate as i32));
    let _ = enc.set_inband_fec(false);

    let mut pending: Vec<i16> = Vec::with_capacity(SAMPLES_PER_CH * 2 * 4);
    let frame_len = SAMPLES_PER_CH * 2; // interleaved stereo i16 per 20 ms
    let mut out = vec![0u8; 4000];
    let mut seq: u32 = 0;

    while let Some(data) = pcm_rx.recv().await {
        let f = { *fmt.lock().unwrap() };
        let Some(f) = f else { continue };
        append_converted(&mut pending, &data, f);

        while pending.len() >= frame_len {
            let frame: Vec<i16> = pending.drain(..frame_len).collect();
            match enc.encode(&frame, &mut out) {
                Ok(n) if n > 0 => {
                    let pkt = AudioPacket {
                        data: Arc::new(out[..n].to_vec()),
                        seq,
                        ts_us: clock::now_us(),
                    };
                    seq = seq.wrapping_add(1);
                    let _ = tx.send(pkt);
                }
                Ok(_) => {}
                Err(e) => eprintln!("[audio] opus encode err: {e}"),
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        advance_deadline, peak_abs_s16le, SilenceGate, FIFO_STALL, FIFO_TICK, FIFO_TICK_BYTES,
        SILENCE_HOLD_TICKS,
    };
    use std::time::{Duration, Instant};

    // 48 kHz x 2 ch x 2 B x 20 ms — the whole pacing design hangs off this.
    #[test]
    fn one_tick_is_3840_bytes() {
        assert_eq!(FIFO_TICK_BYTES, 3840);
        assert_eq!(FIFO_TICK, Duration::from_millis(20));
    }

    #[test]
    fn deadline_keeps_grid_within_stall_and_resnaps_beyond() {
        let t0 = Instant::now();
        // On time: the grid simply advances.
        let (next, snap) = advance_deadline(t0, t0, FIFO_TICK, FIFO_STALL);
        assert_eq!(next, t0 + FIFO_TICK);
        assert!(!snap);
        // Late but within the stall bound: grid preserved, so the following
        // ticks run back-to-back and drain the pipe backlog (catch-up).
        let (next, snap) = advance_deadline(t0, t0 + FIFO_STALL, FIFO_TICK, FIFO_STALL);
        assert_eq!(next, t0 + FIFO_TICK);
        assert!(!snap);
        // Beyond the stall bound: resnap to now — no burst catch-up.
        let late = t0 + FIFO_STALL + Duration::from_millis(1);
        let (next, snap) = advance_deadline(t0, late, FIFO_TICK, FIFO_STALL);
        assert_eq!(next, late + FIFO_TICK);
        assert!(snap);
    }

    #[test]
    fn silence_gate_mutes_after_500ms_and_unmutes_instantly() {
        let mut g = SilenceGate::new(4);
        assert!(g.observe(100)); // loud opens the gate
        for i in 0..SILENCE_HOLD_TICKS - 1 {
            assert!(g.observe(4), "tick {i}: <=thresh but hold not reached");
        }
        assert!(!g.observe(0)); // 25th consecutive silent tick (500 ms) mutes
        assert!(!g.observe(3)); // stays muted through further silence
        assert!(g.observe(5)); // one louder frame unmutes instantly AND is pushed
        assert!(g.observe(0)); // silent run restarts from zero
    }

    #[test]
    fn silence_gate_starts_muted() {
        let mut g = SilenceGate::new(4);
        assert!(!g.observe(0)); // no 500 ms of silence packets at daemon start
        assert!(g.observe(5)); // first real sound passes immediately
    }

    #[test]
    fn peak_handles_sign_and_i16_min() {
        assert_eq!(peak_abs_s16le(&[]), 0);
        assert_eq!(peak_abs_s16le(&5i16.to_le_bytes()), 5);
        assert_eq!(peak_abs_s16le(&[1, 0, 0xfc, 0xff]), 4); // [1, -4] -> 4
        assert_eq!(peak_abs_s16le(&[0, 0, 0x00, 0x80]), 32768); // i16::MIN exact
    }
}
