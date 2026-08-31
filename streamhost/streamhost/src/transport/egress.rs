// Transport egress: SERVER->CLIENT uni-stream framing. One access unit / packet
// / params record per unidirectional QUIC stream, each led by the 1-byte KIND
// prefix the client routes on (see the module doc in `mod.rs`). Split out of the
// session core as a pure framing seam — byte-for-byte identical to the inline
// version; only the enclosing module changed.

use anyhow::Result;

use crate::encode::PublishedParams;
use crate::trace::Ctx;

const KIND_VIDEO: u8 = 1;
const KIND_AUDIO: u8 = 2;
// SERVER->CLIENT encoder-params / server-stats push (SECTION 3.2). Subtype byte
// selects the payload: 1 = encoder-params (on tier change / at connect),
// 2 = server-stats for the HUD (1 Hz per session), 3 = sampled-input
// frame-trace mark (return-path tracing, see `spawn_frame_mark` below).
const KIND_PARAMS: u8 = 3;

pub(super) async fn send_au(conn: &wtransport::Connection, au: &crate::encode::Au) -> Result<()> {
    let vt = super::video_trace();
    let mut buf = Vec::with_capacity(10 + au.data.len());
    buf.push(KIND_VIDEO);
    buf.extend_from_slice(&au.frame_id.to_le_bytes());
    buf.push(if au.is_key { 1 } else { 0 });
    buf.extend_from_slice(&au.capture_ts_us.to_le_bytes());
    buf.extend_from_slice(&au.data);
    if vt {
        eprintln!("[vtrace] send_au f={} opening uni", au.frame_id);
    }
    let pending = conn.open_uni().await?;
    if vt {
        eprintln!(
            "[vtrace] send_au f={} open_uni ok, awaiting grant",
            au.frame_id
        );
    }
    let mut stream = pending.await?;
    if vt {
        eprintln!(
            "[vtrace] send_au f={} stream granted, writing {}",
            au.frame_id,
            buf.len()
        );
    }
    stream.write_all(&buf).await?;
    stream.finish().await?;
    if vt {
        eprintln!("[vtrace] send_au f={} finished", au.frame_id);
    }
    Ok(())
}

pub(super) async fn send_audio(
    conn: &wtransport::Connection,
    pkt: &crate::audio::AudioPacket,
) -> Result<()> {
    let mut buf = Vec::with_capacity(9 + pkt.data.len());
    buf.push(KIND_AUDIO);
    buf.extend_from_slice(&pkt.seq.to_le_bytes());
    buf.extend_from_slice(&pkt.ts_us.to_le_bytes());
    buf.extend_from_slice(&pkt.data);
    let mut stream = conn.open_uni().await?.await?;
    stream.write_all(&buf).await?;
    stream.finish().await?;
    Ok(())
}

/// KIND_PARAMS subtype 1 — encoder-params (SECTION 3.2), 22 bytes, little-endian
/// (the original 18-byte record + a 4-byte native-geometry tail). Pushed at connect
/// and on every tier change / first-SPS refinement.
pub(super) async fn send_params_encoder(
    conn: &wtransport::Connection,
    p: &PublishedParams,
) -> Result<()> {
    let mut buf = Vec::with_capacity(22);
    buf.push(KIND_PARAMS);
    buf.push(1u8); // subtype
    buf.push(p.tier);
    buf.extend_from_slice(&p.width.to_le_bytes());
    buf.extend_from_slice(&p.height.to_le_bytes());
    buf.extend_from_slice(&p.target_kbps.to_le_bytes());
    buf.push(p.crf);
    buf.push(p.fps_cap.min(255) as u8);
    buf.extend_from_slice(&p.keyframe_ms.to_le_bytes());
    buf.push(p.profile_idc);
    buf.push(p.level_idc);
    buf.push(p.preset_enum);
    // NATIVE-geometry tail: the real capture geometry BEFORE any ABR tier-3
    // downscale (`width`/`height` above are the EFFECTIVE encoded size). The HUD
    // uses it to show a genuine "native → stepped" indicator instead of trusting
    // the hardcoded signaling.json 1280×800. Appended after the 18-byte core so an
    // older UI that reads only the fixed record ignores the tail harmlessly.
    buf.extend_from_slice(&p.native_width.to_le_bytes());
    buf.extend_from_slice(&p.native_height.to_le_bytes());
    let mut stream = conn.open_uni().await?.await?;
    stream.write_all(&buf).await?;
    stream.finish().await?;
    Ok(())
}

/// KIND_PARAMS subtype 2 — server-stats for the HUD (SECTION 3.2), 32 bytes,
/// little-endian (the 28-byte core + a 4-byte skip-counter tail). Emitted 1 Hz per
/// session. TODO: `qp` is still hardcoded 0xFF — the in-process encoder could
/// surface a real per-frame QP (x264 pic_out) but it has never been wired; the HUD
/// treats 0xFF as "unknown".
///
/// L-1 TAIL: `skipped_frames` (cumulative per-session egress skips) is appended
/// AFTER the 26-byte core body so an older UI that reads only the fixed record
/// ignores it harmlessly (same additive-tail contract as subtype-1's native
/// geometry). The client subtracts its delta from its gap-derived loss so a
/// backlog skip stops masquerading as network loss in the banner and the report.
#[allow(clippy::too_many_arguments)]
pub(super) async fn send_params_stats(
    conn: &wtransport::Connection,
    p: &PublishedParams,
    measured_send_kbps: u32,
    path_rtt_us: u32,
    path_cwnd: u32,
    path_lost: u32,
    latency_score: u8,
    loss_score: u8,
    bandwidth_score: u8,
    overall_score: u8,
    skipped_frames: u32,
) -> Result<()> {
    let mut buf = Vec::with_capacity(32);
    buf.push(KIND_PARAMS);
    buf.push(2u8); // subtype
    buf.push(p.tier);
    buf.extend_from_slice(&p.target_kbps.to_le_bytes());
    buf.extend_from_slice(&measured_send_kbps.to_le_bytes());
    buf.extend_from_slice(&path_rtt_us.to_le_bytes());
    buf.extend_from_slice(&path_cwnd.to_le_bytes());
    buf.extend_from_slice(&path_lost.to_le_bytes());
    buf.push(latency_score);
    buf.push(loss_score);
    buf.push(bandwidth_score);
    buf.push(overall_score);
    buf.push(0xFFu8); // qp — never wired; 0xFF = "unknown" to the HUD (see fn doc)
    buf.extend_from_slice(&skipped_frames.to_le_bytes()); // L-1 tail (append-only)
    let mut stream = conn.open_uni().await?.await?;
    stream.write_all(&buf).await?;
    stream.finish().await?;
    Ok(())
}

/// KIND_PARAMS subtype 3 — sampled-input frame-trace mark (the return-path
/// extension, `docs/lab/TRACE-CONTEXT.md` §3.2/§8.1; `trace_session.rs`'s
/// "RETURN LEG" doc comment). Sent ONLY for the one AU that answers a
/// sampled input edge — `effect_sent` returns `Some` at most once per
/// pending edge, so this stream opens roughly once per `SAMPLE_N` input
/// edges, never per frame.
///
/// 30 bytes: KIND(1) + subtype(1) + frame_id (u32 LE, matching every other
/// frame_id field on this wire) + trace-id (16 BE) + span-id (8 BE). The
/// trace/span halves are BIG-endian, matching `input_trace.rs`'s own suffix
/// encoding rather than this file's LE convention for numeric fields — both
/// exist so a byte range can be read straight into the hex string a
/// `traceparent` already uses, which is worth more than one file being
/// internally uniform.
///
/// WHY A SEPARATE STREAM AND NOT A LONGER VIDEO-AU HEADER. The AU header
/// (`send_au` above) is followed immediately by an arbitrary-length Annex-B
/// payload with no length prefix — the uni-stream's own close IS the
/// end-of-payload marker. Inserting a variable-length suffix between a fixed
/// header and that payload would need a NEW length field on every AU, which
/// is not additive (an old client reading the old fixed offsets would decode
/// the marker bytes as bitstream and could corrupt or crash that one frame's
/// decode). KIND_PARAMS is additive on purpose: an old client's `handleStream`
/// routes on the KIND byte and its `handleParamsStream` drains an unrecognised
/// SUBTYPE (`else { await br.readToEnd(); }`, `videoDecode.ts`) — this is the
/// same extensibility point subtypes 1 and 2 already use for encoder-params
/// and HUD stats, not a new mechanism.
///
/// WHY SPAWNED rather than awaited inline in the egress loop: this stream is
/// allowed to be slow or to fail without slowing or failing the video AU it
/// describes — the mark is a bonus fact about a frame that is already on its
/// way, never a gate on sending it. `conn` is owned (cloned by the caller)
/// so the task outlives the call that spawned it.
pub(super) fn spawn_frame_mark(
    conn: std::sync::Arc<wtransport::Connection>,
    ctx: Ctx,
    frame_id: u32,
) {
    tokio::spawn(async move {
        let mut buf = Vec::with_capacity(30);
        buf.push(KIND_PARAMS);
        buf.push(3u8); // subtype
        buf.extend_from_slice(&frame_id.to_le_bytes());
        buf.extend_from_slice(&ctx.trace.to_be_bytes());
        buf.extend_from_slice(&ctx.span.to_be_bytes());
        let Ok(pending) = conn.open_uni().await else {
            return;
        };
        let Ok(mut stream) = pending.await else {
            return;
        };
        let _ = stream.write_all(&buf).await;
        let _ = stream.finish().await;
    });
}
