//! Surface pixels -> mouse COUNTS, for a guest whose pointer is a quadrature
//! encoder rather than a position.
//!
//! WHY THIS EXISTS. `mame_sock`/`mame_input` state pointer targets in emulated
//! framebuffer PIXELS, and on the SGI Indy that is right: the agent reads the
//! Newport VC2 hardware-cursor registers, so the loop converges on whatever the
//! pixels->counts relationship happens to be. A machine with no hardware cursor
//! has no such reading, and the module degrades to open loop — each target is a
//! DELTA FROM THE PREVIOUS TARGET, issued one ioport count per pixel. That is
//! correct only when one count moves the guest cursor exactly one pixel, and on
//! the Atari ST it does not:
//!
//!   * MAME's `stkbd` latches the 8-bit MOUSEX/MOUSEY ioport every 4 ticks of a
//!     500 Hz timer, keeps only the DIRECTION of the change and emits ONE
//!     quadrature cycle per latch. The magnitude of a burst is discarded, so the
//!     device absorbs ~125 counts/s/axis and no more;
//!   * one delivered count moves the GEM cursor 4 ST pixels, which on the
//!     published 1024x768 surface is ~9.7 px across and ~12.3 px down.
//!
//! Issuing one count per surface pixel therefore overshoots by an order of
//! magnitude, and with no reading to correct against, the residual never shrinks
//! and the pointer bleeds paced counts until it slams into an edge — the "runs
//! away" symptom. The pointer's real resolution is the COUNT GRID: 79 x 52
//! reachable positions on the ST, not 1024 x 768.
//!
//! So the sink states targets in grid units. `PtrGrid` is the affine map from
//! the surface rectangle the guest pointer can actually reach onto that grid,
//! measured on the live machine and passed in as `SH_MAMESOCK_PTR_GRID`
//! ("left,top,right,bottom,cols,rows"). UNSET = no mapping and no reckoning at
//! all, which is exactly the irix behaviour this must not disturb.
//!
//! `GridReckon` adds what open-loop dead reckoning needs to stay honest, in
//! grid units, and for the same reasons `ptr_reckon` documents at length: a
//! HOME slam so the first sample starts from a known origin instead of an
//! assumed one, and a full-axis SLAM whenever the target ENTERS an edge, so a
//! clamping guest and our model cannot disagree permanently. It differs from
//! `ptr_reckon::Reckoner` in one way that matters here: the motion itself still
//! rides an ABSOLUTE `MOVEA` target (the module differences it, and acks it
//! immediately), so this returns only the slams that must ride alongside — which
//! is what lets the sink keep coalescing moves latest-wins.

use std::time::{Duration, Instant};

/// Pointer silence after which the next sample re-establishes the origin. Same
/// value and same reasoning as `ptr_reckon::REHOME_IDLE`: no interactive session
/// crosses it, and the station self-heals between visitors.
const REHOME_IDLE: Duration = Duration::from_secs(30);

/// Extra counts on a homing slam, past the grid's own extent, so the guest is
/// certainly clamped in the corner and not merely close to it.
const HOME_MARGIN: u32 = 8;

/// The surface rectangle the guest pointer can reach, and how many discrete
/// count positions span it. `left`/`top` are the surface pixels of grid (0,0)
/// and `right`/`bottom` those of grid (cols-1, rows-1) — i.e. the two corner
/// CLAMPS, which is what a calibration run can actually measure.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PtrGrid {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
    pub cols: u32,
    pub rows: u32,
}

impl PtrGrid {
    /// `SH_MAMESOCK_PTR_GRID`, read once at sink construction. The knob is read
    /// HERE rather than in `config` for two reasons: `config/mod.rs` is at its
    /// size cap and this is a single-consumer knob, and the parser that decides
    /// what a valid grid IS should be the thing that documents it (the same
    /// arrangement `mame_sock`'s `SH_MAMESOCK_TRACE` already uses). See
    /// `streamhost/docs/CONFIG.md`.
    pub fn from_env() -> Option<Self> {
        let spec = std::env::var("SH_MAMESOCK_PTR_GRID").ok()?;
        if spec.trim().is_empty() {
            return None;
        }
        Self::parse(&spec)
    }

    /// Parse "left,top,right,bottom,cols,rows". Returns None (with the reason on
    /// stderr) for anything that would not produce a usable map, so a typo
    /// degrades to the unmapped default instead of a silently skewed pointer.
    pub fn parse(spec: &str) -> Option<Self> {
        let f: Vec<&str> = spec.split(',').map(str::trim).collect();
        let bad = |why: &str| {
            eprintln!("[ptr-grid] ignoring {spec:?}: {why}");
            None::<Self>
        };
        if f.len() != 6 {
            return bad("expected left,top,right,bottom,cols,rows");
        }
        let mut v = [0u32; 6];
        for (i, s) in f.iter().enumerate() {
            match s.parse::<u32>() {
                Ok(n) => v[i] = n,
                Err(_) => return bad("fields must be non-negative integers"),
            }
        }
        let g = Self {
            left: v[0],
            top: v[1],
            right: v[2],
            bottom: v[3],
            cols: v[4],
            rows: v[5],
        };
        if g.right <= g.left || g.bottom <= g.top {
            return bad("right/bottom must exceed left/top");
        }
        if g.cols < 2 || g.rows < 2 {
            return bad("cols/rows must be at least 2");
        }
        Some(g)
    }

    /// One surface point -> its grid cell, clamped to the grid. Rounds to
    /// nearest so the cell boundaries fall halfway between reachable positions.
    pub fn map(&self, x: u32, y: u32) -> (u32, u32) {
        (
            axis(x, self.left, self.right, self.cols),
            axis(y, self.top, self.bottom, self.rows),
        )
    }

    /// The relative slam that pins the guest into the (0,0) corner: past the
    /// full extent of the grid in both axes, so it clamps whatever it believed.
    pub fn home_slam(&self) -> (i32, i32) {
        (
            -((self.cols + HOME_MARGIN) as i32),
            -((self.rows + HOME_MARGIN) as i32),
        )
    }
}

fn axis(v: u32, lo: u32, hi: u32, n: u32) -> u32 {
    let span = i64::from(hi) - i64::from(lo);
    let off = i64::from(v) - i64::from(lo);
    let cell = (off * i64::from(n - 1) * 2 + span) / (span * 2); // round to nearest
    cell.clamp(0, i64::from(n - 1)) as u32
}

/// What must ride ALONGSIDE the absolute target for this sample.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GridStep {
    /// Emit the homing slam and re-state the origin BEFORE the target.
    pub home: bool,
    /// Emit this relative slam AFTER the target: the target has taken the
    /// pointer to an edge, and the overshoot re-pins model and guest together.
    pub slam_x: i32,
    pub slam_y: i32,
}

impl GridStep {
    /// A sample carrying either is order-sensitive and must not be coalesced.
    pub fn is_plain(&self) -> bool {
        !self.home && self.slam_x == 0 && self.slam_y == 0
    }
}

/// Home/edge bookkeeping for one pointer stream, in grid units.
#[derive(Default)]
pub struct GridReckon {
    seeded: bool,
    on_edge_x: bool,
    on_edge_y: bool,
    last: Option<Instant>,
}

impl GridReckon {
    /// Forget the origin: the next sample re-homes. Called when the control
    /// connection is (re)established, because the module's own last-target
    /// belief did not survive with us.
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn step(&mut self, cx: u32, cy: u32, cols: u32, rows: u32) -> GridStep {
        self.step_at(cx, cy, cols, rows, Instant::now())
    }

    fn step_at(&mut self, cx: u32, cy: u32, cols: u32, rows: u32, now: Instant) -> GridStep {
        let idle = self
            .last
            .is_some_and(|t| now.duration_since(t) >= REHOME_IDLE);
        self.last = Some(now);

        let home = !self.seeded || idle;
        if home {
            // The slam leaves the guest clamped in the corner, i.e. on both
            // edges already — so the very next sample must not read as an edge
            // ENTRY and slam again for nothing.
            self.seeded = true;
            self.on_edge_x = true;
            self.on_edge_y = true;
        }

        let at_x = cx == 0 || cx >= cols - 1;
        let at_y = cy == 0 || cy >= rows - 1;
        let slam_x = if at_x && !self.on_edge_x {
            if cx == 0 {
                -(cols as i32)
            } else {
                cols as i32
            }
        } else {
            0
        };
        let slam_y = if at_y && !self.on_edge_y {
            if cy == 0 {
                -(rows as i32)
            } else {
                rows as i32
            }
        } else {
            0
        };
        self.on_edge_x = at_x;
        self.on_edge_y = at_y;
        GridStep {
            home,
            slam_x,
            slam_y,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{GridReckon, GridStep, PtrGrid, REHOME_IDLE};

    /// The live Atari ST arm's measured map: the GEM pointer reaches surface
    /// x 134..891 and y 63..692, on a 79 x 52 count grid.
    fn st() -> PtrGrid {
        PtrGrid::parse("134,63,891,692,79,52").unwrap()
    }

    #[test]
    fn a_bad_spec_degrades_to_no_mapping_rather_than_a_skewed_one() {
        for spec in [
            "",
            "1,2,3",
            "134,63,891,692,79,52,7",
            "134,63,891,692,79",
            "134,63,100,692,79,52", // right <= left
            "134,63,891,10,79,52",  // bottom <= top
            "134,63,891,692,1,52",  // degenerate grid
            "134,63,891,692,79,0",
            "134,63,891,692,79,-2",
            "a,b,c,d,e,f",
        ] {
            assert_eq!(PtrGrid::parse(spec), None, "{spec:?} must not parse");
        }
    }

    #[test]
    fn corners_map_to_corners_and_beyond_them_clamps() {
        let g = st();
        assert_eq!(g.map(134, 63), (0, 0));
        assert_eq!(g.map(891, 692), (78, 51));
        // Outside the reachable rectangle (letterbox border, or a surface
        // bigger than the raster) clamps rather than running off the grid.
        assert_eq!(g.map(0, 0), (0, 0));
        assert_eq!(g.map(1023, 767), (78, 51));
    }

    /// The map must be monotone and cover every cell — a rounding error that
    /// made a cell unreachable would be a dead stripe on the desktop.
    #[test]
    fn every_grid_cell_is_reachable_and_the_map_is_monotone() {
        let g = st();
        let mut seen = [false; 79];
        let mut prev = 0;
        for x in 0..1024 {
            let (cx, _) = g.map(x, 63);
            assert!(cx >= prev, "map went backwards at x={x}");
            prev = cx;
            seen[cx as usize] = true;
        }
        assert!(seen.iter().all(|s| *s), "some column is unreachable");
    }

    #[test]
    fn one_count_is_about_ten_surface_pixels_across_and_twelve_down() {
        let g = st();
        // Interior: 20 counts across == the 195 px measured on the live arm.
        assert_eq!(g.map(307, 209).0 + 20, g.map(502, 209).0);
        assert_eq!(g.map(502, 136).1 + 10, g.map(502, 260).1);
    }

    #[test]
    fn the_first_sample_homes_and_the_second_does_not() {
        let mut r = GridReckon::default();
        let s = r.step(40, 20, 79, 52);
        assert!(s.home);
        assert_eq!((s.slam_x, s.slam_y), (0, 0));
        assert!(!s.is_plain());
        let s = r.step(41, 20, 79, 52);
        assert_eq!(s, GridStep::default());
        assert!(s.is_plain());
    }

    /// The home slam leaves the guest in the corner, so the first move AWAY
    /// from it must not be read as an edge entry and slammed again.
    #[test]
    fn homing_corner_is_not_re_slammed_by_the_first_move_away() {
        let mut r = GridReckon::default();
        assert!(r.step(0, 0, 79, 52).home);
        assert_eq!(r.step(10, 10, 79, 52), GridStep::default());
    }

    #[test]
    fn entering_an_edge_slams_once_and_parking_on_it_does_not_repeat() {
        let mut r = GridReckon::default();
        r.step(40, 20, 79, 52); // homes
        r.step(41, 20, 79, 52);
        let s = r.step(0, 20, 79, 52);
        assert_eq!((s.home, s.slam_x, s.slam_y), (false, -79, 0));
        // parked on the left edge: no second slam
        assert_eq!(r.step(0, 21, 79, 52), GridStep::default());
        // leaving it is a plain move
        assert_eq!(r.step(30, 21, 79, 52), GridStep::default());
        // the opposite edge slams the other way, and the bottom with it
        let s = r.step(78, 51, 79, 52);
        assert_eq!((s.slam_x, s.slam_y), (79, 52));
    }

    #[test]
    fn a_long_idle_gap_re_homes_so_out_of_band_motion_cannot_stick() {
        let mut r = GridReckon::default();
        assert!(r.step(40, 20, 79, 52).home);
        assert!(!r.step(41, 20, 79, 52).home);
        let then = std::time::Instant::now();
        assert!(
            r.step_at(42, 20, 79, 52, then + REHOME_IDLE + REHOME_IDLE)
                .home
        );
    }

    #[test]
    fn the_home_slam_overshoots_the_whole_grid() {
        let g = st();
        let (hx, hy) = g.home_slam();
        assert!(hx < -(g.cols as i32) && hy < -(g.rows as i32));
    }

    #[test]
    fn reset_makes_the_next_sample_home_again() {
        let mut r = GridReckon::default();
        assert!(r.step(40, 20, 79, 52).home);
        assert!(!r.step(40, 20, 79, 52).home);
        r.reset();
        assert!(r.step(40, 20, 79, 52).home);
    }
}
