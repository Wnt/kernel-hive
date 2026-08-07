// Static/ABR parameter resolution for the encode pipeline: preset/profile enum
// mapping for the wire, the per-resolution tier-0 maxrate table, ladder-tier
// resolution, and the sliced-thread count. Pure functions extracted verbatim
// from encode/mod.rs; pipeline overview lives there.

use super::EncodeParams;

/// x264 preset enum for the wire (0=ultrafast .. 8=veryslow).
pub(super) fn preset_enum(p: &str) -> u8 {
    match p {
        "ultrafast" => 0,
        "superfast" => 1,
        "veryfast" => 2,
        "faster" => 3,
        "fast" => 4,
        "medium" => 5,
        "slow" => 6,
        "slower" => 7,
        "veryslow" => 8,
        _ => 2,
    }
}

/// H.264 profile_idc for the wire (66=baseline, 77=main, 100=high).
pub(super) fn profile_idc_of(p: &str) -> u8 {
    match p {
        "baseline" => 66,
        "main" => 77,
        _ => 100,
    }
}

/// Per-resolution DEFAULT tier-0 maxrate (kbps) — the VBV PEAK cap. Auto rule:
/// pick the smallest row whose area >= tile area; else area * 0.030.
///
/// These caps are GENEROUS on purpose: the cap is the ceiling the CRF quality
/// target is allowed to spend up to, and a LOW cap silently re-introduces the
/// artefacts the low default CRF (10, see config.rs) is meant to remove — the
/// encoder wants a big, near-lossless KEYFRAME for a busy static desktop
/// (e.g. the Solaris CDE stipple), and if the cap throttles it the frame blocks
/// up. The gallery is a LAN (gigabit+), so ~3x the old caps is free; on a real
/// WAN link the ABR ladder scales these down on sustained congestion.
fn auto_maxrate_kbps(w: u32, h: u32) -> u32 {
    let area = (w as u64) * (h as u64);
    match area {
        a if a <= 307_200 => 12000,                  // 640x480   L3.1
        a if a <= 480_000 => 16000,                  // 800x600   L3.2
        a if a <= 786_432 => 24000,                  // 1024x768  L4.0
        a if a <= 1_049_088 => 36000,                // ~1MP / 1366x768 / 720x1440 portrait
        a if a <= 2_073_600 => 60000,                // 1920x1080
        _ => ((area as f64) * 0.030).round() as u32, // e.g. 1920x1200 -> ~69 Mbps
    }
}

/// Resolve a ladder tier (SECTION 2.1) against the tile's native geometry and the
/// static params. Returns (effective_w, effective_h, crf, maxrate_kbps).
/// Tier 3 always steps resolution down (>=floor, 16-aligned); tiers 0-1 keep native;
/// tier 2 steps only when the L-3 res ladder is enabled (SH_ABR_RES_LADDER).
///
/// WAN BURST CAPS (B3, 2026-07-17): tiers >= 1 exist ONLY under sustained
/// congestion, yet a big tile's scaled maxrate stayed LAN-sized (1920x1200:
/// tier-2 0.35x base = 24.2 Mbps) — every ~2.5 s heartbeat IDR flooded the
/// bufferbloated 5G queue in one burst (FZ episodes, RTT spikes). Congested
/// tiers are therefore additionally clamped to WAN-plausible ceilings:
/// T1 12 Mbps, T2 8 Mbps, T3 5 Mbps. Tier 0 keeps the GENEROUS per-resolution
/// table untouched — LAN sessions never leave tier 0, so the design intent of
/// the big caps (near-lossless busy-desktop keyframes) is preserved.
pub(super) fn resolve_tier(
    native_w: u16,
    native_h: u16,
    tier: u8,
    params: &EncodeParams,
) -> (u16, u16, u8, u32) {
    let base = if params.maxrate_kbps > 0 {
        params.maxrate_kbps
    } else {
        auto_maxrate_kbps(native_w as u32, native_h as u32)
    };
    let (crf, scale, cap_kbps): (u8, f64, u32) = match tier {
        0 => (params.crf, 1.0, u32::MAX), // LAN tier: no WAN cap
        1 => (params.crf.saturating_add(3), 0.60, 12_000),
        2 => (params.crf.saturating_add(6), 0.35, 8_000),
        _ => (params.crf.saturating_add(6), 0.35, 5_000), // tier 3
    };
    let crf = crf.min(51);
    let maxrate = (((base as f64) * scale).round() as u32)
        .max(200)
        .min(cap_kbps);

    // L-3 progressive resolution ladder: tier 3 steps ~0.75x height (always); tier 2
    // steps a gentler ~6/7 (~0.857x) ONLY when SH_ABR_RES_LADDER is on, so the drop
    // to tier 3 is not a single cliff. Tiers 0-1 keep native. Default (ladder off) =>
    // only tier 3 downscales, byte-identical to today; a LAN session stays tier 0.
    let step: Option<(u32, u32)> = match tier {
        3 => Some((3, 4)),
        2 if params.abr_res_ladder => Some((6, 7)),
        _ => None,
    };
    let (ew, eh) = match step {
        None => (native_w, native_h),
        Some((num, den)) => {
            let floor = params.abr_floor_height.max(240);
            // one step down, 16-aligned, not below the floor.
            let mut th = ((native_h as u32) * num / den) / 16 * 16;
            if th < floor {
                th = floor;
            }
            if th >= native_h as u32 {
                (native_w, native_h) // native already at/below floor: no step
            } else {
                let mut tw = ((native_w as u32) * th) / (native_h as u32) / 16 * 16;
                if tw < 16 {
                    tw = 16;
                }
                (tw as u16, th as u16)
            }
        }
    };
    (ew, eh, crf, maxrate)
}

/// The VBV bufsize ratio actually applied for a tier (B3, 2026-07-17):
/// congested tiers (>= 1, VBV-driven) never budget more than 0.5 x maxrate
/// for a single burst, so the ~2.5 s heartbeat IDR cannot flood a
/// bufferbloated WAN queue in one go (busy WAN IDRs get quantised harder
/// transiently — accepted trade-off). Tier 0 is CQP (no VBV), so the
/// configured ratio passes through untouched and LAN quality is unchanged.
/// `min()` keeps this idempotent with the fleet-wide SH_BUFSIZE_RATIO=0.5
/// tile.env stopgap (plan item C1) deployed 2026-07-17.
pub(super) fn effective_bufsize_ratio(tier: u8, ratio: f64) -> f64 {
    if tier >= 1 {
        ratio.min(0.5)
    } else {
        ratio
    }
}

/// L-2 fps ladder: the encode fps for a tier. `base_fps` is the tile's configured
/// cap (SH_FPS). With the ladder OFF (default) EVERY tier runs the native base fps,
/// so a bare deploy is byte-identical and a LAN session (always tier 0) is
/// unaffected. With it ON, congested tiers cap fps — the cheapest quality-for-
/// bitrate lever for near-static retro desktops: tier1 <=15, tier2/3 <=10. Never
/// raises fps above the configured base, never returns 0 (the feed-interval math
/// divides by it).
pub(super) fn resolve_fps(tier: u8, base_fps: u32, params: &EncodeParams) -> u32 {
    if !params.abr_fps_ladder {
        return base_fps;
    }
    let cap = match tier {
        0 => base_fps,
        1 => 15,
        _ => 10,
    };
    base_fps.min(cap).max(1)
}

/// Resolve the SLICED-thread count: 0 = auto (min(4, cores)), else clamp 1..16.
pub(super) fn resolve_threads(cfg: u32) -> u32 {
    if cfg == 0 {
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4) as u32;
        cores.clamp(1, 4)
    } else {
        cfg.clamp(1, 16)
    }
}

#[cfg(test)]
mod tests {
    use super::super::EncodeParams;
    use super::{effective_bufsize_ratio, resolve_fps, resolve_tier};

    fn params() -> EncodeParams {
        EncodeParams {
            preset: "ultrafast".into(),
            profile: "high".into(),
            tune: "zerolatency".into(),
            crf: 10,
            maxrate_kbps: 0, // auto per-resolution table
            bufsize_ratio: 1.0,
            abr_floor_height: 480,
            threads: 0,
            enc_nice: None,
            damage_conv: true,
            damage_full_pct: 35,
            abr_fps_ladder: false,
            abr_res_ladder: false,
            abr_idr_backoff: false,
        }
    }

    /// 1920x1200 auto base = 69,120 kbps: every congested tier hits its WAN
    /// burst cap; tier 0 keeps the generous LAN budget untouched.
    #[test]
    fn wan_caps_bind_on_large_tiles() {
        let p = params();
        assert_eq!(resolve_tier(1920, 1200, 0, &p).3, 69_120);
        assert_eq!(resolve_tier(1920, 1200, 1, &p).3, 12_000);
        assert_eq!(resolve_tier(1920, 1200, 2, &p).3, 8_000);
        assert_eq!(resolve_tier(1920, 1200, 3, &p).3, 5_000);
    }

    /// 640x480 auto base = 12,000 kbps: the scaled rates sit below every WAN
    /// cap, so the clamp must not touch small tiles at all.
    #[test]
    fn wan_caps_inert_on_small_tiles() {
        let p = params();
        assert_eq!(resolve_tier(640, 480, 0, &p).3, 12_000);
        assert_eq!(resolve_tier(640, 480, 1, &p).3, 7_200);
        assert_eq!(resolve_tier(640, 480, 2, &p).3, 4_200);
        assert_eq!(resolve_tier(640, 480, 3, &p).3, 4_200);
    }

    /// L-3 res ladder: OFF (default) => tier 2 keeps native resolution (only tier 3
    /// steps, today's behavior); ON => tier 2 also steps down (~0.857x), bounded by
    /// the floor. Tier 3 is unchanged either way; tier 0/1 always native.
    #[test]
    fn res_ladder_gates_tier2_downscale() {
        let mut p = params(); // abr_res_ladder: false
        let native = (1920u16, 1200u16);
        // OFF: tiers 0/1/2 keep native; tier 3 steps down to 3/4 (16-aligned), >= floor.
        assert_eq!(
            (
                resolve_tier(native.0, native.1, 2, &p).0,
                resolve_tier(native.0, native.1, 2, &p).1
            ),
            native
        );
        let (w3, h3, _, _) = resolve_tier(native.0, native.1, 3, &p);
        assert_eq!((w3, h3), (1424, 896)); // 1200*3/4=900 ->896 (/16); 1920*896/1200 ->1424 (/16)
        assert!(h3 >= p.abr_floor_height as u16);
        // ON: tier 2 now ALSO steps (between native and tier 3); tier 3 unchanged.
        p.abr_res_ladder = true;
        assert_eq!(
            (
                resolve_tier(native.0, native.1, 0, &p).0,
                resolve_tier(native.0, native.1, 1, &p).1
            ),
            native
        );
        let (w2, h2, _, _) = resolve_tier(native.0, native.1, 2, &p);
        assert!(
            h2 < native.1 && h2 > h3,
            "tier2 steps between native and tier3: {w2}x{h2}"
        );
        assert!(h2 >= p.abr_floor_height as u16);
        assert_eq!(
            (
                resolve_tier(native.0, native.1, 3, &p).0,
                resolve_tier(native.0, native.1, 3, &p).1
            ),
            (w3, h3)
        );
    }

    /// L-2 fps ladder: OFF (default) => native fps at every tier (byte-identical
    /// deploy); ON => tier1 <=15, tier2/3 <=10, never above the base, never 0.
    #[test]
    fn fps_ladder_default_off_is_native() {
        let p = params(); // abr_fps_ladder: false
        assert_eq!(resolve_fps(0, 60, &p), 60);
        assert_eq!(resolve_fps(1, 60, &p), 60);
        assert_eq!(resolve_fps(3, 60, &p), 60);
    }

    #[test]
    fn fps_ladder_on_caps_congested_tiers() {
        let mut p = params();
        p.abr_fps_ladder = true;
        assert_eq!(resolve_fps(0, 60, &p), 60); // LAN tier untouched
        assert_eq!(resolve_fps(1, 60, &p), 15);
        assert_eq!(resolve_fps(2, 60, &p), 10);
        assert_eq!(resolve_fps(3, 60, &p), 10);
        // Never raises fps above the configured base (a 24 fps tile stays <= 24).
        assert_eq!(resolve_fps(1, 24, &p), 15);
        assert_eq!(resolve_fps(2, 8, &p), 8);
    }

    /// Congested-tier (>= 1) bufsize is capped at 0.5 x maxrate — idempotent
    /// with the fleet SH_BUFSIZE_RATIO=0.5 tile.env stopgap; a tighter
    /// operator-set ratio stays tighter; tier 0 (CQP, no VBV) passes through.
    #[test]
    fn bufsize_ratio_capped_only_on_congested_tiers() {
        assert_eq!(effective_bufsize_ratio(0, 1.0), 1.0);
        assert_eq!(effective_bufsize_ratio(0, 2.0), 2.0);
        assert_eq!(effective_bufsize_ratio(1, 1.0), 0.5);
        assert_eq!(effective_bufsize_ratio(2, 0.5), 0.5);
        assert_eq!(effective_bufsize_ratio(3, 2.0), 0.5);
        assert_eq!(effective_bufsize_ratio(1, 0.5), 0.5);
    }
}
