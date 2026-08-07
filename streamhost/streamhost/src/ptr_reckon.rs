//! Absolute-to-relative pointer dead reckoning, shared by the two emulator input
//! sinks (`x11_input::X11TestSink` and `mame_input::MameCmdSink` — the latter
//! only on its `SH_MAMECMD_ABS=0` rollback path; its default is closed-loop
//! MOVEA targets that need no reckoning at all).
//!
//! Both drive a guest whose mouse is RELATIVE while the browser sends ABSOLUTE
//! targets, so both have to remember where they last put the cursor and send the
//! difference. That is straightforward until the cursor reaches a screen edge —
//! and then it is not, in a way that is easy to miss and impossible to recover
//! from once it has happened:
//!
//! **A clamping guest and a dead-reckoned model disagree permanently after one
//! edge clamp.** The guest stops at the edge; our model keeps whatever we last
//! commanded. Commanding the edge again produces a delta of ZERO, so there is
//! nothing left that could ever push the two back into agreement — the error is
//! frozen in for the rest of the session and every later click lands off-target
//! by it. Measured on the IRIX tile: after a single clamp at the top edge the
//! guest cursor sat 127 px below where the model said it was, and a closed-loop
//! corrector reading the real framebuffer could not recover it, because the
//! correction it wanted to send was a negative coordinate that does not exist.
//!
//! The fix is to make an edge SELF-CORRECTING: whenever the target ENTERS an
//! edge, add a full-surface slam in that axis. The guest clamps, both ends agree
//! again, and the overshoot costs nothing precisely because the cursor is already
//! pinned there. Only on entry, never while parked on the edge — otherwise
//! holding the pointer against an edge queues slams faster than the guest can
//! consume them and the pointer goes unresponsive when it finally leaves.
//!
//! The other way the model goes stale is ANYTHING ELSE moving the guest pointer:
//! an ops script writing to the agent's command file, the desktop-park helper,
//! the guest warping its own cursor. Dead reckoning cannot see that happen, and
//! homing only once per process means the error then lasts for the life of the
//! daemon. Measured on the live tile: after the park helper drove the pointer
//! out of band, a browser session tracked the guest EXACTLY in delta (moves
//! matched to 2 px) but with a constant ~(463,232) px offset. So the reckoner
//! re-homes after `REHOME_IDLE` of pointer silence: a visitor mid-interaction is
//! never interrupted (samples arrive tens of times a second), while a fresh
//! visitor — and any out-of-band drift — gets a correct origin. That first move
//! already homed before this existed, so the visible behaviour is unchanged for
//! the case that matters.

use std::time::{Duration, Instant};

/// What to send to the guest for one absolute sample.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Step {
    /// First sample of the session: the caller must emit its homing slam (an
    /// over-large negative delta that clamps the guest into the top-left corner)
    /// BEFORE `dx`/`dy`, and must not merge the two — a transport that summed
    /// them would cancel part of the homing overshoot instead of moving.
    pub home: bool,
    pub dx: i32,
    pub dy: i32,
}

/// Pointer silence after which the next sample re-establishes the origin.
/// Long enough that no interactive session ever crosses it (samples arrive at
/// tens of hertz while a visitor is moving) and short enough that the tile
/// self-heals between visitors.
const REHOME_IDLE: Duration = Duration::from_secs(30);

#[derive(Default)]
pub struct Reckoner {
    lx: i32,
    ly: i32,
    seeded: bool,
    on_edge_x: bool,
    on_edge_y: bool,
    last: Option<Instant>,
}

impl Reckoner {
    /// Convert one absolute client target into the relative delta to inject.
    /// `width`/`height` are the guest surface size, from the live capture state.
    pub fn step(&mut self, x: u32, y: u32, width: u32, height: u32) -> Step {
        let tx = x.min(width.saturating_sub(1)) as i32;
        let ty = y.min(height.saturating_sub(1)) as i32;

        let now = Instant::now();
        let idle = self
            .last
            .is_some_and(|t| now.duration_since(t) >= REHOME_IDLE);
        self.last = Some(now);

        let home = !self.seeded || idle;
        if home {
            // The homing slam leaves the guest clamped in the corner, which is
            // both axes' edges — record that so the very next sample does not
            // also count as an edge ENTRY and slam again for no reason.
            self.lx = 0;
            self.ly = 0;
            self.seeded = true;
            self.on_edge_x = true;
            self.on_edge_y = true;
        }

        let at_x = tx == 0 || tx as u32 >= width.saturating_sub(1);
        let at_y = ty == 0 || ty as u32 >= height.saturating_sub(1);
        let mut dx = tx - self.lx;
        let mut dy = ty - self.ly;
        if at_x && !self.on_edge_x {
            dx += if tx == 0 {
                -(width as i32)
            } else {
                width as i32
            };
        }
        if at_y && !self.on_edge_y {
            dy += if ty == 0 {
                -(height as i32)
            } else {
                height as i32
            };
        }
        self.on_edge_x = at_x;
        self.on_edge_y = at_y;
        self.lx = tx;
        self.ly = ty;
        Step { home, dx, dy }
    }
}

#[cfg(test)]
mod tests {
    use super::{Reckoner, Step};

    const W: u32 = 1288;
    const H: u32 = 1024;

    fn step(r: &mut Reckoner, x: u32, y: u32) -> Step {
        r.step(x, y, W, H)
    }

    /// A long gap in pointer traffic re-establishes the origin, so anything that
    /// moved the guest cursor behind our back cannot leave a permanent offset.
    #[test]
    fn a_long_idle_gap_re_homes() {
        let mut r = Reckoner::default();
        assert!(step(&mut r, 100, 100).home, "first sample always homes");
        assert!(!step(&mut r, 200, 200).home, "back-to-back samples do not");
        r.last = Some(std::time::Instant::now() - super::REHOME_IDLE);
        let s = step(&mut r, 300, 300);
        assert!(s.home, "a sample after REHOME_IDLE of silence re-homes");
        assert_eq!(
            (s.dx, s.dy),
            (300, 300),
            "and reckons from the corner again"
        );
    }

    #[test]
    fn first_sample_homes_then_deltas_are_plain_differences() {
        let mut r = Reckoner::default();
        assert_eq!(
            step(&mut r, 100, 50),
            Step {
                home: true,
                dx: 100,
                dy: 50
            }
        );
        assert_eq!(
            step(&mut r, 140, 50),
            Step {
                home: false,
                dx: 40,
                dy: 0
            }
        );
        assert_eq!(
            step(&mut r, 140, 50),
            Step {
                home: false,
                dx: 0,
                dy: 0
            }
        );
    }

    #[test]
    fn homing_corner_is_not_re_slammed_by_the_first_move_away() {
        // The home leaves the guest in the corner, i.e. on both edges already.
        let mut r = Reckoner::default();
        assert_eq!(step(&mut r, 0, 0).dx, 0);
        assert_eq!(
            step(&mut r, 10, 10),
            Step {
                home: false,
                dx: 10,
                dy: 10
            }
        );
    }

    #[test]
    fn entering_an_edge_slams_once_and_parking_does_not_repeat_it() {
        let mut r = Reckoner::default();
        step(&mut r, 500, 500);
        // Enter the LEFT edge: -500 plus a full-width slam.
        assert_eq!(
            step(&mut r, 0, 500),
            Step {
                home: false,
                dx: -500 - W as i32,
                dy: 0
            }
        );
        // Parked on it: plain delta, no second slam.
        assert_eq!(
            step(&mut r, 0, 400),
            Step {
                home: false,
                dx: 0,
                dy: -100
            }
        );
        // Leaving is plain too.
        assert_eq!(
            step(&mut r, 300, 400),
            Step {
                home: false,
                dx: 300,
                dy: 0
            }
        );
    }

    #[test]
    fn far_edges_and_out_of_range_targets_clamp_and_slam() {
        let mut r = Reckoner::default();
        step(&mut r, 500, 500);
        // A target past the surface clamps to the last addressable pixel and
        // slams in BOTH axes.
        let s = step(&mut r, 9999, 9999);
        assert_eq!(s.dx, (W as i32 - 1 - 500) + W as i32);
        assert_eq!(s.dy, (H as i32 - 1 - 500) + H as i32);
        // Still on both edges: no repeat.
        assert_eq!(
            step(&mut r, W - 1, H - 1),
            Step {
                home: false,
                dx: 0,
                dy: 0
            }
        );
    }

    #[test]
    fn one_axis_on_an_edge_does_not_slam_the_other() {
        let mut r = Reckoner::default();
        step(&mut r, 500, 500);
        let s = step(&mut r, 0, 600);
        assert_eq!(s.dx, -500 - W as i32);
        assert_eq!(s.dy, 100, "y is nowhere near an edge");
    }
}
