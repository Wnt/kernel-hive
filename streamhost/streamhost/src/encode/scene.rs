// Pure feed-gating + content scene-change detection for the capture->encode loop:
// should_feed() decides whether a wakeup produces a frame; update_scene_samples()
// maintains the every-8th-pixel content detector that drives forced IDRs.
// Extracted verbatim from encode/mod.rs; pipeline overview lives there.

use super::handoff::BgraPatch;

/// RECEIVER-GATED FEED DECISION (pure; unit-tested below). One wakeup of the
/// capture->encode loop produces a frame iff:
///   * `kicked`  — a joiner's request_keyframe() advanced key_req. Always feeds:
///     transport subscribes BEFORE kicking, so the joiner's forced IDR is never
///     gated away, even in the subscribe/receiver_count race window.
///   * `damaged` — guest framebuffer changed. Feeds ONLY while watched: with
///     zero receivers the encoded AU would be broadcast to nobody, so feeding
///     was pure waste (~23% of the host across 28 idle stations, 2026-07-12).
///   * `hb_due`  — wall-clock heartbeat tick elapsed. Watched-only, as before.
pub(super) fn should_feed(damaged: bool, kicked: bool, watched: bool, hb_due: bool) -> bool {
    kicked || (watched && (damaged || hb_due))
}

/// Update the every-eighth-pixel scene detector from damage patches instead of
/// requiring a full BGRA snapshot. The returned fraction still uses the whole
/// frame's sample count, so the existing >=70% scene-change threshold retains
/// its meaning.
pub(super) fn update_scene_samples(
    patches: &[BgraPatch],
    frame_w: usize,
    frame_h: usize,
    prev: &mut Vec<u32>,
) -> f32 {
    let sample_w = frame_w.div_ceil(8);
    let sample_h = frame_h.div_ceil(8);
    let sample_n = sample_w * sample_h;
    let had_previous = prev.len() == sample_n && sample_n != 0;
    if !had_previous {
        prev.clear();
        prev.resize(sample_n, 0);
    }
    let mut changed = 0usize;
    for patch in patches {
        let r = patch.rect;
        let x_first = (r.x as usize).div_ceil(8) * 8;
        let y_first = (r.y as usize).div_ceil(8) * 8;
        let x_end = r.x as usize + r.w as usize;
        let y_end = r.y as usize + r.h as usize;
        let mut y = y_first;
        while y < y_end {
            let mut x = x_first;
            while x < x_end {
                let src = ((y - r.y as usize) * r.w as usize + (x - r.x as usize)) * 4;
                let value = u32::from_le_bytes([
                    patch.bgra[src],
                    patch.bgra[src + 1],
                    patch.bgra[src + 2],
                    patch.bgra[src + 3],
                ]);
                let idx = (y / 8) * sample_w + x / 8;
                if had_previous && prev[idx] != value {
                    changed += 1;
                }
                prev[idx] = value;
                x += 8;
            }
            y += 8;
        }
    }
    if had_previous {
        changed as f32 / sample_n as f32
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::should_feed;

    /// The 2026-07-12 idle-CPU gate: an animated guest with ZERO receivers
    /// must not feed the encoder (damage used to bypass the idle gating and
    /// run snapshot+scene-detect+x264 24/7 on unwatched stations).
    #[test]
    fn unwatched_damage_does_not_feed() {
        assert!(!should_feed(true, false, false, false));
        assert!(!should_feed(true, false, false, true)); // nor with a tick due
    }

    /// Watched damage feeds — the interactive path is unchanged.
    #[test]
    fn watched_damage_feeds() {
        assert!(should_feed(true, false, true, false));
    }

    /// A join kick ALWAYS feeds, even if the receiver-count read races the
    /// subscribe (transport subscribes before request_keyframe, so the forced
    /// IDR for the joiner must never be gated away).
    #[test]
    fn join_kick_always_feeds() {
        assert!(should_feed(false, true, false, false));
        assert!(should_feed(false, true, true, false));
        assert!(should_feed(true, true, false, true));
    }

    /// The heartbeat only feeds while watched (pre-existing behavior).
    #[test]
    fn heartbeat_only_while_watched() {
        assert!(should_feed(false, false, true, true));
        assert!(!should_feed(false, false, false, true));
    }

    /// A bare unwatched tick with nothing pending stays dark.
    #[test]
    fn idle_tick_stays_dark() {
        assert!(!should_feed(false, false, false, false));
        assert!(!should_feed(false, false, true, false));
    }
}
