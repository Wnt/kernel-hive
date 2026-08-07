// x264 FFI surface: the encoder-param builder, the encoder-handle RAII wrapper,
// and SPS profile/level extraction. Extracted verbatim from the old monolithic
// encode.rs / worker.rs. Stream-shape + param tests drive the real FFI. The
// encode-thread body that uses these lives in worker.rs.

use x264_sys as sys;

/// Owns an x264 encoder handle. Lives ENTIRELY on the dedicated encode thread
/// (created and dropped in worker_main), so no Send impl is needed any more.
/// Drop closes the encoder, freeing it on every exit / re-open path.
pub(super) struct X264Enc(pub(super) *mut sys::x264_t);
impl Drop for X264Enc {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { sys::x264_encoder_close(self.0) };
            self.0 = std::ptr::null_mut();
        }
    }
}

/// Build a fully-configured x264_param_t whose settings are IDENTICAL in effect
/// to the old `build_ffmpeg_args`. See the module header for the field-by-field
/// mapping. `use_cqp` (tier 0 only) selects CONSTANT-QP with NO VBV; otherwise
/// CRF + VBV. Profile is applied LAST (x264 CLI order) so it can clamp for the
/// target profile.
#[allow(clippy::too_many_arguments)]
pub(super) unsafe fn configure_param(
    out_w: i32,
    out_h: i32,
    fps_cap: u32,
    crf: u8,
    maxrate_kbps: u32,
    bufsize_kbps: u32,
    profile: &str,
    preset: &str,
    tune: &str,
    use_cqp: bool,
    threads: i32,
) -> anyhow::Result<sys::x264_param_t> {
    use std::ffi::CString;
    let c_preset = CString::new(preset)?;
    let c_tune = CString::new(tune)?;
    let mut par = std::mem::MaybeUninit::<sys::x264_param_t>::uninit();
    if sys::x264_param_default_preset(par.as_mut_ptr(), c_preset.as_ptr(), c_tune.as_ptr()) != 0 {
        anyhow::bail!("x264_param_default_preset failed (preset={preset} tune={tune})");
    }
    let mut par = par.assume_init();

    // Geometry + input colourspace (we feed planar I420 built from BGRA).
    par.i_width = out_w;
    par.i_height = out_h;
    par.i_csp = sys::X264_CSP_I420 as i32;
    par.i_bitdepth = 8;

    // SLICED threads: parallelism WITHIN a frame -> no added frame latency
    // (replaces the old `-threads 1`). NOTE: the encode-latency investigation
    // measured x264_encoder_encode at ~12 ms/frame here regardless of thread
    // mode (sliced i_threads=4, sliced i_threads=1, AND true-serial
    // b_sliced_threads=0 all landed ~12 ms wall), so slice threading is NOT the
    // latency source — see the CPU-vs-wall profile.
    par.i_threads = threads;
    par.b_sliced_threads = 1;
    par.i_lookahead_threads = 0;

    // zerolatency invariants — the `zerolatency` tune already sets these, but we
    // pin them explicitly so behaviour does not depend on preset/tune internals.
    par.i_bframe = 0;
    par.rc.i_lookahead = 0;
    par.i_sync_lookahead = 0;
    par.b_vfr_input = 0;

    // Keyint: matches `-g 300 -keyint_min 1 -sc_threshold 0`. x264's own scenecut
    // is OFF; the daemon does content scene detection itself (see run()).
    par.i_keyint_max = 300;
    par.i_keyint_min = 1;
    par.i_scenecut_threshold = 0;

    // Muxing: Annex-B start codes, SPS/PPS repeated before every IDR, no AUD.
    par.b_repeat_headers = 1;
    par.b_annexb = 1;
    par.b_aud = 0;

    // CFR ratecontrol timing for VBV (tier>=1). tier-0 CQP ignores fps entirely.
    par.i_fps_num = fps_cap.max(1);
    par.i_fps_den = 1;

    // Quiet, like the old `-loglevel error`.
    par.i_log_level = sys::X264_LOG_ERROR as i32;

    // RATE CONTROL — identical semantics to build_ffmpeg_args:
    //   tier 0  : constant QP, NO VBV (self-limits, no per-frame RC shimmer)
    //   tier>=1 : CRF + VBV, where the per-tier maxrate cap relieves a WAN link.
    if use_cqp {
        par.rc.i_rc_method = sys::X264_RC_CQP as i32;
        par.rc.i_qp_constant = crf as i32;
        // NO VBV: leave rc.i_vbv_max_bitrate / rc.i_vbv_buffer_size at 0 (off).
    } else {
        par.rc.i_rc_method = sys::X264_RC_CRF as i32;
        par.rc.f_rf_constant = crf as f32;
        par.rc.i_vbv_max_bitrate = maxrate_kbps as i32;
        par.rc.i_vbv_buffer_size = bufsize_kbps as i32;
    }

    // Profile LAST (validates/clamps for the target profile), matching x264 CLI.
    let c_profile = CString::new(profile)?;
    if sys::x264_param_apply_profile(&mut par, c_profile.as_ptr()) != 0 {
        anyhow::bail!("x264_param_apply_profile failed (profile={profile})");
    }
    Ok(par)
}

/// Find the SPS NAL (type 7) in an Annex-B AU and return (profile_idc, level_idc).
/// SPS payload layout after the 1-byte NAL header: profile_idc, constraint_flags,
/// level_idc. Used to publish the authoritative codec string.
pub(super) fn extract_sps_profile_level(data: &[u8]) -> Option<(u8, u8)> {
    let mut i = 0usize;
    while i + 3 < data.len() {
        let is3 = data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1;
        let is4 = data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1;
        if is3 || is4 {
            let hdr = if is4 { 4 } else { 3 };
            let nal_start = i + hdr; // byte 0 = NAL header
            let nal_type = data.get(nal_start).map(|b| b & 0x1f);
            if nal_type == Some(7) {
                // payload[0]=header, [1]=profile_idc, [2]=constraint, [3]=level_idc
                let pidc = *data.get(nal_start + 1)?;
                let lidc = *data.get(nal_start + 3)?;
                return Some((pidc, lidc));
            }
            i += hdr;
        } else {
            i += 1;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // Ordered list of Annex-B NAL types (5 bits) in an AU.
    fn nal_types(data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut i = 0usize;
        while i + 3 < data.len() {
            let is3 = data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1;
            let is4 = data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1;
            if is3 || is4 {
                let hdr = if is4 { 4 } else { 3 };
                out.push(data[i + hdr] & 0x1f);
                i += hdr;
            } else {
                i += 1;
            }
        }
        out
    }

    // Encode one I420 frame; return (annexb_au_bytes, b_keyframe, out_pts).
    #[allow(clippy::too_many_arguments)] // test helper mirroring the FFI call site
    unsafe fn encode_one(
        enc: *mut sys::x264_t,
        w: i32,
        _h: i32,
        y: &mut [u8],
        u: &mut [u8],
        v: &mut [u8],
        pts: i64,
        force_idr: bool,
    ) -> (Vec<u8>, bool, i64) {
        let cw = (w + 1) / 2;
        let mut pic_in: sys::x264_picture_t = std::mem::zeroed();
        pic_in.img.i_csp = sys::X264_CSP_I420 as i32;
        pic_in.img.i_plane = 3;
        pic_in.img.i_stride[0] = w;
        pic_in.img.i_stride[1] = cw;
        pic_in.img.i_stride[2] = cw;
        pic_in.img.plane[0] = y.as_mut_ptr();
        pic_in.img.plane[1] = u.as_mut_ptr();
        pic_in.img.plane[2] = v.as_mut_ptr();
        pic_in.i_pts = pts;
        pic_in.i_type = if force_idr {
            sys::X264_TYPE_IDR as i32
        } else {
            sys::X264_TYPE_AUTO as i32
        };
        let mut nal_ptr: *mut sys::x264_nal_t = std::ptr::null_mut();
        let mut nnal: std::os::raw::c_int = 0;
        let mut pic_out: sys::x264_picture_t = std::mem::zeroed();
        let fsize =
            sys::x264_encoder_encode(enc, &mut nal_ptr, &mut nnal, &mut pic_in, &mut pic_out);
        assert!(
            fsize > 0 && !nal_ptr.is_null(),
            "zerolatency encode must return a frame immediately (fsize={fsize})"
        );
        let bytes =
            std::slice::from_raw_parts((*nal_ptr).p_payload as *const u8, fsize as usize).to_vec();
        (bytes, pic_out.b_keyframe != 0, pic_out.i_pts)
    }

    // Drives the REAL configure_param()/x264 FFI path to prove the emitted stream:
    //   * IDR leads with SPS(7)+PPS(8)+IDR(5)  (repeat-headers, Annex-B)
    //   * a following static frame is a plain P slice (NAL 1), b_keyframe=0
    //   * output pts == input pts, in order (no reorder — b-frames off)
    //   * a forced IDR re-emits SPS+PPS+IDR (client re-sync guarantee)
    #[test]
    fn tier0_cqp_stream_shape() {
        let (w, h) = (64i32, 64i32);
        let mut par = unsafe {
            configure_param(
                w,
                h,
                60,
                23,
                0,
                0,
                "high",
                "veryfast",
                "zerolatency",
                true,
                2,
            )
            .unwrap()
        };
        // tier-0 => CQP, no VBV.
        assert_eq!(par.rc.i_rc_method, sys::X264_RC_CQP as i32);
        assert_eq!(par.rc.i_qp_constant, 23);
        assert_eq!(par.rc.i_vbv_max_bitrate, 0);
        assert_eq!(par.rc.i_vbv_buffer_size, 0);
        // low-latency invariants + sliced threads
        assert_eq!(par.i_bframe, 0);
        assert_eq!(par.rc.i_lookahead, 0);
        assert_eq!(par.i_sync_lookahead, 0);
        assert_eq!(par.b_sliced_threads, 1);
        assert_eq!(par.i_threads, 2);
        assert_eq!(par.b_repeat_headers, 1);
        assert_eq!(par.b_annexb, 1);
        assert_eq!(par.i_scenecut_threshold, 0);

        let enc = unsafe { sys::x264_encoder_open(&mut par) };
        assert!(!enc.is_null());
        let cw = ((w + 1) / 2) as usize;
        let mut y = vec![128u8; (w * h) as usize];
        let mut u = vec![128u8; cw * cw];
        let mut v = vec![128u8; cw * cw];

        // Frame 0: expect IDR led by SPS(7),PPS(8),IDR(5).
        let (au0, key0, p0) = unsafe { encode_one(enc, w, h, &mut y, &mut u, &mut v, 0, false) };
        let t0 = nal_types(&au0);
        assert!(key0, "first frame must be a keyframe");
        assert_eq!(p0, 0, "no reorder: out pts == in pts");
        let sps = t0.iter().position(|&n| n == 7).expect("SPS present");
        let pps = t0.iter().position(|&n| n == 8).expect("PPS present");
        let idr = t0.iter().position(|&n| n == 5).expect("IDR present");
        assert!(sps < pps && pps < idr, "must lead SPS<PPS<IDR, got {t0:?}");

        // Frame 1 (identical): expect a plain P slice, not a keyframe.
        let (au1, key1, p1) = unsafe { encode_one(enc, w, h, &mut y, &mut u, &mut v, 1, false) };
        let t1 = nal_types(&au1);
        assert!(!key1, "static follow-up frame must not be a keyframe");
        assert_eq!(p1, 1, "no reorder: out pts == in pts");
        assert!(
            t1.contains(&1) && !t1.contains(&5),
            "expected P slice (NAL 1), got {t1:?}"
        );

        // Frame 2: FORCE IDR -> SPS+PPS+IDR again (re-sync).
        let (au2, key2, _) = unsafe { encode_one(enc, w, h, &mut y, &mut u, &mut v, 2, true) };
        let t2 = nal_types(&au2);
        assert!(key2, "forced frame must be a keyframe");
        assert!(
            t2.contains(&7) && t2.contains(&8) && t2.contains(&5),
            "forced IDR must repeat SPS+PPS+IDR, got {t2:?}"
        );

        unsafe { sys::x264_encoder_close(enc) };
    }

    // tier>=1 selects CRF + VBV with the per-tier maxrate/bufsize cap.
    #[test]
    fn tier1_crf_vbv_params() {
        let par = unsafe {
            configure_param(
                320,
                240,
                60,
                17,
                8000,
                8000,
                "high",
                "veryfast",
                "zerolatency",
                false,
                4,
            )
            .unwrap()
        };
        assert_eq!(par.rc.i_rc_method, sys::X264_RC_CRF as i32);
        assert_eq!(par.rc.f_rf_constant, 17.0);
        assert_eq!(par.rc.i_vbv_max_bitrate, 8000);
        assert_eq!(par.rc.i_vbv_buffer_size, 8000);
        assert_eq!(par.b_sliced_threads, 1);
        assert_eq!(par.i_threads, 4);
    }
}
