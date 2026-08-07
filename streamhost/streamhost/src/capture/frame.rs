// Framebuffer state + damage accounting for dbus-display capture.
//
// `FrameState` holds the latest scanout surface — either an mmap'd memfd shared
// with QEMU (zero-copy Unix.Map path) or a reconstructed v1 copy-path
// framebuffer — plus the accumulated damage region. The listener callbacks
// (see `super::listener`) mutate it on every scanout/update; the encode loop
// drains it via `snapshot_damage_bgra` (or `snapshot_bgra` for the bootrec
// sidecar bin).

/// Frame-relative damage rectangle. Capture callbacks accumulate their union;
/// the encode loop consumes it atomically with the corresponding pixel copy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DamageRect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

impl DamageRect {
    fn union(self, other: Self) -> Self {
        let x0 = self.x.min(other.x);
        let y0 = self.y.min(other.y);
        let x1 = self
            .x
            .saturating_add(self.w)
            .max(other.x.saturating_add(other.w));
        let y1 = self
            .y
            .saturating_add(self.h)
            .max(other.y.saturating_add(other.h));
        Self {
            x: x0,
            y: y0,
            w: x1.saturating_sub(x0),
            h: y1.saturating_sub(y0),
        }
    }

    fn area(self) -> u64 {
        self.w as u64 * self.h as u64
    }
}

/// A tightly-packed BGRA snapshot of either a damage bbox or the full frame.
pub struct DamageSnapshot {
    pub bgra: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub rect: Option<DamageRect>,
    pub generation: u64,
}

// Latest scanout surface. `map_ptr` points into a memfd shared with QEMU.
pub struct FrameState {
    pub map_ptr: *mut u8,
    pub map_len: usize,
    pub offset: usize,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub format: u32,
    pub frames: u64,
    // v1 copy-path reconstruction (fallback when shm isn't offered)
    pub fb: Vec<u8>,
    pub fb_w: u32,
    pub fb_h: u32,
    pub fb_stride: u32,
    pub gen: u64, // bumped every damage event
    pending_damage: Option<DamageRect>,
    // Sum of clipped damage-event areas since the previous snapshot. The bbox
    // alone misses video-style churn when QEMU repeatedly reports many small
    // strips covering the same part of the scanout.
    pending_damage_area: u64,
    full_damage: bool,
}
unsafe impl Send for FrameState {}

impl FrameState {
    pub(super) fn new() -> Self {
        FrameState {
            map_ptr: std::ptr::null_mut(),
            map_len: 0,
            offset: 0,
            width: 0,
            height: 0,
            stride: 0,
            format: 0,
            frames: 0,
            fb: Vec::new(),
            fb_w: 0,
            fb_h: 0,
            fb_stride: 0,
            gen: 0,
            pending_damage: None,
            pending_damage_area: 0,
            full_damage: false,
        }
    }

    fn frame_geometry(&self) -> Option<(u32, u32)> {
        if !self.map_ptr.is_null() && self.width > 0 && self.height > 0 {
            Some((self.width, self.height))
        } else if !self.fb.is_empty() && self.fb_w > 0 && self.fb_h > 0 {
            Some((self.fb_w, self.fb_h))
        } else {
            None
        }
    }

    pub(super) fn note_full_damage(&mut self) {
        self.full_damage = true;
        self.pending_damage = None;
        self.pending_damage_area = 0;
    }

    pub(super) fn note_damage(&mut self, x: i32, y: i32, w: i32, h: i32) {
        let Some((fw, fh)) = self.frame_geometry() else {
            return;
        };
        if w <= 0 || h <= 0 {
            return;
        }
        let x0 = (x as i64).clamp(0, fw as i64);
        let y0 = (y as i64).clamp(0, fh as i64);
        let x1 = (x as i64 + w as i64).clamp(0, fw as i64);
        let y1 = (y as i64 + h as i64).clamp(0, fh as i64);
        if x1 <= x0 || y1 <= y0 || self.full_damage {
            return;
        }
        let rect = DamageRect {
            x: x0 as u32,
            y: y0 as u32,
            w: (x1 - x0) as u32,
            h: (y1 - y0) as u32,
        };
        self.pending_damage_area = self.pending_damage_area.saturating_add(rect.area());
        self.pending_damage = Some(match self.pending_damage {
            Some(old) => old.union(rect),
            None => rect,
        });
    }

    /// Drop the shm map (munmap + clear geometry). Caller holds the lock.
    pub(super) fn drop_map(&mut self) {
        if !self.map_ptr.is_null() {
            unsafe { libc::munmap(self.map_ptr as *mut libc::c_void, self.map_len) };
            self.map_ptr = std::ptr::null_mut();
            self.map_len = 0;
            self.offset = 0;
            self.width = 0;
            self.height = 0;
            self.stride = 0;
        }
    }

    /// Copy the current frame into a tightly-packed BGRA buffer (w*h*4).
    /// Returns (bytes, w, h) or None if no frame yet.
    // Only called from the bootrec-tap sidecar bin (via the `streamhost` lib target);
    // the daemon bin compiles this same source with its own private mods, where it
    // is genuinely unused — a false positive from this target's point of view.
    #[allow(dead_code)]
    pub fn snapshot_bgra(&self) -> Option<(Vec<u8>, u32, u32)> {
        if !self.map_ptr.is_null() && self.width > 0 && self.height > 0 {
            let w = self.width as usize;
            let h = self.height as usize;
            let stride = self.stride as usize;
            let mut out = vec![0u8; w * h * 4];
            for y in 0..h {
                let row_off = self.offset + y * stride;
                let dst = y * w * 4;
                if row_off + w * 4 <= self.map_len {
                    let src =
                        unsafe { std::slice::from_raw_parts(self.map_ptr.add(row_off), w * 4) };
                    out[dst..dst + w * 4].copy_from_slice(src);
                }
            }
            Some((out, self.width, self.height))
        } else if !self.fb.is_empty() && self.fb_w > 0 {
            let w = self.fb_w as usize;
            let h = self.fb_h as usize;
            let stride = self.fb_stride as usize;
            let mut out = vec![0u8; w * h * 4];
            for y in 0..h {
                let row_off = y * stride;
                let dst = y * w * 4;
                if row_off + w * 4 <= self.fb.len() {
                    out[dst..dst + w * 4].copy_from_slice(&self.fb[row_off..row_off + w * 4]);
                }
            }
            Some((out, self.fb_w, self.fb_h))
        } else {
            None
        }
    }

    /// Consume accumulated D-Bus damage and copy only its even-padded bbox.
    /// `force_full` covers first/reopen/key-request frames; `enabled=false` is
    /// the rollback knob. Large bboxes and high accumulated damage volume fall
    /// back before copying. Empty damage is valid for heartbeat frames: the
    /// worker reuses its complete I420 state.
    pub fn snapshot_damage_bgra(
        &mut self,
        enabled: bool,
        full_threshold_pct: u8,
        force_full: bool,
    ) -> Option<DamageSnapshot> {
        let (fw, fh) = self.frame_geometry()?;
        let full_rect = DamageRect {
            x: 0,
            y: 0,
            w: fw,
            h: fh,
        };
        let frame_area = fw as u64 * fh as u64;
        let threshold = full_threshold_pct.clamp(1, 100) as u64;
        let mut full = force_full || !enabled || self.full_damage;
        let mut rect = self.pending_damage;
        let threshold_area = frame_area.saturating_mul(threshold);
        let bbox_reaches_threshold = rect
            .map(|r| r.area().saturating_mul(100) >= threshold_area)
            .unwrap_or(false);
        let accumulated_reaches_threshold =
            self.pending_damage_area.saturating_mul(100) >= threshold_area;
        if bbox_reaches_threshold || accumulated_reaches_threshold {
            full = true;
        }
        if full {
            rect = Some(full_rect);
        } else if let Some(r) = rect {
            // I420 chroma is shared by each 2x2 luma block. Expand outward so a
            // partial conversion always refreshes whole chroma samples.
            let x0 = r.x & !1;
            let y0 = r.y & !1;
            let x1 = r.x.saturating_add(r.w).saturating_add(1) & !1;
            let y1 = r.y.saturating_add(r.h).saturating_add(1) & !1;
            rect = Some(DamageRect {
                x: x0,
                y: y0,
                w: x1.min(fw).saturating_sub(x0),
                h: y1.min(fh).saturating_sub(y0),
            });
        }

        let mut bgra = Vec::new();
        if let Some(r) = rect {
            bgra.resize(r.w as usize * r.h as usize * 4, 0);
            let row_bytes = r.w as usize * 4;
            if !self.map_ptr.is_null() && self.width == fw && self.height == fh {
                for row in 0..r.h as usize {
                    let src_off = self.offset
                        + (r.y as usize + row) * self.stride as usize
                        + r.x as usize * 4;
                    let dst_off = row * row_bytes;
                    if src_off + row_bytes <= self.map_len {
                        let src = unsafe {
                            std::slice::from_raw_parts(self.map_ptr.add(src_off), row_bytes)
                        };
                        bgra[dst_off..dst_off + row_bytes].copy_from_slice(src);
                    }
                }
            } else {
                for row in 0..r.h as usize {
                    let src_off = (r.y as usize + row) * self.fb_stride as usize + r.x as usize * 4;
                    let dst_off = row * row_bytes;
                    if src_off + row_bytes <= self.fb.len() {
                        bgra[dst_off..dst_off + row_bytes]
                            .copy_from_slice(&self.fb[src_off..src_off + row_bytes]);
                    }
                }
            }
        }

        self.pending_damage = None;
        self.pending_damage_area = 0;
        self.full_damage = false;
        Some(DamageSnapshot {
            bgra,
            width: fw,
            height: fh,
            rect,
            generation: self.gen,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{DamageRect, FrameState};

    #[test]
    fn damage_union_clips_and_pads_for_i420() {
        let mut s = FrameState::new();
        s.fb_w = 20;
        s.fb_h = 12;
        s.fb_stride = 80;
        s.fb = (0..20 * 12 * 4).map(|i| i as u8).collect();
        s.note_damage(-3, 3, 8, 4); // clipped to x=0..5
        s.note_damage(9, 4, 4, 5); // union x=0..13, y=3..9
        let snap = s.snapshot_damage_bgra(true, 90, false).unwrap();
        assert_eq!(
            snap.rect,
            Some(DamageRect {
                x: 0,
                y: 2,
                w: 14,
                h: 8
            })
        );
        assert_eq!(snap.bgra.len(), 14 * 8 * 4);
        assert!(s.pending_damage.is_none(), "snapshot consumes the union");
    }

    #[test]
    fn damage_large_disabled_and_forced_paths_are_full() {
        for (enabled, force) in [(true, false), (false, false), (true, true)] {
            let mut s = FrameState::new();
            s.fb_w = 10;
            s.fb_h = 10;
            s.fb_stride = 40;
            s.fb = vec![7; 400];
            s.note_damage(0, 0, 6, 6); // 36% >= 35% threshold
            let snap = s.snapshot_damage_bgra(enabled, 35, force).unwrap();
            assert_eq!(
                snap.rect,
                Some(DamageRect {
                    x: 0,
                    y: 0,
                    w: 10,
                    h: 10
                })
            );
            assert_eq!(snap.bgra.len(), 400);
        }
    }

    #[test]
    fn repeated_small_damage_volume_triggers_full_then_resets() {
        let mut s = FrameState::new();
        s.fb_w = 20;
        s.fb_h = 10;
        s.fb_stride = 80;
        s.fb = vec![7; 800];

        // Each event and their spatial union cover only 10% of the frame, but
        // four repaints are 40% of a frame: video-like churn must go full at 35%.
        for _ in 0..4 {
            s.note_damage(2, 2, 4, 5);
        }
        let full = s.snapshot_damage_bgra(true, 35, false).unwrap();
        assert_eq!(
            full.rect,
            Some(DamageRect {
                x: 0,
                y: 0,
                w: 20,
                h: 10
            })
        );

        // Consuming the snapshot resets the volume counter, preserving the
        // partial-update fast path for the next isolated small repaint.
        s.note_damage(2, 2, 4, 5);
        let partial = s.snapshot_damage_bgra(true, 35, false).unwrap();
        assert_eq!(
            partial.rect,
            Some(DamageRect {
                x: 2,
                y: 2,
                w: 4,
                h: 6
            })
        );
    }
}
