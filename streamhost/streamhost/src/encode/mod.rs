// Encode: raw BGRA frames -> H.264 Annex-B access units via IN-PROCESS libx264
// (zerolatency), driven through the `x264-sys` FFI (x264_encoder_encode).
//
// This replaces the previous ffmpeg-child prototype. We no longer shell out to
// `ffmpeg -c:v libx264 ...`, no longer memcpy raw frames through a stdin pipe,
// and no longer detect access-unit boundaries by watching the child's stdout go
// quiet for ~2 ms: each `x264_encoder_encode()` call returns EXACTLY one frame's
// NAL units (zerolatency => no frame reorder, no encoder delay), so the AU
// boundary is exact per call. The encoded bitstream is byte-for-byte the same
// libx264 output as before (same params below); only the plumbing changed.
//
// Behaviour preserved verbatim vs the ffmpeg path:
//   * tier-0 = CONSTANT-QP, NO VBV  (i_rc_method=X264_RC_CQP, i_qp_constant)
//   * tier>=1 = CRF + VBV           (X264_RC_CRF, rc.f_rf_constant,
//                                    rc.i_vbv_max_bitrate / i_vbv_buffer_size)
//   * b-frames=0, rc-lookahead=0, sync-lookahead=0, profile high, Annex-B,
//     repeat-headers (SPS+PPS lead every IDR), scenecut OFF (i_scenecut=0),
//     -g 300 / keyint_min 1.
//   * content scene-change -> forced IDR, SAME >=70% sampled-pixel detector +
//     3 s cooldown. We now force it via pic_in.i_type=X264_TYPE_IDR on the very
//     frame that tripped the detector (repeat-headers => that IDR carries
//     SPS+PPS so every client re-syncs) INSTEAD of killing+restarting the child.
//   * wall-clock keyframe HEARTBEAT (>= keyframe_ms) -> forced IDR, same effect
//     as the old `-force_key_frames expr` but driven off the last emitted IDR.
//   * ABR tier change / mid-stream geometry change still RE-OPEN the encoder
//     (fresh SPS+PPS+IDR re-syncs every client) — same semantics as the old
//     child restart.
//
// NEW: SLICED threads (i_threads=N, b_sliced_threads=1) replace the old
// `-threads 1`. Slice threading parallelises WITHIN a frame, so it adds no frame
// latency (unlike frame threading, which buffers frames). N is gated behind the
// SH_ENC_THREADS / --enc-threads knob (0 = auto = min(4, cores)).
//
// NEW: DEDICATED ENCODE THREAD. The encode-latency investigation showed
// x264_encoder_encode costs ~1 ms CPU at tile resolutions but ~11-13 ms WALL
// when run synchronously on the shared Nice=5 tokio runtime serving the whole
// fleet — pure OS-scheduling preemption (the old ffmpeg CHILD never showed it
// because a process is its own scheduling entity). Conversion + encode now run
// on one std::thread per encoder instance (its own scheduling entity, blocks on
// a condvar between frames), fed through a depth-1 latest-wins handoff that
// never blocks a tokio worker. Design + equivalence argument at `Handoff` (handoff.rs).
//
// FUTURE: the ABR tier step could become a live x264_encoder_reconfig() (mutate
// rc.i_vbv_* with no IDR blip); we keep the re-open for now to match behaviour.
//
// MODULE LAYOUT (this file = public API + shared types + spawn):
//   * params.rs  — preset/profile enum + maxrate/tier/thread resolution
//   * scene.rs   — receiver-gated feed decision + scene-change detector
//   * run.rs     — the capture->encode driver loop (`run`)
//   * convert.rs — BGRA->I420 conversion, damage-patch splice, tier-3 downscale
//   * x264.rs    — x264 FFI: param builder, encoder handle, SPS extraction
//   * worker.rs  — dedicated encode-thread body + its lifecycle handle
//   * handoff.rs — depth-1 latest-wins frame/control handoff to the encode thread

use std::sync::atomic::{AtomicU16, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;

use tokio::sync::{broadcast, Mutex};

use crate::capture::Capture;

mod convert;
mod handoff;
mod params;
mod run;
mod scene;
mod worker;
mod x264;

use params::{preset_enum, profile_idc_of};

#[derive(Clone)]
pub struct Au {
    pub data: Arc<Vec<u8>>,
    pub is_key: bool,
    pub capture_ts_us: u32,
    pub frame_id: u32,
}

/// Static (per-tile) encoder configuration threaded from Config into the
/// capture->encode loop. The ABR TIER (a dynamic index into the ladder) is held
/// separately in `EncoderOut::tier`; these are the invariants the ladder is built
/// on top of.
#[derive(Clone)]
pub struct EncodeParams {
    pub preset: String,
    pub profile: String, // baseline|main|high
    pub tune: String,
    /// tier-0 CRF anchor (tier1 = +3, tier2/3 = +6).
    pub crf: u8,
    /// tier-0 -maxrate cap in kbps; 0 = auto (per-resolution table 1.3).
    pub maxrate_kbps: u32,
    pub bufsize_ratio: f64,
    /// tier-3 resolution floor height (px).
    pub abr_floor_height: u32,
    /// libx264 SLICED-thread count. 0 = auto (min(4, cores)).
    pub threads: u32,
    /// Encode-thread nice: Some(n) = setpriority(PRIO_PROCESS, gettid(), n)
    /// at encode-thread startup (before the first x264_encoder_open, so the
    /// x264 sliced pool inherits it); None = inherit the process nice.
    /// See config.rs `enc_nice` for the full rationale. SH_ENC_NICE.
    pub enc_nice: Option<i32>,
    /// Damage-bbox snapshot + native I420 conversion gate (SH_DAMAGE_CONV).
    pub damage_conv: bool,
    /// Full-conversion fallback threshold for bbox or accumulated event area.
    pub damage_full_pct: u8,
    /// L-2 fps ladder (SH_ABR_FPS_LADDER): cap encode fps on congested tiers
    /// (tier1 <=15, tier2/3 <=10). false = native fps at every tier (today's
    /// behavior; a LAN session never leaves tier 0 so it is inert there).
    pub abr_fps_ladder: bool,
    /// L-3 progressive resolution ladder (SH_ABR_RES_LADDER): tier 2 also steps
    /// resolution down. false = only tier 3 downscales (today's behavior).
    pub abr_res_ladder: bool,
    /// L-4 forced-IDR backoff (SH_ABR_IDR_BACKOFF): congested tiers (>= 2) lengthen
    /// the keyframe heartbeat + suppress the scene-change IDR. false = today.
    pub abr_idr_backoff: bool,
}

/// A snapshot of the CURRENTLY-RUNNING encoder params, published by the encode
/// loop after each (re)launch and refined once the first SPS is parsed. The
/// transport reads this to build the KIND_PARAMS subtype-1 message.
#[derive(Clone, Copy)]
pub struct PublishedParams {
    pub tier: u8,
    pub target_kbps: u32,
    pub crf: u8,
    pub width: u16,
    pub height: u16,
    pub native_width: u16,
    pub native_height: u16,
    pub fps_cap: u16,
    pub keyframe_ms: u16,
    pub profile_idc: u8,
    pub level_idc: u8,
    pub preset_enum: u8,
}

pub struct EncoderOut {
    pub tx: broadcast::Sender<Au>,
    // latest keyframe, so a freshly-joined session can start decoding immediately
    pub last_key: Arc<Mutex<Option<Au>>>,
    // Bumped on every new client connection (transport::handle_session). The
    // capture->encode loop polls this and, when it advances, feeds a frame
    // immediately (bypassing the damage wait) so the wall-clock keyframe
    // heartbeat delivers a fresh IDR to the joiner within <= keyframe_ms even if
    // the guest is completely static. See docs/DESIGN.md §1.2 "keyframe starvation".
    key_req: AtomicU64,
    // Event-driven wake for the loop's inner wait: pulsed (permit-storing
    // notify_one) by request_keyframe()/request_tier() so a connect or ABR tier
    // change wakes the loop IMMEDIATELY even while it sits on the long unwatched
    // poll interval (idle-CPU fix, 2026-07-12). The permit semantics close the
    // check-then-wait race: a bump between the loop's atomic check and its await
    // still completes the next notified() instantly.
    wake: tokio::sync::Notify,

    // ---- ABR control (SECTION 2.5). The controller (abr.rs) writes `tier` and
    // bumps `reconfig_gen`; the encode loop polls `reconfig_gen` in the same 2 ms
    // inner poll as `key_req`, and on change RE-OPENS the x264 encoder and
    // tail-calls run() with the new tier. The fresh libx264 always emits
    // SPS+PPS+IDR first, so the existing is_key -> last_key path repopulates the
    // cache and every client re-syncs — no explicit request_keyframe needed. ----
    tier: AtomicU8,
    reconfig_gen: AtomicU64,

    // ---- full-frame-damage force-IDR state (encode loop only) ----
    // Rising-edge + cooldown so a DESKTOP SWITCH (isolated full-frame change)
    // forces an IDR, while SUSTAINED full-screen animation (screensaver, boot
    // animation, video) fires at most once at onset instead of re-keying every
    // frame.
    dmg_prev_full: std::sync::atomic::AtomicBool,
    dmg_last_restart_ms: AtomicU64,

    // ---- published current params (encode loop writes; transport reads) ----
    params_gen: AtomicU64,
    cur_tier: AtomicU8,
    cur_target_kbps: AtomicU32,
    cur_crf: AtomicU8,
    cur_w: AtomicU16,
    cur_h: AtomicU16,
    cur_native_w: AtomicU16,
    cur_native_h: AtomicU16,
    cur_fps_cap: AtomicU16,
    cur_keyframe_ms: AtomicU16,
    cur_profile_idc: AtomicU8,
    cur_level_idc: AtomicU8,
    cur_preset_enum: AtomicU8,
}

impl EncoderOut {
    /// Request a fresh keyframe ASAP for a newly-connected client. Wakes the
    /// capture->encode loop (via a 2 ms atomic poll) so it feeds a frame without
    /// waiting on guest damage; the wall-clock keyframe heartbeat then forces an
    /// IDR at the next boundary. Cheap + idempotent — safe to call on every
    /// connect. The connecting session is ALSO primed with the freshest cached
    /// keyframe (EncoderOut::last_key) for instant go-live.
    pub fn request_keyframe(&self) {
        self.key_req.fetch_add(1, Ordering::Relaxed);
        self.wake.notify_one();
    }

    /// ABR controller entry point: request a tier change. Idempotent — writes the
    /// desired tier and bumps reconfig_gen so the encode loop re-opens the encoder
    /// with the new ladder rung. Calling with the current tier still forces a
    /// re-open (fresh IDR), so the controller must only call this on an actual
    /// tier change.
    pub fn request_tier(&self, tier: u8) {
        self.tier.store(tier, Ordering::Relaxed);
        self.reconfig_gen.fetch_add(1, Ordering::Relaxed);
        self.wake.notify_one();
    }

    /// The tier the encoder is CURRENTLY running at (published, post-launch).
    /// (No caller today — abr reads params()/params_gen() — kept as the public
    /// accessor for the published tier.)
    #[allow(dead_code)]
    pub fn current_tier(&self) -> u8 {
        self.cur_tier.load(Ordering::Relaxed)
    }

    /// Monotonic generation counter bumped whenever the published params change
    /// (tier restart or first-SPS refinement). Transport watches this to push a
    /// KIND_PARAMS subtype-1 to every session on change.
    pub fn params_gen(&self) -> u64 {
        self.params_gen.load(Ordering::Relaxed)
    }

    /// Snapshot the currently-running encoder params for the wire.
    pub fn params(&self) -> PublishedParams {
        PublishedParams {
            tier: self.cur_tier.load(Ordering::Relaxed),
            target_kbps: self.cur_target_kbps.load(Ordering::Relaxed),
            crf: self.cur_crf.load(Ordering::Relaxed),
            width: self.cur_w.load(Ordering::Relaxed),
            height: self.cur_h.load(Ordering::Relaxed),
            native_width: self.cur_native_w.load(Ordering::Relaxed),
            native_height: self.cur_native_h.load(Ordering::Relaxed),
            fps_cap: self.cur_fps_cap.load(Ordering::Relaxed),
            keyframe_ms: self.cur_keyframe_ms.load(Ordering::Relaxed),
            profile_idc: self.cur_profile_idc.load(Ordering::Relaxed),
            level_idc: self.cur_level_idc.load(Ordering::Relaxed),
            preset_enum: self.cur_preset_enum.load(Ordering::Relaxed),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn publish(
        &self,
        tier: u8,
        target_kbps: u32,
        crf: u8,
        w: u16,
        h: u16,
        native_w: u16,
        native_h: u16,
        fps_cap: u16,
        keyframe_ms: u16,
        profile_idc: u8,
        level_idc: u8,
        preset_enum: u8,
    ) {
        self.cur_tier.store(tier, Ordering::Relaxed);
        self.cur_target_kbps.store(target_kbps, Ordering::Relaxed);
        self.cur_crf.store(crf, Ordering::Relaxed);
        self.cur_w.store(w, Ordering::Relaxed);
        self.cur_h.store(h, Ordering::Relaxed);
        self.cur_native_w.store(native_w, Ordering::Relaxed);
        self.cur_native_h.store(native_h, Ordering::Relaxed);
        self.cur_fps_cap.store(fps_cap, Ordering::Relaxed);
        self.cur_keyframe_ms.store(keyframe_ms, Ordering::Relaxed);
        self.cur_profile_idc.store(profile_idc, Ordering::Relaxed);
        self.cur_level_idc.store(level_idc, Ordering::Relaxed);
        self.cur_preset_enum.store(preset_enum, Ordering::Relaxed);
        self.params_gen.fetch_add(1, Ordering::Relaxed);
    }
}

/// Spawn the capture->encode pipeline. Returns a broadcast source of access
/// units. `keyframe_ms` is the wall-clock keyframe HEARTBEAT: while at least one
/// client is connected, a fresh IDR is forced at least this often (default
/// 2500 ms) so a late joiner never waits long for a decodable first frame.
///
/// RECEIVER GATING (idle-CPU fix, 2026-07-12): with ZERO receivers NOTHING
/// feeds the encoder — neither the heartbeat NOR guest damage (an animated
/// unwatched guest used to run the full snapshot+scene-detect+x264 pipeline
/// 24/7, ~23% of the host across the fleet). The loop wakes on damage but only
/// does a few atomic loads before going back to sleep. Correctness for
/// joiners is carried entirely by the key_req kick: transport subscribes
/// FIRST, then request_keyframe() wakes the loop (event-driven Notify) and the
/// next fed frame is a forced IDR (`answered_key_req` at the feed site), so a
/// fresh join on a long-idle tile still gets decodable video within ~1 frame.
/// The cached `last_key` primer may be stale after an unwatched gap — same
/// class of staleness as the old <=heartbeat window, just longer; the forced
/// IDR replaces it immediately.
pub fn spawn(
    cap: Capture,
    fps_cap: u32,
    keyframe_ms: u64,
    params: EncodeParams,
) -> Arc<EncoderOut> {
    let (tx, _rx) = broadcast::channel::<Au>(256);
    let out = Arc::new(EncoderOut {
        tx: tx.clone(),
        last_key: Arc::new(Mutex::new(None)),
        key_req: AtomicU64::new(0),
        wake: tokio::sync::Notify::new(),
        tier: AtomicU8::new(0),
        reconfig_gen: AtomicU64::new(0),
        dmg_prev_full: std::sync::atomic::AtomicBool::new(false),
        dmg_last_restart_ms: AtomicU64::new(0),
        params_gen: AtomicU64::new(0),
        cur_tier: AtomicU8::new(0),
        cur_target_kbps: AtomicU32::new(0),
        cur_crf: AtomicU8::new(params.crf),
        cur_w: AtomicU16::new(0),
        cur_h: AtomicU16::new(0),
        cur_native_w: AtomicU16::new(0),
        cur_native_h: AtomicU16::new(0),
        cur_fps_cap: AtomicU16::new(fps_cap.min(u16::MAX as u32) as u16),
        cur_keyframe_ms: AtomicU16::new(keyframe_ms.min(u16::MAX as u64) as u16),
        cur_profile_idc: AtomicU8::new(profile_idc_of(&params.profile)),
        cur_level_idc: AtomicU8::new(0),
        cur_preset_enum: AtomicU8::new(preset_enum(&params.preset)),
    });
    let out2 = out.clone();
    tokio::spawn(async move {
        if let Err(e) = run::run(cap, tx, out2, fps_cap, keyframe_ms, params).await {
            eprintln!("[encode] loop exited: {e:?}");
        }
    });
    out
}
