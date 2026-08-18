// Per-station runtime configuration for a single streamhost daemon.
//
// One streamhost process serves exactly ONE QEMU/station (one QMP socket, one UDP
// port). Config is read from CLI flags and/or environment (systemd/compose
// friendly). Positional arg 0 is still the QMP socket for prototype back-compat.
//
//   streamhost <QMP_SOCK> [flags]
//     --tile NAME              logical station id (used to derive default paths/logs)
//     --port N                 WebTransport/QUIC UDP port for this station
//     --fps N                  capture/encode fps cap (default 60, clamped >= 1)
//     --keyframe-ms N          wall-clock keyframe heartbeat while watched (default 2500)
//     --host-ip IP             host IPv4 advertised in signaling.json (default 192.0.2.10)
//     --advertise-host H       hostname the browser dials (default = host-ip)
//     --input-backend B       dbus-abs|dbus-rel|warpd|gallery-hid (default
//                              dbus-abs; SH_INPUT_BACKEND)
//     --pointer abs|rel|warpd  legacy spelling retained for config back-compat
//     --cursor-off-x N         abs-pointer origin calibration X (guest px, default 0)
//     --cursor-off-y N         abs-pointer origin calibration Y (guest px, default 0)
//     --cursor-scale F         abs-pointer scale before offset (default 1.0)
//     --warpd-addr H:P|PATH    in-guest pointer agent addr (default 127.0.0.1:7790)
//     --warpd-buttons W        agent|qemu — route buttons via the agent or the real
//                              QEMU device (default agent)
//     --warpd-wheel W          auto|agent|qemu — wheel route; auto follows buttons
//     --warpd-pace-ms N        min ms between agent writes (default 8, max 50)
//     --warpd-button-delay-ms N  hybrid-buttons race guard (default 0, max 250)
//     --audio on|off           capture+encode guest audio over dbus (default off)
//     --audio-bitrate N        opus bitrate bps (default 96000)
//     --legacy-kbd on|off      pre-1986 guest: send bare keypad scancodes for the
//                              dedicated cursor cluster (Win 1.x/2.x) (default off)
//     --hash-file PATH         bare base64 cert hash (prototype back-compat)
//     --signaling-json PATH    {host,udpPort,certHashB64,...} for the SERVE agent
//     --cert-rotate-days N     regenerate the self-signed cert every N days (default 10)
//     --local-http PORT        optional built-in plain-HTTP signaling (testing/A-B only)
//     --preset P               x264 preset ultrafast..veryslow (default ultrafast;
//                              SH_ENCODER_PRESET, legacy SH_PRESET fallback)
//     --profile P              h264 profile baseline|main|high (default high)
//     --tune T                 x264 tune (default zerolatency)
//     --crf N                  tier-0 quantiser: CQP at tier 0, CRF anchor on ABR
//                              tiers (default 10, clamped 10..40)
//     --maxrate N              tier-0 maxrate kbps; 0 = auto per-resolution (default 0)
//     --bufsize-ratio F        VBV bufsize = ratio*maxrate (default 1.0, 0.5..2.0)
//     --abr on|off             adaptive-bitrate controller (default on)
//     --abr-min-restart-ms N   dwell between tier changes (default 25000)
//     --abr-floor-height N     tier-3 resolution floor px (default 480, >= 240)
//     --enc-threads N          x264 sliced threads; 0 = auto min(4,cores) (default 0)
//     --enc-nice N|off         re-nice the encode thread; off = inherit (default off)
//     --damage-conv on|off     damage-bbox BGRA->I420 conversion (default on)
//     --damage-full-pct N      full-convert fallback at bbox area N% (default 35)
//     --idle-pause-secs N      auto-pause the GUEST (QMP stop) after N secs with zero
//                              sessions; resumed (cont) on the next connect (default 60, 0=off)
//
// Every flag has an SH_* env fallback (e.g. SH_PORT, SH_STATION, SH_AUDIO).

use std::net::{IpAddr, Ipv4Addr};

mod backends;
mod parse;

use backends::{
    parse_audio_source, parse_capture_backend, parse_input_backend, parse_key_remap,
    parse_silence_thresh,
};
pub use backends::{AudioSource, CaptureBackend, InputBackend};
use parse::{
    encoder_preset_env, env_or, normalize_encoder_preset, parse_cc, parse_enc_nice,
    parse_telemetry_level,
};

#[derive(Clone, Debug)]
pub struct Config {
    pub tile: String,
    pub qmp_sock: String,
    /// Frame source (SH_CAPTURE=qemu|x11; default qemu). `X11` reads
    /// `x11_display` instead of `qmp_sock` and disables the QEMU-only audio/idle
    /// paths — see `capture::connect_x11` and main.rs backend selection.
    pub capture_backend: CaptureBackend,
    /// X display for `CaptureBackend::X11` (SH_X11_DISPLAY, default ":0"). e.g.
    /// ":99" for the IRIX/MAME Xvfb. Ignored for the QEMU backend.
    pub x11_display: String,
    /// Command file the `x11test` input backend appends button/key commands to,
    /// read by the in-emulator MAME Lua agent (SH_X11_CMD_FILE, default
    /// /tmp/irix_cmd). MAME-SDL drops mouse buttons + keys unless the window is
    /// pointer-captured (impossible when it fills the whole Xvfb), so buttons/
    /// keys ride this file channel while pointer MOTION rides XTest relative
    /// injection. See docs/history/irix-tile-issue20-handoff.md.
    pub x11_cmd_file: String,
    /// Path of the file-backed framebuffer mapping the emulator publishes for
    /// `CaptureBackend::Shm` (SH_SHM_PATH, default /tmp/irix_fb.shm). Must match
    /// the producer's `IRIX_SHM_PATH`. Ignored by every other backend.
    pub shm_path: String,
    /// How often the shm capture thread checks the mapping's sequence word
    /// (SH_SHM_POLL_MS, default 2, clamp 1..100). There is no wakeup primitive in
    /// the mapping, so this bounds added capture latency; the poll itself is one
    /// atomic load.
    pub shm_poll_ms: u64,
    /// Recover a sub-frame damage bbox on the shm path by diffing each dirty
    /// frame against the previous one (SH_SHM_DAMAGE, default on). The producer's
    /// header only says whole-frame-or-nothing; without this every changed frame
    /// would force a full BGRA->I420 conversion. `0` is the A/B control.
    pub shm_damage: bool,
    pub udp_port: u16,
    pub host_ip: IpAddr,
    pub advertise_host: String,
    /// SH_SESSION_KEY — shared secret with the authenticated gateway. Unset (the
    /// LAN default) accepts every WebTransport session; set, each session must
    /// carry a live gateway-minted ticket. See session_ticket.rs.
    pub session_key: Option<Vec<u8>>,
    pub fps: u32,
    /// Wall-clock keyframe heartbeat (ms): while a client is connected, force a
    /// fresh IDR at least this often so late joiners never wait for a keyframe.
    pub keyframe_ms: u64,
    pub input_backend: InputBackend,
    /// QEMU gallery-hid chardev socket, used only for the explicit gallery-hid
    /// backend.
    pub ghid_socket: String,
    /// mamectl/1 control socket of the in-emulator ctlsock OSD module, used
    /// only by the explicit mamesock backend (SH_MAMECTL_SOCK; default
    /// `<tile-dir>/ctl.sock`, the module's MAME_CTL_SOCK launcher convention).
    pub mamectl_sock: String,
    pub vicectl_sock: String, // SH_VICECTL_SOCK; the vicesock backend's twin of the above
    /// Optional loopback-only Stage-D ingress. It accepts the existing `M x y`
    /// lines but feeds the process-wide production router rather than a backend.
    pub input_bench_addr: Option<String>,
    /// Per-guest absolute-pointer calibration (FIX 3). Applied in input::set_abs
    /// before injecting: guest = round(client * scale) + off. Identity (0/0/1.0)
    /// for every station except those with a measured tablet-origin offset (tinycore).
    pub cursor_off_x: i32,
    pub cursor_off_y: i32,
    pub cursor_scale: f64,
    /// dbus-rel bridge only: send relative motion ONLY in multiples of this many
    /// guest units, carrying the sub-quantum remainder in the model until more
    /// motion arrives (SH_REL_QUANTUM, 0 = off = every station today). For a
    /// guest whose tracking truncates per event (A/UX at "Very Slow": px =
    /// trunc(0.75 * units)) a quantum of 4 makes every send land exactly
    /// (4 -> 3 px), so the homing bridge stays 1:1 instead of drifting.
    pub rel_quantum: i32,
    /// dbus-rel bridge only: per-send chunk cap in guest units (SH_REL_MAX_STEP,
    /// default 256 = the historical PS/2 clamp window). Guests that ACCELERATE
    /// large single events (A/UX above ~32 units) need it lowered so no chunk
    /// ever crosses into the accelerated range.
    pub rel_max_step: i32,
    /// host:port of the in-guest warpd agent (via a QEMU hostfwd), used when
    /// input_backend == Warpd. e.g. 127.0.0.1:7790 forwarded to the guest's :7777.
    pub warpd_addr: String,
    /// Warpd stations only: route mouse BUTTONS through the real QEMU (PS/2) device
    /// instead of the in-guest agent (SH_WARPD_BUTTONS=qemu). Motion stays on the
    /// agent (absolute, drift-free). Real device buttons give true window-manager
    /// semantics (title-bar drags, menus, caption buttons) on guests whose native
    /// click-injection API is limited (e.g. Win3.11: mouse_event is a no-op under
    /// QEMU and PostMessage clicks don't drive non-client areas).
    pub warpd_buttons_qemu: bool,
    /// Warpd stations only: route wheel steps through the agent even when ordinary
    /// buttons use QEMU. OS/2 Warp needs this split: native PS/2 buttons provide
    /// PM capture, while the agent translates wheel 4/5 into WM_VSCROLL.
    pub warpd_wheel_agent: bool,
    /// Min ms between writes to the warpd agent (see warpd.rs pacing doc).
    pub warpd_pace_ms: u64,
    /// Hybrid-buttons race guard (see input.rs type2): hold a qemu-routed button
    /// this long after the most recent warpd motion so slow agent channels
    /// (Win3.x COM1 serial) apply the cursor position before the click lands.
    /// 0 = off (default; TCP agents like Solaris don't need it).
    pub warpd_button_delay_ms: u64,
    pub audio: bool,
    pub audio_bitrate: u32,
    /// PCM source when audio is on (SH_AUDIO_SOURCE, env-only): `dbus` (default;
    /// QEMU p2p AudioOutListener) or `fifo` (paced named-pipe reader — the only
    /// source that works on shm/x11-capture stations, which have no `main_conn`).
    /// See backends.rs and audio::start_fifo.
    pub audio_source: AudioSource,
    /// Named pipe the `fifo` source reads (SH_AUDIO_FIFO, env-only; default
    /// `<tile dir>/audio.fifo`). Must equal the emulator's SDL_DISKAUDIOFILE.
    pub audio_fifo: String,
    /// Silence-gate threshold for the `fifo` source (SH_AUDIO_SILENCE_THRESH,
    /// env-only, default 4): a 20 ms frame whose max|sample| stays at or under
    /// this counts as silent; >=500 ms of silent frames stops Opus packets.
    pub audio_silence_thresh: u16,
    /// Legacy-keyboard quirk (SH_LEGACY_KBD). Pre-1986 guests (Windows 1.x/2.x)
    /// bind a keyboard driver that predates the 1986 101-key "Enhanced" keyboard
    /// and does NOT decode the 0xE0-prefixed EXTENDED scancodes the browser sends
    /// for the dedicated cursor/navigation cluster — it only understands the bare
    /// numeric-keypad cursor scancodes (0x47..0x53, NumLock off). When ON, key()
    /// remaps wire codes 0xE047..=0xE053 to the bare keypad qnum (code & 0x7f)
    /// INSTEAD of the enhanced 0x80|(code&0x7f) form, so arrows/Home/End/PgUp/PgDn/
    /// Ins/Del navigate. DOS is unaffected (its INT 09h BIOS handler accepts both
    /// forms) so this only matters once such a guest installs its own driver.
    /// Default off — modern guests keep distinct dedicated-vs-keypad arrows.
    pub legacy_kbd: bool,
    /// The three per-station KEYBOARD QUIRK knobs. Full rationale, and the code
    /// that applies them, live in `key_quirks.rs`; all three are env-only and
    /// default to off, so no station changes behaviour without declaring them.
    ///
    /// `SH_KEY_REMAP` — `from:to` XT set1 wire codes (hex `0x…` or decimal,
    /// extended keys in the browser's 0xE0xx form), comma-separated. Rewrites
    /// the client's code before all other keyboard handling, for machines with
    /// no key for something the browser has (mpf2 has no Backspace).
    pub key_remap: Vec<(u32, u32)>,
    /// `SH_KEY_MIN_HOLD_MS` — defer a Release until the key has been held this
    /// long, so a once-per-frame emulator can sample it at all.
    pub key_min_hold_ms: u64,
    /// `SH_KEY_MIN_GAP_MS` — make a Press wait this long after the previous
    /// Release, so the all-keys-up state between two keys is sampled too and
    /// back-to-back typing is not read as one long chord. Both pacing knobs
    /// share one serializing gate: over-typing queues in order, never drops.
    pub key_min_gap_ms: u64,
    pub hash_file: String,
    pub signaling_json: String,
    pub cert_rotate_days: u64,
    pub local_http_port: Option<u16>,
    // ---- higher-quality / ABR encoder knobs (SECTION 1 + 5a) ----
    /// x264 preset: ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow.
    pub preset: String,
    /// H.264 profile: baseline|main|high.
    pub profile: String,
    /// x264 tune (zerolatency).
    pub tune: String,
    /// Constant-rate-factor (tier-0 quality anchor). Clamped 10..40.
    pub crf: u8,
    /// tier-0 -maxrate/-bufsize cap in kbps; 0 = auto (per-resolution table).
    pub maxrate_kbps: u32,
    /// VBV bufsize = bufsize_ratio * maxrate. Clamped 0.5..2.0.
    pub bufsize_ratio: f64,
    /// Adaptive-bitrate controller enabled (off => pin tier 0).
    pub abr: bool,
    /// DWELL: minimum ms between ANY two tier changes (anti-oscillation budget).
    /// Must be large enough that the controller cannot ping-pong (the 9 s bounce
    /// regression came from the old 5 s value). Clamped 2000..30000, default 25000.
    pub abr_min_restart_ms: u64,
    /// Tier-3 resolution floor height (px). Clamped >=240.
    pub abr_floor_height: u32,
    /// SERVER-AUTHORITATIVE sustained-backlog downshift (L-1, SH_ABR_BACKLOG_DOWNSHIFT,
    /// env-only, default OFF). When on, a session whose per-session egress SKIP rate
    /// (the backlog gate dropping non-key AUs, transport/backlog.rs) stays elevated
    /// for the same BREACH window as the loss/rtt triggers counts as a THIRD
    /// congestion signal, so a client wedged just under the paced output rate actually
    /// steps the tier down instead of sitting at the ~2 fps backlog floor forever.
    /// OFF => the tier decision stays loss/rtt-only exactly as before (a LAN session
    /// never skips, so this is inert there regardless of the flag).
    pub abr_backlog_downshift: bool,
    /// Asymmetric DOWN dwell (L-2, SH_ABR_DOWN_DWELL_MS, env-only, ms). Minimum time
    /// since the last tier change before a DOWNSHIFT may fire; UPSHIFTS keep the full
    /// abr_min_restart_ms dwell. Lower = react to a handover / congestion onset in a
    /// couple of seconds while still probing back up slowly. Default 0 =>
    /// abr_min_restart_ms (fully symmetric = today's behavior). Clamped 500..30000.
    pub abr_down_dwell_ms: u64,
    /// FPS ladder (SH_ABR_FPS_LADDER, env-only, **default ON** since 2026-08-17;
    /// `off` opts out). Congested tiers cap encode fps (t1 <=15, t2 <=10, t3 <=5):
    /// the PRIMARY congestion lever for near-static retro desktops — half the
    /// framerate is half the bitrate at identical sharpness. Inert at tier 0.
    pub abr_fps_ladder: bool,
    /// Progressive RESOLUTION ladder (L-3, SH_ABR_RES_LADDER, env-only, default OFF).
    /// When on, tier 2 ALSO steps encode resolution down (a gentler ~0.85x step) so
    /// the drop to tier 3 is not a single cliff. OFF => only tier 3 downscales
    /// (today's behavior). LAN sessions stay at tier 0, so this is inert there.
    pub abr_res_ladder: bool,
    /// Forced-IDR backoff under sustained downshift (L-4, SH_ABR_IDR_BACKOFF,
    /// env-only, default OFF). When on, congested tiers (>= 2) lengthen the wall-clock
    /// keyframe heartbeat (x2) and suppress the >=70% scene-change IDR, so an
    /// already-bufferbloated WAN queue isn't repeatedly flooded with large keyframes.
    /// OFF => fixed heartbeat + scene-change IDR at every tier (today). LAN sessions
    /// stay at tier 0, so this is inert there.
    pub abr_idr_backoff: bool,
    /// RTT-keyed conservative START tier (L-3, SH_ABR_START_RTT_MS, env-only, ms).
    /// A fresh session whose first RTT sample exceeds this opens the GLOBAL tier
    /// conservatively (tier 1 at >= this, tier 2 at >= 2x) instead of flooding a
    /// WAN/5G queue with a generous tier-0 keyframe before ABR can react. Default 0
    /// = disabled (always start at tier 0 = today). A LAN connect (sub-ms RTT) never
    /// trips it, so LAN start is unchanged regardless.
    pub abr_start_rtt_ms: u32,
    /// libx264 encode threads (SLICED threading — parallelism WITHIN a frame, no
    /// added frame latency). 0 = auto (min(4, cores)). Clamped 0..16.
    pub enc_threads: u32,
    /// Scheduling nice for the dedicated encode thread (SH_ENC_NICE). The
    /// daemon bulk runs under the service template's Nice=5; measured under
    /// fleet load that inflates x264 WALL time (p50 7.7-14.6ms, p95 to 96ms)
    /// while x264 CPU stays ~1ms — pure scheduler queuing. The encode thread
    /// re-nices ITSELF (setpriority(PRIO_PROCESS, gettid(), n) is
    /// thread-granular on Linux) at startup, BEFORE the first
    /// x264_encoder_open, so the x264 sliced-thread worker pool (created
    /// inside x264_encoder_open on that same thread) inherits the value at
    /// clone time. Semantics:
    ///   Some(n): set nice to n (clamped -20..=19) — plain SCHED_OTHER
    ///            (NOT realtime).
    ///   None ("off" or empty SH_ENC_NICE — the DEFAULT): no syscall, inherit
    ///            the process nice. Default off because nice measurably cannot
    ///            move the contended tail on this EEVDF/RUN_TO_PARITY kernel.
    /// Further step (documented, NOT implemented): SCHED_RR via
    /// sched_setscheduler would remove the tail entirely but risks starving
    /// QEMU vCPUs on a saturated box — do not enable RT by default.
    pub enc_nice: Option<i32>,
    /// Scope native-resolution BGRA snapshot + I420 conversion to the union of
    /// D-Bus damage rectangles. SH_DAMAGE_CONV=off is the instant rollback knob.
    pub damage_conv: bool,
    /// Fall back to a full snapshot/conversion when the padded damage bbox or
    /// accumulated event area reaches this percentage of the frame.
    /// SH_DAMAGE_FULL_PCT, clamped 1..100.
    pub damage_full_pct: u8,
    /// Idle guest auto-pause (SH_IDLE_PAUSE_SECS): seconds with ZERO
    /// WebTransport sessions before the guest's vCPUs are paused with QMP
    /// `stop`; the next accepted session issues `cont` + a forced keyframe so
    /// the joiner sees the live screen sub-second. 0 = disabled; nonzero is
    /// clamped to >= 5 (anti-thrash). Default 60. Pause != loadvm — guest
    /// RAM/state is untouched, so cold-boot-only stations are safe. Per-station
    /// opt-out: SH_IDLE_PAUSE_SECS=0 in station.env. See idle.rs / docs/IDLE-PAUSE.md.
    pub idle_pause_secs: u64,
    /// Process to pause on a NON-QEMU station (SH_IDLE_PAUSE_PIDFILE, env-only),
    /// which has no QMP socket to `stop`: SIGSTOP/SIGCONT that pid instead.
    /// Unset (the QEMU fleet) keeps the QMP mechanism. See idle.rs.
    pub idle_pause_pidfile: Option<String>,
    /// Withhold the FIRST pause this long after daemon start
    /// (SH_IDLE_PAUSE_WARMUP_SECS, env-only, default 0 = off), for a station whose
    /// own health machinery needs the guest RUNNING to vet it. Resumes are
    /// never withheld. See idle.rs / docs/IDLE-PAUSE.md.
    pub idle_pause_warmup_secs: u64,
    /// Guard for the pidfile above (SH_IDLE_PAUSE_PROC_MATCH, env-only): signal
    /// only when this substring is in the pid's /proc/<pid>/cmdline, so a stale
    /// pidfile whose pid was recycled cannot pause an unrelated process.
    pub idle_pause_proc_match: Option<String>,
    /// Bounded per-session egress backlog (SH_SEND_MAX_BACKLOG, frames; env-only).
    /// When a session is more than this many frames ahead of the client's acked
    /// pointer (T_STATS last_frame_id, broadcast-queue-depth fallback), non-key AUs
    /// drop and it resumes on a clean IDR — latest-wins bounded glass-to-glass lag.
    /// Default 6 (~250 ms @ 24 fps); effective bound max(this, fps/4). 0 = unbounded
    /// (rollback). See transport/backlog.rs.
    pub send_max_backlog: u32,
    /// QUIC congestion controller (SH_CC, env-only): true = BBR (default —
    /// the send rate tracks the measured delivery rate, so a bufferbloated
    /// WAN queue is never filled to the loss point); SH_CC=cubic restores
    /// quinn's loss-based default (rollback).
    pub cc_bbr: bool,
    /// SH_INPUT_TELEMETRY (env): 0=off; 1=per-1s summaries; 2=+per-move. input_telemetry.rs.
    pub input_telemetry: u8,
    /// SH_ABS_PACE_MS (env, dbus-abs): min ms between abs injects; 0=off. Paces the
    /// S-Pen's ~120/s flood to ~mouse rate so win98 Paint renders a held drag as a
    /// curve, not a down->up line (the tablet floods faster than Paint draws).
    pub abs_pace_ms: u64,
    /// Closed-loop absolute pointer for the mamecmd backend (SH_MAMECMD_ABS,
    /// env-only, default on): try_pointer_abs emits surface-clamped `MOVEA x y`
    /// targets and `irixagent.lua` closes the loop against the Newport VC2
    /// hardware-cursor registers, so dead-reckoning drift (edge hugging) is
    /// structurally impossible. `0` restores the dead-reckoned MOVEP path
    /// (rollback).
    pub mamecmd_abs: bool,
}

/// Debug/trace env flags (SH_VIDEO_TRACE, SH_ENC_PROFILE, SH_CAP_TRACE) gate on
/// the VALUE being exactly "1". The old `env::var(..).is_ok()` pattern treated
/// any set value — including `SH_VIDEO_TRACE=0` in a station.env — as ENABLED,
/// which for the per-AU trace means an eprintln storm at frame rate.
pub fn env_flag(name: &str) -> bool {
    flag_on(std::env::var(name).ok().as_deref())
}

fn flag_on(v: Option<&str>) -> bool {
    v == Some("1")
}

/// SH_IDLE_PAUSE_SECS clamp: 0 stays 0 (disabled); any nonzero grace is at
/// least 5 s so a misconfigured tiny value can't thrash QMP stop/cont around
/// every reconnect blip.
fn clamp_idle_pause(secs: u64) -> u64 {
    if secs == 0 {
        0
    } else {
        secs.max(5)
    }
}

impl Config {
    pub fn from_args() -> Config {
        let mut args = std::env::args().skip(1).peekable();

        // positional QMP sock (optional; else env/default)
        let mut qmp = std::env::var("SH_QMP").ok();
        if let Some(a) = args.peek() {
            if !a.starts_with("--") {
                qmp = Some(args.next().unwrap());
            }
        }

        let capture_backend = parse_capture_backend(&env_or("SH_CAPTURE", "qemu"));
        let x11_display = env_or("SH_X11_DISPLAY", ":0");
        let x11_cmd_file = env_or("SH_X11_CMD_FILE", "/tmp/irix_cmd");
        let shm_path = env_or("SH_SHM_PATH", "/tmp/irix_fb.shm");
        let shm_poll_ms = env_or("SH_SHM_POLL_MS", "2").parse().unwrap_or(2);
        let shm_damage = matches!(
            env_or("SH_SHM_DAMAGE", "on").to_ascii_lowercase().as_str(),
            "on" | "1" | "true"
        );
        // SH_STATION is the current name; SH_TILE is read as a fallback for one
        // epoch (terminology migration stage 3) so a station whose env has not
        // been re-emitted yet still identifies itself correctly.
        let mut tile = std::env::var("SH_STATION")
            .ok()
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| env_or("SH_TILE", "dev951"));
        let mut port: u16 = env_or("SH_PORT", "4433").parse().unwrap_or(4433);
        let mut fps: u32 = env_or("SH_FPS", "60").parse().unwrap_or(60);
        // 2500 (was 1000): at CQP q10/1920x1200 an IDR is a ~1-2 MB frame whose
        // encode alone spikes to ~90-100 ms (measured p95) — at 1 Hz that was a
        // visible periodic hitch during interaction AND most of the idle
        // bandwidth. Joiners are primed from the cached last IDR, and the
        // full-frame-damage restart provides an instant IDR on real scene
        // changes, so the heartbeat only bounds datagram-loss recovery.
        let mut keyframe_ms: u64 = env_or("SH_KEYFRAME_MS", "2500").parse().unwrap_or(2500);
        let mut host_ip = env_or("SH_HOST_IP", "192.0.2.10");
        let mut advertise = std::env::var("SH_ADVERTISE_HOST").ok();
        let mut legacy_pointer = env_or("SH_POINTER", "abs");
        let mut input_backend_env = std::env::var("SH_INPUT_BACKEND").ok();
        let ghid_socket_env = std::env::var("SH_GHID_SOCKET").ok();
        let mamectl_sock_env = std::env::var("SH_MAMECTL_SOCK").ok();
        let vicectl_sock_env = std::env::var("SH_VICECTL_SOCK").ok();
        let input_bench_addr = std::env::var("SH_INPUT_BENCH_ADDR").ok();
        let mut cursor_off_x: i32 = env_or("SH_CURSOR_OFF_X", "0").parse().unwrap_or(0);
        let mut cursor_off_y: i32 = env_or("SH_CURSOR_OFF_Y", "0").parse().unwrap_or(0);
        let mut cursor_scale: f64 = env_or("SH_CURSOR_SCALE", "1.0").parse().unwrap_or(1.0);
        let rel_quantum: i32 = env_or("SH_REL_QUANTUM", "0").parse().unwrap_or(0).max(0);
        let rel_max_step: i32 = env_or("SH_REL_MAX_STEP", "256")
            .parse()
            .unwrap_or(256)
            .max(1);
        let mut warpd_addr = env_or("SH_WARPD_ADDR", "127.0.0.1:7790");
        let mut warpd_buttons_qemu = env_or("SH_WARPD_BUTTONS", "agent") == "qemu";
        let mut warpd_wheel = env_or("SH_WARPD_WHEEL", "auto");
        let mut warpd_pace_ms: u64 = env_or("SH_WARPD_PACE_MS", "8").parse().unwrap_or(8);
        let mut warpd_button_delay_ms: u64 =
            env_or("SH_WARPD_BUTTON_DELAY_MS", "0").parse().unwrap_or(0);
        let mut audio = matches!(env_or("SH_AUDIO", "off").as_str(), "on" | "1" | "true");
        let mut audio_bitrate: u32 = env_or("SH_AUDIO_BITRATE", "96000").parse().unwrap_or(96000);
        // Env-only fifo-source knobs (no CLI flags, like SH_SEND_MAX_BACKLOG).
        let audio_source = parse_audio_source(&env_or("SH_AUDIO_SOURCE", "dbus"));
        let audio_fifo_env = std::env::var("SH_AUDIO_FIFO").ok();
        let idle_pause_pidfile = std::env::var("SH_IDLE_PAUSE_PIDFILE")
            .ok()
            .filter(|s| !s.is_empty());
        let idle_pause_proc_match = std::env::var("SH_IDLE_PAUSE_PROC_MATCH")
            .ok()
            .filter(|s| !s.is_empty());
        let idle_pause_warmup_secs: u64 = env_or("SH_IDLE_PAUSE_WARMUP_SECS", "0")
            .parse()
            .unwrap_or(0);
        let audio_silence_thresh = parse_silence_thresh(&env_or("SH_AUDIO_SILENCE_THRESH", "4"));
        let mut legacy_kbd = matches!(env_or("SH_LEGACY_KBD", "off").as_str(), "on" | "1" | "true");
        let key_remap = parse_key_remap(&env_or("SH_KEY_REMAP", ""));
        let key_min_hold_ms: u64 = env_or("SH_KEY_MIN_HOLD_MS", "0").parse().unwrap_or(0);
        let key_min_gap_ms: u64 = env_or("SH_KEY_MIN_GAP_MS", "0").parse().unwrap_or(0);
        let mut hash_file = std::env::var("SH_HASH_FILE").ok();
        let mut signaling_json = std::env::var("SH_SIGNALING_JSON").ok();
        let mut rotate_days: u64 = env_or("SH_CERT_ROTATE_DAYS", "10").parse().unwrap_or(10);
        let mut local_http: Option<u16> = std::env::var("SH_LOCAL_HTTP")
            .ok()
            .and_then(|s| s.parse().ok());
        let mut preset = encoder_preset_env();
        let mut profile = env_or("SH_PROFILE", "high");
        let mut tune = env_or("SH_TUNE", "zerolatency");
        // Default quantiser 10. At tier 0 this value is used as a CONSTANT QP
        // (see encode/worker.rs): CQP removes the CRF/VBV rate-control
        // feedback loop that re-quantised static high-frequency content (the CDE
        // stipple) slightly differently every frame — the visible idle
        // "dancing/swimming". Measured on the artefact-lab harness: CQP q10 codes
        // a static screen as BIT-EXACT SKIP P-frames (temporal flicker 0.0000,
        // consecutive-frame SSIM 1.0) vs 0.0824 under CRF14+VBV, and is crisper
        // (61.3 vs 59.1 dB XPSNR). On ABR tiers >= 1 the same value acts as the
        // CRF anchor (+3/+6 per tier) with VBV re-enabled, so a congested WAN
        // client still gets a hard bit ceiling. Per-station SH_CRF override wins.
        let mut crf: u8 = env_or("SH_CRF", "10").parse().unwrap_or(10);
        let mut maxrate_kbps: u32 = env_or("SH_MAXRATE_KBPS", "0").parse().unwrap_or(0);
        let mut bufsize_ratio: f64 = env_or("SH_BUFSIZE_RATIO", "1.0").parse().unwrap_or(1.0);
        let mut abr = matches!(env_or("SH_ABR", "on").as_str(), "on" | "1" | "true");
        let mut abr_min_restart_ms: u64 = env_or("SH_ABR_MIN_RESTART_MS", "25000")
            .parse()
            .unwrap_or(25000);
        let mut abr_floor_height: u32 = env_or("SH_ABR_FLOOR_HEIGHT", "480").parse().unwrap_or(480);
        // L-1 / L-2 ABR extensions — all default to today's behavior (env-only opt-in).
        let abr_backlog_downshift = env_flag("SH_ABR_BACKLOG_DOWNSHIFT");
        let abr_down_dwell_ms: u64 = env_or("SH_ABR_DOWN_DWELL_MS", "0").parse().unwrap_or(0);
        let abr_fps_ladder = !matches!(env_or("SH_ABR_FPS_LADDER", "on").as_str(), "off" | "0");
        let abr_res_ladder = env_flag("SH_ABR_RES_LADDER");
        let abr_idr_backoff = env_flag("SH_ABR_IDR_BACKOFF");
        let abr_start_rtt_ms: u32 = env_or("SH_ABR_START_RTT_MS", "0").parse().unwrap_or(0);
        // 0 = auto (min(4, cores)) resolved in encode/mod.rs. Replaces the old
        // ffmpeg `-threads 1`; SLICED threads add NO frame latency.
        let mut enc_threads: u32 = env_or("SH_ENC_THREADS", "0").parse().unwrap_or(0);
        // Default "off" = no syscall, inherit the process nice (the service's
        // Nice=5). An integer value re-nices the encode thread. See the enc_nice
        // field doc above.
        let mut enc_nice: Option<i32> = parse_enc_nice(&env_or("SH_ENC_NICE", "off"));
        let mut damage_conv = matches!(
            env_or("SH_DAMAGE_CONV", "on").to_ascii_lowercase().as_str(),
            "on" | "1" | "true"
        );
        let mut damage_full_pct: u8 = env_or("SH_DAMAGE_FULL_PCT", "35").parse().unwrap_or(35);
        // Default ON with a 60 s grace (see the idle_pause_secs field doc).
        let mut idle_pause_secs: u64 = env_or("SH_IDLE_PAUSE_SECS", "60").parse().unwrap_or(60);
        // Env-only (no CLI flag), like SH_INPUT_BENCH_ADDR. See the field doc.
        let send_max_backlog: u32 = env_or("SH_SEND_MAX_BACKLOG", "6").parse().unwrap_or(6);
        let cc_bbr = parse_cc(&env_or("SH_CC", "bbr"));
        let input_telemetry = parse_telemetry_level(&env_or("SH_INPUT_TELEMETRY", "0"));
        let abs_pace_ms: u64 = env_or("SH_ABS_PACE_MS", "0").parse().unwrap_or(0);
        let mamecmd_abs = matches!(
            env_or("SH_MAMECMD_ABS", "on").to_ascii_lowercase().as_str(),
            "on" | "1" | "true"
        );

        while let Some(a) = args.next() {
            match a.as_str() {
                "--tile" => tile = args.next().unwrap_or(tile),
                "--port" => port = args.next().and_then(|s| s.parse().ok()).unwrap_or(port),
                "--fps" => fps = args.next().and_then(|s| s.parse().ok()).unwrap_or(fps),
                "--keyframe-ms" => {
                    keyframe_ms = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(keyframe_ms)
                }
                "--host-ip" => host_ip = args.next().unwrap_or(host_ip),
                "--advertise-host" => advertise = args.next(),
                "--input-backend" => input_backend_env = args.next(),
                "--pointer" => legacy_pointer = args.next().unwrap_or(legacy_pointer),
                "--cursor-off-x" => {
                    cursor_off_x = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(cursor_off_x)
                }
                "--cursor-off-y" => {
                    cursor_off_y = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(cursor_off_y)
                }
                "--cursor-scale" => {
                    cursor_scale = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(cursor_scale)
                }
                "--warpd-addr" => warpd_addr = args.next().unwrap_or(warpd_addr),
                "--warpd-buttons" => warpd_buttons_qemu = args.next().as_deref() == Some("qemu"),
                "--warpd-wheel" => warpd_wheel = args.next().unwrap_or(warpd_wheel),
                "--warpd-pace-ms" => {
                    warpd_pace_ms = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(warpd_pace_ms)
                }
                "--warpd-button-delay-ms" => {
                    warpd_button_delay_ms = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(warpd_button_delay_ms)
                }
                "--audio" => {
                    audio = matches!(
                        args.next().as_deref(),
                        Some("on") | Some("1") | Some("true")
                    )
                }
                "--audio-bitrate" => {
                    audio_bitrate = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(audio_bitrate)
                }
                "--legacy-kbd" => {
                    legacy_kbd = matches!(
                        args.next().as_deref(),
                        Some("on") | Some("1") | Some("true")
                    )
                }
                "--hash-file" => hash_file = args.next(),
                "--signaling-json" => signaling_json = args.next(),
                "--cert-rotate-days" => {
                    rotate_days = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(rotate_days)
                }
                "--local-http" => local_http = args.next().and_then(|s| s.parse().ok()),
                "--preset" => preset = args.next().unwrap_or(preset),
                "--profile" => profile = args.next().unwrap_or(profile),
                "--tune" => tune = args.next().unwrap_or(tune),
                "--crf" => crf = args.next().and_then(|s| s.parse().ok()).unwrap_or(crf),
                "--maxrate" => {
                    maxrate_kbps = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(maxrate_kbps)
                }
                "--bufsize-ratio" => {
                    bufsize_ratio = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(bufsize_ratio)
                }
                "--abr" => {
                    abr = matches!(
                        args.next().as_deref(),
                        Some("on") | Some("1") | Some("true")
                    )
                }
                "--abr-min-restart-ms" => {
                    abr_min_restart_ms = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(abr_min_restart_ms)
                }
                "--abr-floor-height" => {
                    abr_floor_height = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(abr_floor_height)
                }
                "--enc-threads" => {
                    enc_threads = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(enc_threads)
                }
                "--enc-nice" => {
                    enc_nice = args.next().map(|s| parse_enc_nice(&s)).unwrap_or(enc_nice)
                }
                "--damage-conv" => {
                    damage_conv = matches!(
                        args.next()
                            .unwrap_or_default()
                            .to_ascii_lowercase()
                            .as_str(),
                        "on" | "1" | "true"
                    )
                }
                "--damage-full-pct" => {
                    damage_full_pct = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(damage_full_pct)
                }
                "--idle-pause-secs" => {
                    idle_pause_secs = args
                        .next()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(idle_pause_secs)
                }
                _ => {}
            }
        }

        // Derive defaults from the station name so a bare `--tile foo --port N` works.
        let base = format!("/data/vms/streamhost/stations/{tile}");
        let qmp = qmp.unwrap_or_else(|| "/data/vms/streamhost/run951/qmp951.sock".to_string());
        let hash_file = hash_file.unwrap_or_else(|| format!("{base}/cert_hash_b64.txt"));
        let signaling_json = signaling_json.unwrap_or_else(|| format!("{base}/signaling.json"));
        let host_ip: IpAddr = host_ip
            .parse()
            .unwrap_or(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 126)));
        let advertise_host = advertise.unwrap_or_else(|| host_ip.to_string());
        // Env-only: a shared secret on a command line is visible in `ps` to every
        // process on labhost. Empty is the same as unset (the gate stays off).
        let session_key = std::env::var("SH_SESSION_KEY")
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .map(String::into_bytes);
        let input_backend = parse_input_backend(&legacy_pointer, input_backend_env.as_deref());
        let ghid_socket = ghid_socket_env.unwrap_or_else(|| format!("{base}/gallery-hid.sock"));
        let mamectl_sock = mamectl_sock_env.unwrap_or_else(|| format!("{base}/ctl.sock"));
        let audio_fifo = audio_fifo_env.unwrap_or_else(|| format!("{base}/audio.fifo"));
        let warpd_wheel_agent = match warpd_wheel.to_ascii_lowercase().as_str() {
            "agent" => true,
            "qemu" => false,
            _ => !warpd_buttons_qemu,
        };

        // Validate/normalize the encoder knobs (fall back to the safe default on garbage).
        let profile = match profile.to_ascii_lowercase().as_str() {
            "baseline" => "baseline",
            "main" => "main",
            _ => "high",
        }
        .to_string();
        let preset = normalize_encoder_preset(&preset);

        Config {
            tile,
            qmp_sock: qmp,
            capture_backend,
            x11_display,
            x11_cmd_file,
            shm_path,
            shm_poll_ms,
            shm_damage,
            udp_port: port,
            host_ip,
            advertise_host,
            session_key,
            // >= 1: SH_FPS=0 parses fine and would divide-by-zero the encode
            // loop's frame-interval math (a silent no-video station).
            fps: fps.clamp(1, 240),
            keyframe_ms: keyframe_ms.clamp(100, 10_000),
            input_backend,
            ghid_socket,
            mamectl_sock,
            vicectl_sock: vicectl_sock_env.unwrap_or_else(|| format!("{base}/ctl.sock")),
            input_bench_addr,
            cursor_off_x,
            cursor_off_y,
            rel_quantum,
            rel_max_step,
            cursor_scale,
            warpd_addr,
            warpd_buttons_qemu,
            warpd_wheel_agent,
            warpd_pace_ms: warpd_pace_ms.min(50),
            warpd_button_delay_ms: warpd_button_delay_ms.min(250),
            audio,
            audio_bitrate,
            audio_source,
            audio_fifo,
            audio_silence_thresh,
            legacy_kbd,
            key_remap,
            // 250 ms is already an eternity for a keypress; cap so a typo in a
            // station.env cannot wedge the keyboard.
            key_min_hold_ms: key_min_hold_ms.min(250),
            key_min_gap_ms: key_min_gap_ms.min(250),
            hash_file,
            signaling_json,
            cert_rotate_days: rotate_days.max(1),
            local_http_port: local_http,
            preset,
            profile,
            tune,
            crf: crf.clamp(10, 40),
            maxrate_kbps,
            bufsize_ratio: bufsize_ratio.clamp(0.5, 2.0),
            abr,
            abr_min_restart_ms: abr_min_restart_ms.clamp(2000, 30_000),
            abr_backlog_downshift,
            // Default 0 => symmetric with the up dwell (today's behavior).
            abr_down_dwell_ms: if abr_down_dwell_ms == 0 {
                abr_min_restart_ms.clamp(2000, 30_000)
            } else {
                abr_down_dwell_ms.clamp(500, 30_000)
            },
            abr_fps_ladder,
            abr_res_ladder,
            abr_idr_backoff,
            abr_start_rtt_ms,
            abr_floor_height: abr_floor_height.max(240),
            enc_threads: enc_threads.min(16),
            enc_nice,
            damage_conv,
            damage_full_pct: damage_full_pct.clamp(1, 100),
            idle_pause_secs: clamp_idle_pause(idle_pause_secs),
            idle_pause_pidfile,
            idle_pause_proc_match,
            idle_pause_warmup_secs,
            send_max_backlog,
            cc_bbr,
            input_telemetry,
            abs_pace_ms: abs_pace_ms.min(100),
            mamecmd_abs,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        clamp_idle_pause, flag_on, normalize_encoder_preset, parse_cc, parse_telemetry_level,
    };

    #[test]
    fn telemetry_level_parse() {
        assert_eq!(parse_telemetry_level("off"), 0);
        assert_eq!(parse_telemetry_level("garbage"), 0); // unparsable -> 0
        assert_eq!(parse_telemetry_level("1"), 1);
        assert_eq!(parse_telemetry_level("on"), 1);
        assert_eq!(parse_telemetry_level("2"), 2);
        assert_eq!(parse_telemetry_level("5"), 2); // >2 clamps
    }

    // The is_ok() trap: a set-but-disabled value must NOT enable the flag.
    #[test]
    fn trace_flag_gates_on_value_one() {
        assert!(flag_on(Some("1")));
        assert!(!flag_on(Some("0")));
        assert!(!flag_on(Some("")));
        assert!(!flag_on(Some("on"))); // strict "1", matching the SH_CAP_TRACE precedent
        assert!(!flag_on(None));
    }

    // 0 = disabled must survive the clamp; tiny nonzero graces are floored.
    #[test]
    fn idle_pause_clamp() {
        assert_eq!(clamp_idle_pause(0), 0);
        assert_eq!(clamp_idle_pause(1), 5);
        assert_eq!(clamp_idle_pause(5), 5);
        assert_eq!(clamp_idle_pause(60), 60);
    }

    // Only an explicit "cubic" opts out of BBR; garbage falls back to the
    // default like every other env_or knob.
    #[test]
    fn cc_knob_defaults_to_bbr() {
        assert!(parse_cc("bbr"));
        assert!(!parse_cc("cubic"));
        assert!(!parse_cc("CUBIC"));
        assert!(!parse_cc(" cubic "));
        assert!(parse_cc("")); // unset/garbage -> default bbr
        assert!(parse_cc("reno"));
    }

    #[test]
    fn encoder_preset_normalizes_and_defaults_safely() {
        assert_eq!(normalize_encoder_preset("ULTRAFAST"), "ultrafast");
        assert_eq!(normalize_encoder_preset("veryfast"), "veryfast");
        assert_eq!(normalize_encoder_preset("not-a-preset"), "ultrafast");
    }
}
