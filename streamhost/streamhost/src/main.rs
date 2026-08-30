// streamhost — scratch-built per-VM streaming host in Rust.
//
// Pipeline (one process per gallery station):
//   QEMU -display dbus,p2p=on  --(zbus p2p)-->  capture (shm scanout + v1 fallback)
//     -> encode (x264 zerolatency Annex-B)  -> transport (WebTransport/QUIC)
//   QEMU -audiodev dbus         --(same p2p)-->  audio (Opus low-latency)  ---^
//   browser input  --(datagrams + reliable stream)-->  input -> QEMU dbus Mouse/Kbd/Touch
//
// Config is per-station (see config.rs): QMP socket, UDP port, audio on/off, input
// backend, cert rotation, signaling.json output. The prototype invocation
// `streamhost <qmp.sock> --port N --fps N --hash-file P` still works.

mod abr;
mod audio;
mod capture;
mod cert;
mod clock;
mod config;
mod encode;
mod idle;
mod input;
mod input_telemetry;
mod key_quirks;
mod mame_input;
mod mame_sock;
mod mga_ctl;
mod ptr_grid;
mod ptr_reckon;
mod realtime_input;
mod rel_bridge;
mod session_ticket;
mod signaling;
mod transport;
mod vice_keymap;
mod vice_sock;
mod warpd;
mod webrtc_bridge;
mod x11_input;
mod x11_keys;

use std::sync::Arc;

use anyhow::Result;

#[tokio::main]
async fn main() -> Result<()> {
    match std::env::args().nth(1).as_deref() {
        Some("-h" | "--help") => {
            println!("streamhost {}\n\nUsage: streamhost [QMP_SOCKET] [OPTIONS]\n\nConfiguration is read from SH_* environment variables; legacy --port/--fps/--hash-file options are also supported.", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        Some("-V" | "--version") => {
            println!("streamhost {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        _ => {}
    }

    clock::init();
    let cfg = Arc::new(config::Config::from_args());
    eprintln!(
        "[streamhost] tile={} capture={} qmp={} x11={} udp/{} fps={} keyframe_ms={} input_backend={} audio={} audio_src={}",
        cfg.tile,
        cfg.capture_backend.as_str(),
        cfg.qmp_sock,
        cfg.x11_display,
        cfg.udp_port,
        cfg.fps,
        cfg.keyframe_ms,
        cfg.input_backend.as_str(),
        cfg.audio,
        cfg.audio_source.as_str()
    );
    // Diagnostic pointer-input telemetry (SH_INPUT_TELEMETRY; default off).
    // Installs the process-global singleton + (level >= 1) the 1 s summary task.
    input_telemetry::init(cfg.input_telemetry, &cfg.tile);

    let cap = match cfg.capture_backend {
        config::CaptureBackend::Qemu => capture::connect(&cfg.qmp_sock).await?,
        config::CaptureBackend::X11 => capture::connect_x11(&cfg.x11_display).await?,
        config::CaptureBackend::Shm => {
            capture::connect_shm(&cfg.shm_path, cfg.shm_poll_ms, cfg.shm_damage).await?
        }
    };
    {
        let s = cap.state.lock().unwrap();
        eprintln!(
            "[streamhost] first frame {}x{} (shm={})",
            s.width.max(s.fb_w),
            s.height.max(s.fb_h),
            !s.map_ptr.is_null()
        );
    }

    // Guest audio (opt-in per station), from one of two sources. `dbus` rides the
    // QEMU p2p connection — only the QEMU capture backend has one. `fifo` reads
    // the named pipe MAME's SDL disk audio driver writes; the shm-capture IRIX
    // station has NO main_conn, so that arm must never gate on it.
    let audio = if !cfg.audio {
        None
    } else {
        match cfg.audio_source {
            config::AudioSource::Dbus => match cap.main_conn.clone() {
                Some(conn) => match audio::start(conn, cfg.audio_bitrate).await {
                    Ok(a) => {
                        eprintln!(
                            "[streamhost] audio: registered dbus AudioOutListener (Opus @{}k)",
                            cfg.audio_bitrate / 1000
                        );
                        Some(a)
                    }
                    Err(e) => {
                        eprintln!("[streamhost] audio: DISABLED (no dbus audiodev?): {e:?}");
                        None
                    }
                },
                // SH_AUDIO=on on an x11/shm-capture station still defaulting to
                // dbus: nothing to register against — say so instead of
                // silently running video-only.
                None => {
                    eprintln!(
                        "[streamhost] audio: DISABLED (capture backend has no dbus connection; SH_AUDIO_SOURCE=fifo is the non-QEMU path)"
                    );
                    None
                }
            },
            config::AudioSource::Fifo => match audio::start_fifo(
                cfg.audio_fifo.clone(),
                cfg.audio_bitrate,
                cfg.audio_silence_thresh,
            ) {
                Ok(a) => {
                    eprintln!(
                        "[streamhost] audio: paced fifo reader on {} (Opus @{}k, silence thresh {})",
                        cfg.audio_fifo,
                        cfg.audio_bitrate / 1000,
                        cfg.audio_silence_thresh
                    );
                    Some(a)
                }
                Err(e) => {
                    eprintln!("[streamhost] audio: DISABLED (fifo reader failed to spawn): {e:?}");
                    None
                }
            },
        }
    };

    let enc_params = encode::EncodeParams {
        preset: cfg.preset.clone(),
        profile: cfg.profile.clone(),
        tune: cfg.tune.clone(),
        crf: cfg.crf,
        maxrate_kbps: cfg.maxrate_kbps,
        bufsize_ratio: cfg.bufsize_ratio,
        abr_floor_height: cfg.abr_floor_height,
        threads: cfg.enc_threads,
        enc_nice: cfg.enc_nice,
        damage_conv: cfg.damage_conv,
        damage_full_pct: cfg.damage_full_pct,
        abr_fps_ladder: cfg.abr_fps_ladder,
        abr_res_ladder: cfg.abr_res_ladder,
        abr_idr_backoff: cfg.abr_idr_backoff,
    };
    eprintln!(
        "[streamhost] encoder cfg preset={} profile={} tune={} crf={} maxrate_kbps={} bufsize_ratio={} abr={} enc_threads={} enc_nice={} damage_conv={} damage_full_pct={}",
        cfg.preset, cfg.profile, cfg.tune, cfg.crf, cfg.maxrate_kbps, cfg.bufsize_ratio, cfg.abr, cfg.enc_threads,
        cfg.enc_nice.map(|n| n.to_string()).unwrap_or_else(|| "off".into()),
        cfg.damage_conv, cfg.damage_full_pct
    );
    let enc = encode::spawn(cap.clone(), cfg.fps, cfg.keyframe_ms, enc_params);
    eprintln!("[streamhost] encoder up");

    // One idle lease counter is shared by BOTH platform transports. A WebRTC
    // viewer must wake/hold the guest exactly like a WebTransport viewer; the
    // generic bridge sends S/E lease commands as peers connect and leave.
    // A QEMU station freezes its vCPUs over QMP. The x11/shm (emulator) stations have
    // no QMP socket, so they pause the emulator process itself — but only when
    // the station names its pidfile, because signalling is not something to infer.
    let freezer = if cfg.capture_backend.is_qemu() {
        Some(idle::Freezer::Qmp {
            sock: cfg.qmp_sock.clone(),
        })
    } else {
        cfg.idle_pause_pidfile
            .clone()
            .map(|pidfile| idle::Freezer::Signal {
                pidfile,
                proc_match: cfg.idle_pause_proc_match.clone(),
            })
    };
    // IdlePauser::new logs the ON line (it names the mechanism it resolved).
    let pauser = freezer.and_then(|f| {
        idle::IdlePauser::new(
            f,
            cfg.idle_pause_secs,
            cfg.idle_pause_warmup_secs,
            &cfg.tile,
        )
    });
    if pauser.is_none() {
        eprintln!(
            "[streamhost] idle auto-pause OFF (SH_IDLE_PAUSE_SECS={}{})",
            cfg.idle_pause_secs,
            if cfg.capture_backend.is_qemu() {
                ""
            } else {
                ", non-QEMU tile with no SH_IDLE_PAUSE_PIDFILE"
            }
        );
    }

    // Platform WebRTC egress feed. Every instance of the shared streamhost
    // binary registers its ordinary station id with the ONE generic bridge. There
    // is no per-station WebRTC environment, port, process, or opt-in. If the bridge
    // is absent this reconnect loop is inert apart from a rate-limited log; the
    // WebTransport path below remains independent and authoritative.
    webrtc_bridge::spawn(cfg.tile.clone(), enc.clone(), audio.clone(), pauser.clone());

    if let Some(p) = cfg.local_http_port {
        signaling::spawn_http(cfg.clone(), p);
    }
    // Relative-pointer stations: SIGUSR2 = "guest state replaced" (reset-tile.sh
    // sends it after a loadvm) -> the bridge re-homes on the next motion.
    if cfg.input_backend == config::InputBackend::DbusRel && cfg.rel_home_on.reset {
        rel_bridge::spawn_reset_signal();
    }

    transport::serve(cfg.clone(), cap, enc, audio, pauser).await?;
    Ok(())
}
