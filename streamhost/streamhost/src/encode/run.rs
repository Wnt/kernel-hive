// The capture->encode driver loop: waits on guest damage / heartbeat / connect
// kick / ABR reconfig, applies receiver-gated feed decisions, snapshots the
// framebuffer, runs the content scene detector, and hands frames to the dedicated
// encode thread. Extracted verbatim from encode/mod.rs (the `encode::run`
// god-loop). Pipeline overview + the handoff equivalence argument live in
// encode/mod.rs and handoff.rs.

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::broadcast;

use crate::capture::Capture;

use super::handoff::{BgraPatch, FrameJob, ReopenSpec};
use super::params::{
    effective_bufsize_ratio, preset_enum, profile_idc_of, resolve_fps, resolve_threads,
    resolve_tier,
};
use super::scene::{should_feed, update_scene_samples};
use super::worker::EncodeWorker;
use super::{Au, EncodeParams, EncoderOut};

/// Monotonic milliseconds since process start (for restart cooldowns; atomics
/// can't hold an Instant).
fn mono_ms() -> u64 {
    static T0: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    T0.get_or_init(Instant::now).elapsed().as_millis() as u64
}

pub(super) async fn run(
    cap: Capture,
    tx: broadcast::Sender<Au>,
    out: Arc<EncoderOut>,
    fps_cap: u32,
    keyframe_ms: u64,
    params: EncodeParams,
) -> anyhow::Result<()> {
    // Wait for the first real frame to learn geometry.
    let (mut w, mut h) = loop {
        {
            let s = cap.state.lock().unwrap();
            if s.width > 0 && s.height > 0 {
                break (s.width, s.height);
            }
            if s.fb_w > 0 && s.fb_h > 0 {
                break (s.fb_w, s.fb_h);
            }
        }
        cap.damage.notified().await;
    };

    // One dedicated encode thread for the whole encoder lifetime; tier/geometry
    // changes re-open the encoder ON that thread via control messages. Joined
    // (bounded) when run() exits.
    let worker = EncodeWorker::spawn(tx.clone(), out.clone(), params.enc_nice)?;

    let min_interval = Duration::from_micros(1_000_000 / fps_cap as u64);
    // Heartbeat feed cadence WHILE WATCHED (see history): half the keyframe period,
    // clamped to [100ms, 500ms].
    let feed_hb = Duration::from_millis((keyframe_ms / 2).clamp(100, 500));
    // Rate-cap epoch: last frame FED to the encode thread (the old code used the
    // post-encode emit instant; feed spacing is what the cap is for).
    let mut last_feed = Instant::now() - min_interval;
    let prof = crate::config::env_flag("SH_ENC_PROFILE");

    // Each 'open iteration = one encoder lifetime. Re-entered on ABR tier change
    // and mid-stream geometry change, with fresh per-open detector state —
    // mirroring the old tail-call re-entry of run().
    'open: loop {
        // Resolve the active ABR tier (SECTION 2.5) into concrete encode params.
        let tier = out.tier.load(Ordering::Relaxed);
        let (out_w, out_h, crf, maxrate_kbps) = resolve_tier(w as u16, h as u16, tier, &params);
        // L-2: per-tier fps (default = native at all tiers). Recomputed each open so
        // an ABR tier change re-opens with the tier's fps, and the feed rate-cap
        // below actually throttles to it. The x264 i_fps_num (VBV timing) tracks it
        // via ReopenSpec.fps_cap -> configure_param.
        let tier_fps = resolve_fps(tier, fps_cap, &params);
        let min_interval = Duration::from_micros(1_000_000 / tier_fps.max(1) as u64);
        // L-4: under sustained downshift, lengthen the keyframe heartbeat at congested
        // tiers (>= 2) so the periodic IDR doesn't repeatedly flood a bufferbloated WAN
        // queue. Default-off => unchanged at every tier; LAN stays tier 0 (inert).
        let tier_keyframe_ms = if params.abr_idr_backoff && tier >= 2 {
            keyframe_ms.saturating_mul(2)
        } else {
            keyframe_ms
        };
        let use_cqp = tier == 0;
        let threads = resolve_threads(params.threads);
        // B3: congested tiers get at most 0.5 x maxrate of VBV burst budget
        // (see effective_bufsize_ratio); tier 0 is CQP so this is LAN-inert.
        let bufsize_kbps = (((maxrate_kbps as f64)
            * effective_bufsize_ratio(tier, params.bufsize_ratio))
        .round() as u32)
            .max(200);
        eprintln!(
            "[encode] geometry {}x{} tier={} -> out {}x{} crf={} maxrate={}k preset={} profile={} threads={}(sliced) -> in-process libx264 (dedicated encode thread)",
            w, h, tier, out_w, out_h, crf, maxrate_kbps, params.preset, params.profile, threads
        );

        // Publish params at launch (level_idc filled once the first SPS is parsed).
        out.publish(
            tier,
            maxrate_kbps,
            crf,
            out_w,
            out_h,
            w as u16,
            h as u16,
            tier_fps.min(u16::MAX as u32) as u16,
            tier_keyframe_ms.min(u16::MAX as u64) as u16,
            profile_idc_of(&params.profile),
            out.cur_level_idc.load(Ordering::Relaxed),
            preset_enum(&params.preset),
        );

        // (Re)open the x264 encoder ON the encode thread. The fresh libx264
        // always emits SPS+PPS+IDR first, so the existing is_key -> last_key path
        // repopulates the cache and every client re-syncs — same semantics as the
        // old child restart / tail-call re-open.
        worker.reopen(ReopenSpec {
            tier,
            out_w,
            out_h,
            native_w: w as u16,
            native_h: h as u16,
            crf,
            maxrate_kbps,
            bufsize_kbps,
            use_cqp,
            threads,
            fps_cap: tier_fps,
            keyframe_ms: tier_keyframe_ms,
            preset: params.preset.clone(),
            profile: params.profile.clone(),
            tune: params.tune.clone(),
        });

        // Per-open state: the last_gen sentinel forces an immediate first feed
        // (the fresh encoder needs a frame to emit its IDR), and the scene-change
        // detector state resets like the old per-run() locals.
        let mut last_gen: u64 = u64::MAX;
        let last_reconfig = out.reconfig_gen.load(Ordering::Relaxed);
        // KEYFRAME-ON-CONNECT (join fix, 2026-07-11): last key_req value that has
        // been ANSWERED with a forced IDR. On a busy station (constant damage) the
        // wake loop below always breaks out via `damaged` before it ever reports
        // `kicked`, so a joiner's request_keyframe() used to produce NO keyframe
        // at all — the client sat on a stale primed key + broken-reference deltas
        // until the wall-clock heartbeat (<= keyframe_ms, measured 1.5 s on
        // freedos). Checking the counter at the FEED site (not the wake site)
        // guarantees the next encoded frame after any join is an IDR. Fresh-open
        // value is answered by the open IDR itself.
        let mut answered_key_req = out.key_req.load(Ordering::Relaxed);
        // Scene-change detector state: every-8th-pixel samples of the PREVIOUS
        // captured frame (see the detector comment at the snapshot site).
        let mut prev_samples: Vec<u32> = Vec::new();
        // Frames fed since this (re)open — guards the detector off the encoder's
        // own opening frame (the old code used frame_id>0 for the same purpose).
        let mut fed: u64 = 0;

        loop {
            // Wait for one of: guest damage, a new-client keyframe request, an ABR
            // reconfig, or a heartbeat tick.
            //
            // POLL CADENCE (idle-CPU fix, 2026-07-12): WHILE WATCHED the inner
            // wait still polls every 2 ms (no damage Notify missed, ABR reconfig
            // within ~2 ms, encode-thread death surfaces fast). UNWATCHED it
            // widens to 50 ms — the old always-2 ms poll cost ~500 wakeups/s per
            // station 24/7 (~1.2% of a core each, plus sys% across 28 daemons).
            // Connects do NOT pay the 50 ms: request_keyframe() pulses
            // `out.wake` (permit-storing notify_one), which the select below
            // completes on immediately.
            let start_req = out.key_req.load(Ordering::Relaxed);
            let watched = tx.receiver_count() > 0;
            let tick = if watched {
                feed_hb
            } else {
                Duration::from_millis(250)
            };
            let wait_t0 = Instant::now();
            let mut waited = Duration::ZERO;
            let mut damaged = false;
            let mut kicked = false;
            let mut reconfig = false;
            loop {
                if let Some(err) = worker.dead() {
                    anyhow::bail!("encode thread died: {err}");
                }
                let g = { cap.state.lock().unwrap().gen };
                if g != last_gen {
                    last_gen = g;
                    damaged = true;
                    break;
                }
                if out.key_req.load(Ordering::Relaxed) != start_req {
                    kicked = true; // a client just connected -> prime a frame now
                    break;
                }
                if out.reconfig_gen.load(Ordering::Relaxed) != last_reconfig {
                    reconfig = true; // ABR tier change -> re-open the encoder now
                    break;
                }
                let poll = if tx.receiver_count() > 0 {
                    Duration::from_millis(2)
                } else {
                    Duration::from_millis(50)
                };
                let _ = tokio::time::timeout(poll, async {
                    tokio::select! {
                        _ = cap.damage.notified() => {}
                        _ = out.wake.notified() => {}
                    }
                })
                .await;
                waited = wait_t0.elapsed();
                if waited >= tick {
                    break;
                }
            }

            // An ABR reconfig re-opens the encoder with the new tier (control
            // message to the encode thread; ordering notes at Handoff).
            if reconfig {
                eprintln!(
                    "[encode] ABR reconfig (tier {} -> {}), re-opening encoder",
                    tier,
                    out.tier.load(Ordering::Relaxed)
                );
                continue 'open;
            }

            // Decide whether this wakeup actually produces a frame (see
            // should_feed): connect kicks always do; damage and heartbeat ticks
            // only feed while at least one receiver exists. With zero receivers
            // even an animated guest costs a few atomic loads per damage event —
            // never a snapshot or an encode.
            let watched_now = tx.receiver_count() > 0;
            let hb_due = waited >= tick;
            if !should_feed(damaged, kicked, watched_now, hb_due) {
                continue; // nobody watching / nothing due -> stay dark (idle ~0 CPU)
            }

            // Rate-cap the feed (coalesce bursts; isolated events are never
            // delayed since the previous feed is long past).
            let since = last_feed.elapsed();
            if since < min_interval {
                tokio::time::sleep(min_interval - since).await;
            }
            let snap_t0 = Instant::now();

            // Snapshot the current frame: a copy out of the QEMU shm map under the
            // capture lock. Stays on THIS side — the encode thread never touches
            // capture state, and this task never blocks on the encode thread, so a
            // slow encode can never backpressure the dbus-display listener.
            let pending_key_req = out.key_req.load(Ordering::Relaxed);
            let force_full_snapshot = fed == 0 || pending_key_req != answered_key_req;
            // Downscaled ABR tier 3 still uses the established full-frame box
            // scaler. Native tiers use the damage path when enabled.
            let damage_conv = params.damage_conv && out_w as u32 == w && out_h as u32 == h;
            let frame = {
                let mut s = cap.state.lock().unwrap();
                s.snapshot_damage_bgra(damage_conv, params.damage_full_pct, force_full_snapshot)
            };
            let Some(snapshot) = frame else {
                continue;
            };
            last_gen = snapshot.generation;
            let (fw, fh) = (snapshot.width, snapshot.height);
            if fw != w || fh != h {
                // geometry changed mid-stream (mode switch): re-open encoder
                eprintln!(
                    "[encode] geometry changed {}x{} -> {}x{}, re-opening",
                    w, h, fw, fh
                );
                w = fw;
                h = fh;
                continue 'open;
            }
            let patches = snapshot
                .rect
                .map(|rect| {
                    vec![BgraPatch {
                        rect,
                        bgra: snapshot.bgra,
                    }]
                })
                .unwrap_or_default();
            let m_snap = Instant::now(); // DEBUG: end of snapshot+geometry

            // SCENE-CHANGE detector -> forced IDR, by CONTENT not damage metadata. A
            // desktop/backdrop switch or boot splash changes >= ~70% of actual pixels;
            // typing/menus/window-resize steps change a few percent. (History: an
            // accumulated damage-AREA detector storm-re-keyed every ~1.7 s during a
            // steady resize drag; a largest-single-RECT detector still stormed on
            // win2000/winxp/qnx whose display drivers blit the WHOLE framebuffer for
            // any update — QEMU reports 100% rects for a keystroke. Only comparing
            // sampled pixel content is driver-agnostic.) Sampling every 8th pixel in x
            // and y (~36k words at 1920x1200) costs tens of microseconds per frame.
            // x264's own scenecut is OFF (i_scenecut_threshold=0), so the daemon does
            // the detection; forcing pic_in.i_type=IDR on this frame (repeat-headers
            // => SPS+PPS+IDR) re-syncs every client via the is_key -> last_key path.
            // Rising edge + 3 s cooldown: sustained full-screen animation fires once
            // at onset, not per frame; fed>0 guards the encoder's own opening frame.
            // The wall-clock keyframe HEARTBEAT check lives on the encode thread
            // (worker_main), which knows when IDRs are actually emitted.
            let changed_frac =
                update_scene_samples(&patches, fw as usize, fh as usize, &mut prev_samples);
            let full_now = changed_frac >= 0.70;
            let prev_full = out.dmg_prev_full.swap(full_now, Ordering::Relaxed);
            let mut force_idr = false;
            // L-4: suppress the scene-change IDR at congested tiers (>= 2) when the
            // backoff is armed — the join/backlog-resume IDRs still fire, so the
            // stream stays decodable; this only drops the extra content-driven burst.
            let scene_idr_ok = !(params.abr_idr_backoff && tier >= 2);
            if fed > 0 && full_now && !prev_full && scene_idr_ok {
                let now_ms = mono_ms();
                let last = out.dmg_last_restart_ms.load(Ordering::Relaxed);
                if now_ms.saturating_sub(last) >= 3000 {
                    out.dmg_last_restart_ms.store(now_ms, Ordering::Relaxed);
                    eprintln!(
                        "[encode] scene change ({:.0}% of sampled pixels) -> forced IDR",
                        changed_frac * 100.0
                    );
                    force_idr = true;
                }
            }

            // KEYFRAME-ON-CONNECT: answer any key_req advance since the last fed
            // frame by forcing THIS frame to be an IDR (sticky through a Handoff
            // replace, so a join's keyframe can never be coalesced away).
            let kr = pending_key_req;
            if kr != answered_key_req {
                answered_key_req = kr;
                force_idr = true;
            }

            // shared A/V clock (same epoch audio Opus packets are stamped from)
            let cap_ts = crate::clock::now_us();
            let m_scene = Instant::now(); // DEBUG: end of scene-change detector

            // Hand the frame to the encode thread. NEVER blocks this task: a still-
            // pending frame is replaced (its force-IDR flag merged) — see Handoff.
            worker.submit_frame(FrameJob {
                patches,
                w: fw,
                h: fh,
                force_idr,
                cap_ts_us: cap_ts,
                snap_t0,
                handoff_t: snap_t0, // overwritten in submit_frame
                prof_snap_ns: if prof {
                    m_snap.duration_since(snap_t0).as_nanos()
                } else {
                    0
                },
                prof_scene_ns: if prof {
                    m_scene.duration_since(m_snap).as_nanos()
                } else {
                    0
                },
            });
            fed += 1;
            last_feed = Instant::now();
        }
    }
}
