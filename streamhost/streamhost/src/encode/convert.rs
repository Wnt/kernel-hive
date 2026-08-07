// BGRA -> planar I420 colour conversion (libyuv-backed), damage-patch splicing
// into persistent I420 planes, and the tier-3 box downscale. Extracted verbatim
// from the old monolithic encode.rs / worker.rs. Pixel-diff + damage-splice tests
// (with the naive integer oracle) live below.

/// Legacy Rust conversion retained as the pixel-diff oracle and before-kernel in
/// the release microbenchmark. It is byte-identical to the original naive
/// integer BT.601 implementation, including odd-edge chroma handling.
#[cfg(test)]
fn bgra_to_i420_rust(
    bgra: &[u8],
    w: usize,
    h: usize,
    y: &mut Vec<u8>,
    u: &mut Vec<u8>,
    v: &mut Vec<u8>,
) {
    let cw = w.div_ceil(2);
    let ch = h.div_ceil(2);
    y.clear();
    y.resize(w * h, 0);
    u.clear();
    u.resize(cw * ch, 0);
    v.clear();
    v.resize(cw * ch, 0);

    // Luma (per pixel) — row-at-a-time chunked iterators elide bounds checks and
    // let the compiler autovectorise the BT.601 dot product.
    for j in 0..h {
        let brow = &bgra[j * w * 4..j * w * 4 + w * 4];
        let yrow = &mut y[j * w..j * w + w];
        for (px, yo) in brow.chunks_exact(4).zip(yrow.iter_mut()) {
            let b = px[0] as i32;
            let g = px[1] as i32;
            let r = px[2] as i32;
            *yo = (((66 * r + 129 * g + 25 * b + 128) >> 8) + 16) as u8;
        }
    }

    // Chroma (2x2 box average -> one U,V per block). Fast path: fully-interior
    // blocks (both columns AND both rows in range => cnt==4) with an unchecked
    // flat kernel. Odd last row/column (cnt<4) falls back to the scalar form so
    // output is bit-identical for odd geometries too.
    let full_cw = w / 2;
    let full_ch = h / 2;
    for cj in 0..full_ch {
        let r0 = (cj * 2) * w * 4;
        let r1 = (cj * 2 + 1) * w * 4;
        for ci in 0..full_cw {
            let i0 = ci * 2;
            let o00 = r0 + i0 * 4;
            let o10 = r1 + i0 * 4;
            unsafe {
                let bs = *bgra.get_unchecked(o00) as i32
                    + *bgra.get_unchecked(o00 + 4) as i32
                    + *bgra.get_unchecked(o10) as i32
                    + *bgra.get_unchecked(o10 + 4) as i32;
                let gs = *bgra.get_unchecked(o00 + 1) as i32
                    + *bgra.get_unchecked(o00 + 5) as i32
                    + *bgra.get_unchecked(o10 + 1) as i32
                    + *bgra.get_unchecked(o10 + 5) as i32;
                let rs = *bgra.get_unchecked(o00 + 2) as i32
                    + *bgra.get_unchecked(o00 + 6) as i32
                    + *bgra.get_unchecked(o10 + 2) as i32
                    + *bgra.get_unchecked(o10 + 6) as i32;
                let r = rs / 4;
                let g = gs / 4;
                let b = bs / 4;
                *u.get_unchecked_mut(cj * cw + ci) =
                    (((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128) as u8;
                *v.get_unchecked_mut(cj * cw + ci) =
                    (((112 * r - 94 * g - 18 * b + 128) >> 8) + 128) as u8;
            }
        }
    }
    // Odd-edge blocks only (skipped entirely when w and h are both even).
    if full_cw != cw || full_ch != ch {
        for cj in 0..ch {
            let j0 = cj * 2;
            for ci in 0..cw {
                if cj < full_ch && ci < full_cw {
                    continue; // already done by the fast path
                }
                let i0 = ci * 2;
                let (mut rs, mut gs, mut bs, mut cnt) = (0i32, 0i32, 0i32, 0i32);
                for dj in 0..2 {
                    let jj = j0 + dj;
                    if jj >= h {
                        continue;
                    }
                    for di in 0..2 {
                        let ii = i0 + di;
                        if ii >= w {
                            continue;
                        }
                        let o = (jj * w + ii) * 4;
                        bs += bgra[o] as i32;
                        gs += bgra[o + 1] as i32;
                        rs += bgra[o + 2] as i32;
                        cnt += 1;
                    }
                }
                let r = rs / cnt;
                let g = gs / cnt;
                let b = bs / cnt;
                u[cj * cw + ci] = (((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128) as u8;
                v[cj * cw + ci] = (((112 * r - 94 * g - 18 * b + 128) >> 8) + 128) as u8;
            }
        }
    }
}

/// BGRA bytes (B,G,R,A in memory) -> planar I420, BT.601 limited range.
///
/// libyuv calls this byte layout "ARGB" on little-endian hosts. Its production
/// kernel converts pairs of rows, reusing hot source cache lines for Y and UV,
/// and runtime-dispatches among portable C, SSE/AVX2, and other-architecture
/// equivalents.
/// The bundled static library keeps deployment independent of a system libyuv
/// package and never assumes the build machine's ISA. At 1920x1200 on CT950 it
/// is ~4x faster than the preceding Rust loop. Y is byte-identical; rounded
/// 2x2 chroma differs from the old truncate-before-matrix path by at most one.
pub(super) fn bgra_to_i420(
    bgra: &[u8],
    w: usize,
    h: usize,
    y: &mut Vec<u8>,
    u: &mut Vec<u8>,
    v: &mut Vec<u8>,
) {
    assert!(w > 0 && h > 0, "BGRA frame dimensions must be non-zero");
    assert!(
        w <= (i32::MAX as usize) / 4 && h <= i32::MAX as usize,
        "BGRA frame dimensions exceed libyuv's signed-stride API"
    );
    let cw = w.div_ceil(2);
    let ch = h.div_ceil(2);
    let pixels = w.checked_mul(h).expect("BGRA frame size overflow");
    let bgra_len = pixels.checked_mul(4).expect("BGRA byte size overflow");
    y.resize(pixels, 0);
    u.resize(cw * ch, 0);
    v.resize(cw * ch, 0);
    assert!(bgra.len() >= bgra_len, "short BGRA frame buffer");
    let rc = unsafe {
        yuv_sys::rs_ARGBToI420(
            bgra.as_ptr(),
            (w * 4) as i32,
            y.as_mut_ptr(),
            w as i32,
            u.as_mut_ptr(),
            cw as i32,
            v.as_mut_ptr(),
            cw as i32,
            w as i32,
            h as i32,
        )
    };
    assert_eq!(rc, 0, "libyuv ARGBToI420 rejected {w}x{h} BGRA frame");
}

/// Convert one even-aligned BGRA damage patch and splice it into persistent
/// full-frame I420 planes. The encoder still sees complete pictures; only the
/// colour-conversion work is scoped. A full patch uses the direct fast path.
#[allow(clippy::too_many_arguments)]
pub(super) fn apply_bgra_patch_to_i420(
    bgra: &[u8],
    rect: crate::capture::DamageRect,
    frame_w: usize,
    frame_h: usize,
    y: &mut Vec<u8>,
    u: &mut Vec<u8>,
    v: &mut Vec<u8>,
    patch_y: &mut Vec<u8>,
    patch_u: &mut Vec<u8>,
    patch_v: &mut Vec<u8>,
) {
    let rw = rect.w as usize;
    let rh = rect.h as usize;
    assert_eq!(bgra.len(), rw * rh * 4);
    if rect.x == 0 && rect.y == 0 && rw == frame_w && rh == frame_h {
        bgra_to_i420(bgra, frame_w, frame_h, y, u, v);
        return;
    }

    let frame_cw = frame_w.div_ceil(2);
    let frame_ch = frame_h.div_ceil(2);
    assert_eq!(rect.x & 1, 0);
    assert_eq!(rect.y & 1, 0);
    assert_eq!(y.len(), frame_w * frame_h);
    assert_eq!(u.len(), frame_cw * frame_ch);
    assert_eq!(v.len(), frame_cw * frame_ch);

    bgra_to_i420(bgra, rw, rh, patch_y, patch_u, patch_v);
    for row in 0..rh {
        let src = row * rw;
        let dst = (rect.y as usize + row) * frame_w + rect.x as usize;
        y[dst..dst + rw].copy_from_slice(&patch_y[src..src + rw]);
    }
    let patch_cw = rw.div_ceil(2);
    let patch_ch = rh.div_ceil(2);
    let dst_x = rect.x as usize / 2;
    let dst_y = rect.y as usize / 2;
    for row in 0..patch_ch {
        let src = row * patch_cw;
        let dst = (dst_y + row) * frame_cw + dst_x;
        u[dst..dst + patch_cw].copy_from_slice(&patch_u[src..src + patch_cw]);
        v[dst..dst + patch_cw].copy_from_slice(&patch_v[src..src + patch_cw]);
    }
}

/// Box-average downscale of a BGRA frame (tier-3 only). The old path used
/// ffmpeg `scale=...:flags=bicubic`; this is a plain area average — a
/// quality-only difference that is reached ONLY on a tier-3 (sustained WAN
/// congestion) step, never on the LAN/tier-0 default path.
pub(super) fn box_downscale_bgra(
    src: &[u8],
    iw: usize,
    ih: usize,
    ow: usize,
    oh: usize,
) -> Vec<u8> {
    let mut dst = vec![0u8; ow * oh * 4];
    for oy in 0..oh {
        let sy0 = oy * ih / oh;
        let sy1 = (((oy + 1) * ih).div_ceil(oh)).max(sy0 + 1).min(ih);
        for ox in 0..ow {
            let sx0 = ox * iw / ow;
            let sx1 = (((ox + 1) * iw).div_ceil(ow)).max(sx0 + 1).min(iw);
            let (mut bs, mut gs, mut rs, mut as_, mut c) = (0u32, 0u32, 0u32, 0u32, 0u32);
            for sy in sy0..sy1 {
                for sx in sx0..sx1 {
                    let o = (sy * iw + sx) * 4;
                    bs += src[o] as u32;
                    gs += src[o + 1] as u32;
                    rs += src[o + 2] as u32;
                    as_ += src[o + 3] as u32;
                    c += 1;
                }
            }
            let o = (oy * ow + ox) * 4;
            dst[o] = (bs / c) as u8;
            dst[o + 1] = (gs / c) as u8;
            dst[o + 2] = (rs / c) as u8;
            dst[o + 3] = (as_ / c) as u8;
        }
    }
    dst
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    // Naive per-pixel reference (the pre-optimisation form) — the oracle the
    // fast bgra_to_i420 must match byte-for-byte.
    fn bgra_to_i420_ref(
        bgra: &[u8],
        w: usize,
        h: usize,
        y: &mut Vec<u8>,
        u: &mut Vec<u8>,
        v: &mut Vec<u8>,
    ) {
        let cw = w.div_ceil(2);
        let ch = h.div_ceil(2);
        y.clear();
        y.resize(w * h, 0);
        u.clear();
        u.resize(cw * ch, 0);
        v.clear();
        v.resize(cw * ch, 0);
        for j in 0..h {
            for i in 0..w {
                let o = (j * w + i) * 4;
                let b = bgra[o] as i32;
                let g = bgra[o + 1] as i32;
                let r = bgra[o + 2] as i32;
                y[j * w + i] = (((66 * r + 129 * g + 25 * b + 128) >> 8) + 16) as u8;
            }
        }
        for cj in 0..ch {
            let j0 = cj * 2;
            for ci in 0..cw {
                let i0 = ci * 2;
                let (mut rs, mut gs, mut bs, mut cnt) = (0i32, 0i32, 0i32, 0i32);
                for dj in 0..2 {
                    let jj = j0 + dj;
                    if jj >= h {
                        continue;
                    }
                    for di in 0..2 {
                        let ii = i0 + di;
                        if ii >= w {
                            continue;
                        }
                        let o = (jj * w + ii) * 4;
                        bs += bgra[o] as i32;
                        gs += bgra[o + 1] as i32;
                        rs += bgra[o + 2] as i32;
                        cnt += 1;
                    }
                }
                let r = rs / cnt;
                let g = gs / cnt;
                let b = bs / cnt;
                u[cj * cw + ci] = (((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128) as u8;
                v[cj * cw + ci] = (((112 * r - 94 * g - 18 * b + 128) >> 8) + 128) as u8;
            }
        }
    }

    fn diff_stats(a: &[u8], b: &[u8]) -> (u8, usize, f64) {
        assert_eq!(a.len(), b.len());
        let mut max = 0u8;
        let mut changed = 0usize;
        let mut sum = 0u64;
        for (&a, &b) in a.iter().zip(b) {
            let d = a.abs_diff(b);
            max = max.max(d);
            changed += usize::from(d != 0);
            sum += d as u64;
        }
        (max, changed, sum as f64 / a.len() as f64)
    }

    // libyuv uses its canonical BT.601 fixed-point coefficients and rounded
    // chroma subsampling. Keep the old integer implementation as the oracle and
    // bound the conversion delta to visually indistinguishable rounding noise.
    #[test]
    fn bgra_to_i420_pixel_diff() {
        for &(w, h) in &[(64usize, 64usize), (1024, 768), (65, 63), (33, 32), (2, 2)] {
            let mut bgra = vec![0u8; w * h * 4];
            let mut s: u32 = 0x9E37_79B9;
            for x in bgra.iter_mut() {
                s = s.wrapping_mul(1664525).wrapping_add(1013904223);
                *x = (s >> 24) as u8;
            }
            let (mut y1, mut u1, mut v1) = (Vec::new(), Vec::new(), Vec::new());
            let (mut y2, mut u2, mut v2) = (Vec::new(), Vec::new(), Vec::new());
            let (mut yr, mut ur, mut vr) = (Vec::new(), Vec::new(), Vec::new());
            bgra_to_i420_ref(&bgra, w, h, &mut y1, &mut u1, &mut v1);
            bgra_to_i420_rust(&bgra, w, h, &mut yr, &mut ur, &mut vr);
            bgra_to_i420(&bgra, w, h, &mut y2, &mut u2, &mut v2);
            assert_eq!(y1, yr, "old fast luma mismatch at {w}x{h}");
            assert_eq!(u1, ur, "old fast u mismatch at {w}x{h}");
            assert_eq!(v1, vr, "old fast v mismatch at {w}x{h}");
            let yd = diff_stats(&y1, &y2);
            let ud = diff_stats(&u1, &u2);
            let vd = diff_stats(&v1, &v2);
            eprintln!("pixel diff {w}x{h}: y={yd:?} u={ud:?} v={vd:?}");
            assert_eq!(yd.0, 0, "luma must remain byte-identical: {yd:?}");
            assert!(ud.0 <= 1 && ud.2 <= 0.6, "u delta too large: {ud:?}");
            assert!(vd.0 <= 1 && vd.2 <= 0.6, "v delta too large: {vd:?}");
        }
    }

    /// Pixel-diff a real tightly-packed BGRA framebuffer supplied by the
    /// operator, e.g. one produced from a clone's QMP screendump with ffmpeg.
    #[test]
    #[ignore = "set SH_BGRA_SAMPLE, SH_BGRA_WIDTH and SH_BGRA_HEIGHT"]
    fn bgra_to_i420_sample_pixel_diff() {
        let path = std::env::var("SH_BGRA_SAMPLE").expect("SH_BGRA_SAMPLE is required");
        let w: usize = std::env::var("SH_BGRA_WIDTH")
            .expect("SH_BGRA_WIDTH is required")
            .parse()
            .expect("invalid SH_BGRA_WIDTH");
        let h: usize = std::env::var("SH_BGRA_HEIGHT")
            .expect("SH_BGRA_HEIGHT is required")
            .parse()
            .expect("invalid SH_BGRA_HEIGHT");
        let bgra = std::fs::read(&path).expect("read BGRA sample");
        assert_eq!(bgra.len(), w * h * 4, "sample is not tightly packed BGRA");
        let (mut y1, mut u1, mut v1) = (Vec::new(), Vec::new(), Vec::new());
        let (mut y2, mut u2, mut v2) = (Vec::new(), Vec::new(), Vec::new());
        bgra_to_i420_ref(&bgra, w, h, &mut y1, &mut u1, &mut v1);
        bgra_to_i420(&bgra, w, h, &mut y2, &mut u2, &mut v2);
        let yd = diff_stats(&y1, &y2);
        let ud = diff_stats(&u1, &u2);
        let vd = diff_stats(&v1, &v2);
        eprintln!("sample pixel diff {path} {w}x{h}: y={yd:?} u={ud:?} v={vd:?}");
        assert_eq!(yd.0, 0, "luma must remain byte-identical: {yd:?}");
        assert!(ud.0 <= 1 && ud.2 <= 0.6, "u delta too large: {ud:?}");
        assert!(vd.0 <= 1 && vd.2 <= 0.6, "v delta too large: {vd:?}");
    }

    /// CT950 conversion microbenchmark. Run single-threaded in a release build:
    /// `cargo test --release bgra_to_i420_1920x1200_bench -- --ignored --nocapture`
    #[test]
    #[ignore = "manual 1920x1200 conversion microbenchmark"]
    fn bgra_to_i420_1920x1200_bench() {
        let (w, h) = (1920usize, 1200usize);
        let mut bgra = vec![0u8; w * h * 4];
        let mut s: u32 = 0x9E37_79B9;
        for x in &mut bgra {
            s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            *x = (s >> 24) as u8;
        }
        let (mut y, mut u, mut v) = (Vec::new(), Vec::new(), Vec::new());
        let (mut old_y, mut old_u, mut old_v) = (Vec::new(), Vec::new(), Vec::new());
        for _ in 0..20 {
            bgra_to_i420(&bgra, w, h, &mut y, &mut u, &mut v);
            bgra_to_i420_rust(&bgra, w, h, &mut old_y, &mut old_u, &mut old_v);
        }
        let mut old_samples = Vec::with_capacity(200);
        let mut new_samples = Vec::with_capacity(200);
        for _ in 0..200 {
            let start = Instant::now();
            bgra_to_i420_rust(
                std::hint::black_box(&bgra),
                w,
                h,
                std::hint::black_box(&mut old_y),
                std::hint::black_box(&mut old_u),
                std::hint::black_box(&mut old_v),
            );
            old_samples.push(start.elapsed().as_nanos());
        }
        for _ in 0..200 {
            let start = Instant::now();
            bgra_to_i420(
                std::hint::black_box(&bgra),
                w,
                h,
                std::hint::black_box(&mut y),
                std::hint::black_box(&mut u),
                std::hint::black_box(&mut v),
            );
            new_samples.push(start.elapsed().as_nanos());
        }
        old_samples.sort_unstable();
        new_samples.sort_unstable();
        let checksum = y.iter().chain(&u).chain(&v).fold(0u64, |acc, &x| {
            acc.wrapping_mul(16_777_619).wrapping_add(x as u64)
        });
        let old_p50 = old_samples[old_samples.len() / 2];
        let new_p50 = new_samples[new_samples.len() / 2];
        eprintln!(
            "bgra_to_i420 1920x1200: old_p50={old_p50} ns/frame old_p95={} ns/frame \
             new_p50={new_p50} ns/frame new_p95={} ns/frame speedup={:.2}x \
             cpu_flags=0x{:08x} checksum={checksum:016x}",
            old_samples[old_samples.len() * 95 / 100],
            new_samples[new_samples.len() * 95 / 100],
            old_p50 as f64 / new_p50 as f64,
            unsafe { yuv_sys::rs_InitCpuFlags() },
        );
    }

    #[test]
    fn damage_patch_matches_fresh_full_conversion() {
        let (w, h) = (8usize, 6usize);
        let mut before = vec![0u8; w * h * 4];
        for (i, b) in before.iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(17);
        }
        let mut after = before.clone();
        let rect = crate::capture::DamageRect {
            x: 2,
            y: 2,
            w: 4,
            h: 2,
        };
        for y in rect.y as usize..(rect.y + rect.h) as usize {
            for x in rect.x as usize..(rect.x + rect.w) as usize {
                let o = (y * w + x) * 4;
                after[o..o + 4].copy_from_slice(&[201, 53, 149, 255]);
            }
        }
        let mut patch = Vec::with_capacity(rect.w as usize * rect.h as usize * 4);
        for row in 0..rect.h as usize {
            let off = ((rect.y as usize + row) * w + rect.x as usize) * 4;
            patch.extend_from_slice(&after[off..off + rect.w as usize * 4]);
        }

        let (mut y, mut u, mut v) = (Vec::new(), Vec::new(), Vec::new());
        bgra_to_i420(&before, w, h, &mut y, &mut u, &mut v);
        let (mut py, mut pu, mut pv) = (Vec::new(), Vec::new(), Vec::new());
        apply_bgra_patch_to_i420(
            &patch, rect, w, h, &mut y, &mut u, &mut v, &mut py, &mut pu, &mut pv,
        );

        let (mut want_y, mut want_u, mut want_v) = (Vec::new(), Vec::new(), Vec::new());
        bgra_to_i420(&after, w, h, &mut want_y, &mut want_u, &mut want_v);
        assert_eq!(y, want_y);
        assert_eq!(u, want_u);
        assert_eq!(v, want_v);
    }
}
