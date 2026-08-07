// Dedicated-encode-thread handoff plumbing, extracted verbatim from the old
// monolithic encode.rs. The design/equivalence argument lives in the comment
// block below; the pipeline overview is in encode/mod.rs.

use std::sync::{Arc, Condvar, Mutex as StdMutex};
use std::time::Instant;

use crate::capture::DamageRect;

// ---------------------------------------------------------------------------
// Dedicated encode thread — handoff plumbing
//
//   capture/run() [tokio task]                encode thread [std::thread]
//   ── damage/heartbeat/kick gating           ── blocks in Handoff::take()
//   ── snapshot_bgra + scene detector    ──►  ── (re)open encoder on Ctrl
//   ── Handoff::submit_frame: NEVER           ── BGRA->I420 (+tier-3 downscale)
//      blocks; REPLACES a pending frame,      ── x264_encoder_encode
//      MERGING its sticky force-IDR flag      ── SPS publish, last_key, tx.send
//
// LATEST-WINS EQUIVALENCE: the old synchronous loop could not observe damage
// while inside x264_encoder_encode; when it returned to its poll it snapshotted
// the NEWEST framebuffer, silently coalescing every intermediate update. With
// damage-scoped snapshots, each consumed rectangle must survive until applied
// to persistent I420, so the depth-1 slot merges pending patches oldest-first;
// a newer full-frame patch subsumes them all. Forced-IDR is sticky across the
// same replacement. Thus one queued job still represents the newest complete
// framebuffer state without losing damage or reordering AUs.
//
// ORDERING: submission is single-producer (one run() task) and the worker is
// one-in-one-out, taking a message and fully processing it (convert -> encode ->
// emit) before the next take, so AUs are emitted in exactly frame-submission
// order. Encoder REOPEN (ABR tier / geometry change) is a control message that
// outranks a pending frame: the in-flight frame finishes and is emitted first,
// a never-started pending frame is dropped (the fresh encoder's SPS+PPS+IDR
// supersedes it — run() always feeds a frame immediately after a reopen), then
// the old handle is closed and the new one opened ON this thread. Fatal x264
// errors, open failures and panics mark the handoff dead; run() polls that flag
// in its 2 ms wait loop and exits with an error instead of stalling silently.
// ---------------------------------------------------------------------------

/// Everything the encode thread needs to (re)open the x264 encoder and publish
/// authoritative params once the first SPS is seen. Built by run() at every
/// (re)open from resolve_tier() + the static EncodeParams.
pub(super) struct ReopenSpec {
    pub(super) tier: u8,
    pub(super) out_w: u16,
    pub(super) out_h: u16,
    pub(super) native_w: u16,
    pub(super) native_h: u16,
    pub(super) crf: u8,
    pub(super) maxrate_kbps: u32,
    pub(super) bufsize_kbps: u32,
    pub(super) use_cqp: bool,
    pub(super) threads: u32,
    pub(super) fps_cap: u32,
    pub(super) keyframe_ms: u64,
    pub(super) preset: String,
    pub(super) profile: String,
    pub(super) tune: String,
}

pub(super) struct BgraPatch {
    pub(super) rect: DamageRect,
    pub(super) bgra: Vec<u8>,
}

/// One captured frame handed to the encode thread. `force_idr` is STICKY: if
/// this job is replaced in the slot before the encoder picks it up, the flag is
/// merged onto the replacement (an IDR request must never be lost). Pixel
/// patches are merged oldest-first as well, so coalescing cannot discard damage
/// that was already consumed from FrameState but not yet applied to I420.
pub(super) struct FrameJob {
    pub(super) patches: Vec<BgraPatch>,
    pub(super) w: u32,
    pub(super) h: u32,
    pub(super) force_idr: bool,
    pub(super) cap_ts_us: u32,
    /// Taken just before snapshot_bgra — the epoch of the snap->AU latency stat
    /// (same instant the old synchronous code called `enc_t0`).
    pub(super) snap_t0: Instant,
    /// Stamped by submit_frame — SH_ENC_PROFILE queue-wait (handoff -> dequeue).
    pub(super) handoff_t: Instant,
    // SH_ENC_PROFILE component spans measured on the capture side (0 when off).
    pub(super) prof_snap_ns: u128,
    pub(super) prof_scene_ns: u128,
}

pub(super) enum Ctrl {
    Reopen(Box<ReopenSpec>),
    Shutdown,
}

pub(super) enum Msg {
    Ctrl(Ctrl),
    Frame(FrameJob),
}

#[derive(Default)]
pub(super) struct HandoffShared {
    frame: Option<FrameJob>,
    ctrl: Option<Ctrl>,
    /// frames superseded in the slot before encode started (latest-wins)
    coalesced: u64,
    /// set once if the encode thread exits abnormally (error / panic)
    dead: Option<String>,
}

/// Bounded (depth-1, latest-wins) frame slot + control channel between the
/// async capture loop and the dedicated encode thread. submit_* never block
/// beyond the short mutex; take() blocks the encode thread on the condvar while
/// idle (no spin/poll — zero CPU between frames).
pub(super) struct Handoff {
    m: StdMutex<HandoffShared>,
    cv: Condvar,
}

impl Handoff {
    pub(super) fn new() -> Arc<Self> {
        Arc::new(Handoff {
            m: StdMutex::new(HandoffShared::default()),
            cv: Condvar::new(),
        })
    }

    /// Latest-wins REPLACE with sticky-flag MERGE (see module notes above): a
    /// pending never-started frame is superseded, but its force-IDR request
    /// carries onto the replacement. Never blocks the submitting task.
    pub(super) fn submit_frame(&self, mut job: FrameJob) {
        job.handoff_t = Instant::now();
        let mut s = self.m.lock().unwrap();
        if let Some(mut old) = s.frame.take() {
            job.force_idr |= old.force_idr;
            let new_is_full = job.patches.len() == 1
                && job.patches[0].rect.x == 0
                && job.patches[0].rect.y == 0
                && job.patches[0].rect.w == job.w
                && job.patches[0].rect.h == job.h;
            if !new_is_full {
                old.patches.append(&mut job.patches);
                job.patches = old.patches;
            }
            s.coalesced += 1;
        }
        // A normally-draining depth-1 slot holds one or two small bboxes. If
        // x264 ever stalls indefinitely, merging already-consumed damage must
        // not turn that slot into an unbounded allocation. Freeze the stream
        // safely (run() observes `dead` and tears the worker down) instead of
        // dropping a patch and emitting a visually corrupt reference frame.
        let pending_bytes: usize = job.patches.iter().map(|p| p.bgra.len()).sum();
        let max_pending = (job.w as usize)
            .saturating_mul(job.h as usize)
            .saturating_mul(16);
        if pending_bytes > max_pending {
            if s.dead.is_none() {
                s.dead = Some(format!(
                    "damage patch backlog exceeded {} bytes (limit {})",
                    pending_bytes, max_pending
                ));
            }
            drop(s);
            self.cv.notify_one();
            return;
        }
        s.frame = Some(job);
        drop(s);
        self.cv.notify_one();
    }

    /// Queue a re-open (processed on the encode thread, after any in-flight
    /// frame completes). Drops a pending frame: it was captured for the previous
    /// tier/geometry and the fresh encoder's SPS+PPS+IDR supersedes it — run()
    /// feeds a new frame immediately after every reopen (last_gen sentinel), so
    /// no IDR request is lost. A queued Shutdown always outranks a Reopen.
    pub(super) fn submit_reopen(&self, spec: ReopenSpec) {
        let mut s = self.m.lock().unwrap();
        if !matches!(s.ctrl, Some(Ctrl::Shutdown)) {
            s.ctrl = Some(Ctrl::Reopen(Box::new(spec)));
        }
        s.frame = None;
        drop(s);
        self.cv.notify_one();
    }

    pub(super) fn submit_shutdown(&self) {
        let mut s = self.m.lock().unwrap();
        s.ctrl = Some(Ctrl::Shutdown);
        s.frame = None;
        drop(s);
        self.cv.notify_one();
    }

    /// Encode-thread receive: control first (a reopen/shutdown outranks a
    /// not-yet-started frame), else the pending frame, else BLOCK.
    pub(super) fn take(&self) -> Msg {
        let mut s = self.m.lock().unwrap();
        loop {
            if let Some(c) = s.ctrl.take() {
                return Msg::Ctrl(c);
            }
            if let Some(f) = s.frame.take() {
                return Msg::Frame(f);
            }
            s = self.cv.wait(s).unwrap();
        }
    }

    /// Non-blocking take, for the pure-logic handoff tests only.
    #[cfg(test)]
    fn try_take(&self) -> Option<Msg> {
        let mut s = self.m.lock().unwrap();
        if let Some(c) = s.ctrl.take() {
            return Some(Msg::Ctrl(c));
        }
        s.frame.take().map(Msg::Frame)
    }

    /// Frames coalesced (superseded in the slot) since the last call.
    pub(super) fn take_coalesced(&self) -> u64 {
        std::mem::take(&mut self.m.lock().unwrap().coalesced)
    }

    pub(super) fn mark_dead(&self, why: String) {
        let mut s = self.m.lock().unwrap();
        if s.dead.is_none() {
            s.dead = Some(why);
        }
    }

    pub(super) fn dead(&self) -> Option<String> {
        self.m.lock().unwrap().dead.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // ---- dedicated-encode-thread handoff: PURE-LOGIC tests (no x264 opened) ----

    fn mk_job(tag: u8, force_idr: bool) -> FrameJob {
        FrameJob {
            patches: vec![BgraPatch {
                rect: DamageRect {
                    x: tag as u32,
                    y: 0,
                    w: 1,
                    h: 1,
                },
                bgra: vec![tag; 4],
            }],
            w: 1,
            h: 1,
            force_idr,
            cap_ts_us: tag as u32,
            snap_t0: Instant::now(),
            handoff_t: Instant::now(),
            prof_snap_ns: 0,
            prof_scene_ns: 0,
        }
    }

    fn mk_spec(tier: u8) -> ReopenSpec {
        ReopenSpec {
            tier,
            out_w: 64,
            out_h: 64,
            native_w: 64,
            native_h: 64,
            crf: 23,
            maxrate_kbps: 0,
            bufsize_kbps: 0,
            use_cqp: tier == 0,
            threads: 1,
            fps_cap: 60,
            keyframe_ms: 1000,
            preset: "veryfast".into(),
            profile: "high".into(),
            tune: "zerolatency".into(),
        }
    }

    // Latest-wins REPLACE with sticky force-IDR merge: a superseded pending frame
    // must never lose its IDR request, and the merged flag must not leak onto
    // frames submitted after the merged one was consumed.
    #[test]
    fn handoff_latest_wins_merges_sticky_idr() {
        let ho = Handoff::new();
        ho.submit_frame(mk_job(1, true)); // IDR requested…
        ho.submit_frame(mk_job(2, false)); // …then the frame is superseded
        match ho.try_take() {
            Some(Msg::Frame(j)) => {
                assert_eq!(
                    j.patches.iter().map(|p| p.bgra[0]).collect::<Vec<_>>(),
                    vec![1, 2],
                    "consumed damage must survive in oldest-first order"
                );
                assert!(j.force_idr, "superseded frame's force-IDR must carry over");
            }
            _ => panic!("expected the coalesced frame"),
        }
        assert_eq!(ho.take_coalesced(), 1, "exactly one frame was coalesced");
        // A later frame must NOT inherit the already-consumed IDR flag.
        ho.submit_frame(mk_job(3, false));
        match ho.try_take() {
            Some(Msg::Frame(j)) => assert!(!j.force_idr, "IDR flag must not leak forward"),
            _ => panic!("expected frame 3"),
        }
        assert!(
            ho.try_take().is_none(),
            "slot must be empty (one-in-one-out)"
        );
    }

    // FIFO one-in-one-out when the consumer keeps up: in order, nothing coalesced.
    #[test]
    fn handoff_fifo_when_drained() {
        let ho = Handoff::new();
        for tag in 1..=3u8 {
            ho.submit_frame(mk_job(tag, false));
            match ho.try_take() {
                Some(Msg::Frame(j)) => {
                    assert_eq!(
                        j.patches[0].bgra[0], tag,
                        "frames must come out in submit order"
                    )
                }
                _ => panic!("expected frame {tag}"),
            }
        }
        assert_eq!(ho.take_coalesced(), 0, "nothing coalesced when drained");
    }

    // Control outranks a not-yet-started frame, and a reopen drops the pending
    // frame (its IDR intent is subsumed by the fresh encoder's SPS+PPS+IDR),
    // while a frame submitted AFTER the reopen is delivered after it.
    #[test]
    fn handoff_reopen_outranks_and_drops_pending_frame() {
        let ho = Handoff::new();
        ho.submit_frame(mk_job(1, true)); // captured for the OLD tier/geometry
        ho.submit_reopen(mk_spec(1));
        ho.submit_frame(mk_job(2, false)); // captured after the reopen request
        match ho.try_take() {
            Some(Msg::Ctrl(Ctrl::Reopen(s))) => assert_eq!(s.tier, 1, "reopen first"),
            _ => panic!("expected the reopen control before any frame"),
        }
        match ho.try_take() {
            Some(Msg::Frame(j)) => {
                assert_eq!(
                    j.patches[0].bgra[0], 2,
                    "only the post-reopen frame survives"
                )
            }
            _ => panic!("expected the post-reopen frame"),
        }
        assert!(ho.try_take().is_none());
    }

    // Shutdown overrides a queued reopen and clears any pending frame.
    #[test]
    fn handoff_shutdown_overrides_reopen() {
        let ho = Handoff::new();
        ho.submit_reopen(mk_spec(2));
        ho.submit_frame(mk_job(1, false));
        ho.submit_shutdown();
        match ho.try_take() {
            Some(Msg::Ctrl(Ctrl::Shutdown)) => {}
            _ => panic!("expected shutdown to win the control slot"),
        }
        assert!(ho.try_take().is_none(), "shutdown clears pending frames");
    }

    // The dead flag is first-error-wins and readable from the async side.
    #[test]
    fn handoff_dead_flag_first_error_wins() {
        let ho = Handoff::new();
        assert!(ho.dead().is_none());
        ho.mark_dead("x264_encoder_encode error -1".into());
        ho.mark_dead("second error must not overwrite".into());
        assert_eq!(ho.dead().as_deref(), Some("x264_encoder_encode error -1"));
    }
}
