// The dedicated encode-thread body + its lifecycle handle. Takes frames/control
// off the depth-1 handoff, converts BGRA->I420 (+tier-3 downscale via convert.rs),
// drives the x264 encoder (x264.rs), extracts the SPS, and emits AUs in submit
// order. Extracted from the old monolithic encode.rs. Pipeline overview:
// encode/mod.rs; handoff design + equivalence argument: handoff.rs.

use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::broadcast;

use x264_sys as sys;

use super::convert::{apply_bgra_patch_to_i420, bgra_to_i420, box_downscale_bgra};
use super::handoff::{Ctrl, FrameJob, Handoff, Msg, ReopenSpec};
use super::params::preset_enum;
use super::x264::{configure_param, extract_sps_profile_level, X264Enc};
use super::{Au, EncoderOut};

/// DEBUG (SH_ENC_PROFILE): this THREAD's consumed CPU time in ns. Used to
/// separate real CPU cost from wall-clock scheduling inflation in the encode
/// latency profile. Only called on the profiling path.
fn thread_cpu_ns() -> u128 {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut ts) };
    ts.tv_sec as u128 * 1_000_000_000 + ts.tv_nsec as u128
}

/// Handle to the dedicated encode thread. One per encoder instance; survives
/// every reopen (tier/geometry changes are control messages, not thread churn).
/// Drop requests shutdown and joins (bounded) — no thread leaks on teardown.
pub(super) struct EncodeWorker {
    ho: Arc<Handoff>,
    join: Option<std::thread::JoinHandle<()>>,
}

impl EncodeWorker {
    pub(super) fn spawn(
        tx: broadcast::Sender<Au>,
        out: Arc<EncoderOut>,
        enc_nice: Option<i32>,
    ) -> anyhow::Result<Self> {
        let ho = Handoff::new();
        let ho_thread = ho.clone();
        let join = std::thread::Builder::new()
            .name("sh-encode".into())
            .spawn(move || {
                let ho_guard = ho_thread.clone();
                let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    worker_main(ho_thread, tx, out, enc_nice)
                }));
                if let Err(p) = r {
                    // Surface a panic as a dead handoff (run() polls it) instead
                    // of a silent stall of the whole video pipeline.
                    let what = p
                        .downcast_ref::<&str>()
                        .map(|s| s.to_string())
                        .or_else(|| p.downcast_ref::<String>().cloned())
                        .unwrap_or_else(|| "non-string panic payload".into());
                    ho_guard.mark_dead(format!("encode thread panicked: {what}"));
                }
            })?;
        Ok(EncodeWorker {
            ho,
            join: Some(join),
        })
    }

    pub(super) fn reopen(&self, spec: ReopenSpec) {
        self.ho.submit_reopen(spec);
    }

    pub(super) fn submit_frame(&self, job: FrameJob) {
        self.ho.submit_frame(job);
    }

    /// Some(reason) once the encode thread has exited abnormally.
    pub(super) fn dead(&self) -> Option<String> {
        self.ho.dead()
    }
}

impl Drop for EncodeWorker {
    fn drop(&mut self) {
        self.ho.submit_shutdown();
        if let Some(join) = self.join.take() {
            // Bounded join: the thread exits after at most one in-flight encode
            // (it re-checks control between messages and never sleeps holding
            // work). If it is truly wedged, detach rather than hang teardown.
            let t0 = Instant::now();
            while !join.is_finished() && t0.elapsed() < Duration::from_secs(2) {
                std::thread::sleep(Duration::from_millis(10));
            }
            if join.is_finished() {
                let _ = join.join();
            } else {
                eprintln!("[encode] WARN: encode thread did not exit within 2s; detaching");
            }
        }
    }
}

/// Body of the dedicated encode thread: strict one-in-one-out — take a message,
/// process it fully (convert -> encode -> publish/emit), repeat. All emission
/// (last_key + broadcast send) happens on this thread in take order, so the AU
/// stream order equals frame-submission order.
fn worker_main(
    ho: Arc<Handoff>,
    tx: broadcast::Sender<Au>,
    out: Arc<EncoderOut>,
    enc_nice: Option<i32>,
) {
    // Re-nice THIS thread first, before anything else — every x264_encoder_open
    // for this encoder's lifetime runs below on this same thread, and Linux
    // threads inherit the creator's nice at clone time, so the x264 sliced
    // worker pool picks the value up transitively. setpriority(PRIO_PROCESS,
    // tid, ..) is thread-granular on Linux; done via raw syscalls to sidestep
    // the glibc `__priority_which_t` signature divergence in the libc crate.
    // Plain SCHED_OTHER either way — SCHED_RR is a documented-only further
    // step (see config.rs), NOT enabled here. Some(n) = set; None = inherit.
    if let Some(nice) = enc_nice {
        // SAFETY: no-pointer syscalls; gettid cannot fail.
        unsafe {
            let tid = libc::syscall(libc::SYS_gettid) as libc::c_long;
            let r = libc::syscall(
                libc::SYS_setpriority,
                libc::PRIO_PROCESS as libc::c_long,
                tid,
                nice as libc::c_long,
            );
            if r != 0 {
                let err = std::io::Error::last_os_error();
                eprintln!(
                    "[encode] WARN: setpriority(tid={tid}, nice={nice}) failed: {err}; encode thread keeps the inherited nice"
                );
            } else {
                eprintln!("[encode] encode thread tid={tid} re-niced to {nice} (daemon bulk keeps the service nice)");
            }
        }
    }

    // DEBUG: fine-grained per-component encode-latency profiling, gated behind
    // SH_ENC_PROFILE=1 (inert by default). Component spans are now measured ON
    // this thread, so CLOCK_THREAD_CPUTIME_ID cleanly separates real CPU from
    // wall inflation, and the new `queue` span (handoff -> dequeue) shows the
    // scheduling win directly.
    let prof = crate::config::env_flag("SH_ENC_PROFILE");

    let mut enc: Option<X264Enc> = None;
    let mut spec: Option<ReopenSpec> = None;
    // Per-open state — reset on every Reopen, like the old per-run() locals.
    let mut pts: i64 = 0;
    let mut frame_id: u32 = 0;
    let mut sps_captured = false;
    // Wall-clock keyframe heartbeat is measured from the last EMITTED IDR.
    let mut last_idr = Instant::now();
    let mut kf_dur = Duration::from_millis(1000);
    // Reused I420 plane buffers (resized only on geometry change -> re-open).
    let mut yb: Vec<u8> = Vec::new();
    let mut ub: Vec<u8> = Vec::new();
    let mut vb: Vec<u8> = Vec::new();
    let mut patch_y: Vec<u8> = Vec::new();
    let mut patch_u: Vec<u8> = Vec::new();
    let mut patch_v: Vec<u8> = Vec::new();

    // snap->AU latency window + SH_ENC_PROFILE component accumulators.
    let mut enc_ns: Vec<u128> = Vec::new();
    let mut key_n: u32 = 0; // IDRs among the current 120-frame logging window
    let mut win_t0 = Instant::now();
    let mut p_snap: Vec<u128> = Vec::new();
    let mut p_scene: Vec<u128> = Vec::new();
    let mut p_queue: Vec<u128> = Vec::new(); // handoff -> encode-thread dequeue
    let mut p_conv: Vec<u128> = Vec::new();
    let mut p_x264: Vec<u128> = Vec::new();
    let mut p_rest: Vec<u128> = Vec::new();
    let mut p_x264_cpu: Vec<u128> = Vec::new(); // THREAD CPU time for the x264 span
    let mut p_enc_cpu: Vec<u128> = Vec::new(); // THREAD CPU dequeue -> x264 end

    loop {
        let msg = ho.take();
        let deq_t = Instant::now();
        match msg {
            Msg::Ctrl(Ctrl::Shutdown) => return,
            Msg::Ctrl(Ctrl::Reopen(s)) => {
                // Close the old encoder BEFORE opening the new one (same order
                // as the old `drop(enc)` + tail-call re-entry).
                drop(enc.take());
                let mut par = match unsafe {
                    configure_param(
                        s.out_w as i32,
                        s.out_h as i32,
                        s.fps_cap,
                        s.crf,
                        s.maxrate_kbps,
                        s.bufsize_kbps,
                        &s.profile,
                        &s.preset,
                        &s.tune,
                        s.use_cqp,
                        s.threads as i32,
                    )
                } {
                    Ok(p) => p,
                    Err(e) => {
                        ho.mark_dead(format!("configure_param failed: {e:?}"));
                        return;
                    }
                };
                let h = unsafe { sys::x264_encoder_open(&mut par) };
                if h.is_null() {
                    ho.mark_dead(format!(
                        "x264_encoder_open failed ({}x{} tier {})",
                        s.out_w, s.out_h, s.tier
                    ));
                    return;
                }
                enc = Some(X264Enc(h));
                kf_dur = Duration::from_millis(s.keyframe_ms.max(100));
                pts = 0;
                frame_id = 0;
                sps_captured = false;
                last_idr = Instant::now();
                enc_ns.clear();
                key_n = 0;
                win_t0 = Instant::now();
                p_snap.clear();
                p_scene.clear();
                p_queue.clear();
                p_conv.clear();
                p_x264.clear();
                p_rest.clear();
                p_x264_cpu.clear();
                p_enc_cpu.clear();
                spec = Some(*s);
            }
            Msg::Frame(job) => {
                let (Some(enc_ref), Some(sp)) = (enc.as_ref(), spec.as_ref()) else {
                    continue; // no encoder yet — run() always reopens before feeding
                };
                let c0 = if prof { thread_cpu_ns() } else { 0 };

                // Wall-clock keyframe HEARTBEAT: force an IDR if >= keyframe_ms
                // since the last emitted IDR (replaces the old `-force_key_frames`
                // time expr). Same epoch as the old code: each frame's
                // pre-snapshot instant. duration_since saturates to zero for a
                // frame snapshotted before this (re)open.
                let mut force_idr = job.force_idr;
                if job.snap_t0.duration_since(last_idr) >= kf_dur {
                    force_idr = true;
                }

                // BGRA -> I420 (with tier-3 box-downscale when out != in), now ON
                // the encode thread: it is real per-frame work (~1.3 ms native)
                // that no longer runs on — or gets preempted with — the shared
                // tokio runtime, and the capture task only moves the snapshot Vec
                // into the slot (pointer move, no copy).
                if sp.out_w as u32 == job.w && sp.out_h as u32 == job.h {
                    for patch in &job.patches {
                        apply_bgra_patch_to_i420(
                            &patch.bgra,
                            patch.rect,
                            job.w as usize,
                            job.h as usize,
                            &mut yb,
                            &mut ub,
                            &mut vb,
                            &mut patch_y,
                            &mut patch_u,
                            &mut patch_v,
                        );
                    }
                } else if let Some(full) = job.patches.last() {
                    debug_assert_eq!(full.rect.x, 0);
                    debug_assert_eq!(full.rect.y, 0);
                    debug_assert_eq!(full.rect.w, job.w);
                    debug_assert_eq!(full.rect.h, job.h);
                    let scaled = box_downscale_bgra(
                        &full.bgra,
                        job.w as usize,
                        job.h as usize,
                        sp.out_w as usize,
                        sp.out_h as usize,
                    );
                    bgra_to_i420(
                        &scaled,
                        sp.out_w as usize,
                        sp.out_h as usize,
                        &mut yb,
                        &mut ub,
                        &mut vb,
                    );
                }
                if yb.is_empty() {
                    // The first frame after every open is required to be full;
                    // guard against a malformed/empty job instead of passing
                    // null planes into x264.
                    continue;
                }
                let cw = (sp.out_w as usize).div_ceil(2);
                let m_conv = Instant::now(); // DEBUG: end of bgra->i420 conversion
                let c_conv = if prof { thread_cpu_ns() } else { 0 };

                // Encode exactly this frame (zerolatency: this call returns THIS
                // frame's complete AU). pic_in/pic_out/nal hold raw pointers that
                // never leave this block.
                enum Step {
                    Au(Vec<u8>, bool),
                    Empty,
                    Fatal(i32),
                }
                let step = {
                    let mut pic_in: sys::x264_picture_t = unsafe { std::mem::zeroed() };
                    pic_in.img.i_csp = sys::X264_CSP_I420 as i32;
                    pic_in.img.i_plane = 3;
                    pic_in.img.i_stride[0] = sp.out_w as i32;
                    pic_in.img.i_stride[1] = cw as i32;
                    pic_in.img.i_stride[2] = cw as i32;
                    pic_in.img.plane[0] = yb.as_mut_ptr();
                    pic_in.img.plane[1] = ub.as_mut_ptr();
                    pic_in.img.plane[2] = vb.as_mut_ptr();
                    pic_in.i_pts = pts;
                    pic_in.i_type = if force_idr {
                        sys::X264_TYPE_IDR as i32
                    } else {
                        sys::X264_TYPE_AUTO as i32
                    };
                    pts += 1;

                    let mut nal_ptr: *mut sys::x264_nal_t = std::ptr::null_mut();
                    let mut nnal: std::os::raw::c_int = 0;
                    let mut pic_out: sys::x264_picture_t = unsafe { std::mem::zeroed() };
                    let fsize = unsafe {
                        sys::x264_encoder_encode(
                            enc_ref.0,
                            &mut nal_ptr,
                            &mut nnal,
                            &mut pic_in,
                            &mut pic_out,
                        )
                    };
                    if fsize < 0 {
                        Step::Fatal(fsize)
                    } else if fsize == 0 || nal_ptr.is_null() || nnal == 0 {
                        Step::Empty
                    } else {
                        // The whole Annex-B AU is contiguous: nal[0].p_payload .. +fsize.
                        let bytes = unsafe {
                            std::slice::from_raw_parts(
                                (*nal_ptr).p_payload as *const u8,
                                fsize as usize,
                            )
                        }
                        .to_vec();
                        Step::Au(bytes, pic_out.b_keyframe != 0)
                    }
                };
                let m_x264 = Instant::now(); // DEBUG: end of x264_encoder_encode + AU copy
                let c_x264 = if prof { thread_cpu_ns() } else { 0 };

                let (au_bytes, is_key) = match step {
                    Step::Fatal(code) => {
                        eprintln!("[encode] x264_encoder_encode error {code}");
                        ho.mark_dead(format!("x264_encoder_encode error {code}"));
                        return;
                    }
                    Step::Empty => continue, // no output (should not happen at zerolatency)
                    Step::Au(bytes, key) => (bytes, key),
                };

                // On the first IDR after (re)open, extract the SPS profile/level_idc
                // and republish so the codec string over the wire
                // (avc1.<profile><cc><level>) is authoritative from the emitted
                // bitstream, not the fallback table.
                if is_key && !sps_captured {
                    if let Some((pidc, lidc)) = extract_sps_profile_level(&au_bytes) {
                        out.publish(
                            sp.tier,
                            sp.maxrate_kbps,
                            sp.crf,
                            sp.out_w,
                            sp.out_h,
                            sp.native_w,
                            sp.native_h,
                            sp.fps_cap.min(u16::MAX as u32) as u16,
                            sp.keyframe_ms.min(u16::MAX as u64) as u16,
                            pidc,
                            lidc,
                            preset_enum(&sp.preset),
                        );
                        sps_captured = true;
                        eprintln!("[encode] SPS profile_idc={} level_idc=0x{:02x} -> codec avc1.{:02x}{:02x}{:02x}", pidc, lidc, pidc, 0, lidc);
                    }
                }

                let au = Au {
                    data: Arc::new(au_bytes),
                    is_key,
                    capture_ts_us: job.cap_ts_us,
                    frame_id,
                };
                if is_key {
                    // blocking_lock is legal here: this is a plain OS thread,
                    // never a tokio runtime worker.
                    *out.last_key.blocking_lock() = Some(au.clone());
                    key_n += 1;
                    last_idr = job.snap_t0;
                }
                let _ = tx.send(au);
                frame_id = frame_id.wrapping_add(1);

                // server-side encode latency: snapshot -> AU ready. Includes the
                // handoff queue wait, so the number stays comparable with the old
                // synchronous snap->AU metric (downstream tooling parses this line).
                let now_end = Instant::now();
                enc_ns.push(now_end.duration_since(job.snap_t0).as_nanos());
                if prof {
                    p_snap.push(job.prof_snap_ns);
                    p_scene.push(job.prof_scene_ns);
                    p_queue.push(deq_t.duration_since(job.handoff_t).as_nanos());
                    p_conv.push(m_conv.duration_since(deq_t).as_nanos());
                    p_x264.push(m_x264.duration_since(m_conv).as_nanos());
                    p_rest.push(now_end.duration_since(m_x264).as_nanos());
                    p_x264_cpu.push(c_x264.saturating_sub(c_conv));
                    p_enc_cpu.push(c_x264.saturating_sub(c0));
                }
                if enc_ns.len() >= 120 {
                    enc_ns.sort_unstable();
                    let n = enc_ns.len();
                    let win_s = win_t0.elapsed().as_secs_f64().max(0.001);
                    eprintln!(
                        "[encode] enc latency (snap->AU) us: p50={} p95={} max={} n={} | {:.1} idr/s ({} idr / {:.1}s) {:.1} fps",
                        enc_ns[n / 2] / 1000,
                        enc_ns[n * 95 / 100] / 1000,
                        enc_ns[n - 1] / 1000,
                        n,
                        key_n as f64 / win_s,
                        key_n,
                        win_s,
                        n as f64 / win_s,
                    );
                    if prof {
                        let p50 = |v: &mut Vec<u128>| {
                            v.sort_unstable();
                            let l = v.len().max(1);
                            v.get(l / 2).copied().unwrap_or(0) / 1000
                        };
                        let p95 = |v: &Vec<u128>| {
                            let l = v.len().max(1);
                            v.get(l * 95 / 100).copied().unwrap_or(0) / 1000
                        };
                        eprintln!(
                            "[encode] PROFILE us p50(p95): snapshot={}({}) scene={}({}) queue={}({}) conv={}({}) x264={}({}) rest={}({}) | coalesced={}",
                            p50(&mut p_snap), p95(&p_snap),
                            p50(&mut p_scene), p95(&p_scene),
                            p50(&mut p_queue), p95(&p_queue),
                            p50(&mut p_conv), p95(&p_conv),
                            p50(&mut p_x264), p95(&p_x264),
                            p50(&mut p_rest), p95(&p_rest),
                            ho.take_coalesced(),
                        );
                        eprintln!(
                            "[encode] PROFILE cpu-vs-wall us p50(p95): x264_cpu={}({}) x264_wall={}({}) | enc-thread cpu={}({})",
                            p50(&mut p_x264_cpu), p95(&p_x264_cpu),
                            p50(&mut p_x264), p95(&p_x264),
                            p50(&mut p_enc_cpu), p95(&p_enc_cpu),
                        );
                        p_snap.clear();
                        p_scene.clear();
                        p_queue.clear();
                        p_conv.clear();
                        p_x264.clear();
                        p_rest.clear();
                        p_x264_cpu.clear();
                        p_enc_cpu.clear();
                    }
                    enc_ns.clear();
                    key_n = 0;
                    win_t0 = Instant::now();
                }
            }
        }
    }
}
