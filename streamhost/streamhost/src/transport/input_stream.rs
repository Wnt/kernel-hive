// Transport reliable-input ingress: draining CLIENT->SERVER reliable input
// streams (both the legacy single bidi and the per-type uni class streams) into
// input::handle. Split out of the session core as the CLIENT->SERVER framing
// seam — byte-for-byte identical to the inline version; only the enclosing
// module changed.

use std::sync::Arc;

use crate::capture::Capture;
use crate::config::Config;
use crate::input;

// CLIENT->SERVER per-type reliable-input CLASS tags: the first byte of each
// client-opened unidirectional reliable input stream (per-type QUIC input streams,
// HOL avoidance). These live in the client-opened-uni-stream tag namespace and are
// independent of the SERVER->CLIENT KIND_* tags. input::handle still routes
// by the record's own type byte, so the tag only selects which ordered stream a
// class rides — it is validated for logging but not needed for dispatch.
const ICLASS_KEY: u8 = 1;
const ICLASS_BUTTON: u8 = 2;
const ICLASS_WHEEL: u8 = 3;
const ICLASS_CONTROL: u8 = 4;

fn input_class_name(tag: u8) -> &'static str {
    match tag {
        ICLASS_KEY => "keyboard",
        ICLASS_BUTTON => "mouse-button",
        ICLASS_WHEEL => "wheel",
        ICLASS_CONTROL => "urgent-control",
        _ => "unknown",
    }
}

/// Drain a client-opened reliable input stream, dispatching every length-prefixed
/// record to input::handle in stream order. Shared by the legacy bidi loop and the
/// per-type uni loop. When `has_tag` is set (per-type uni streams), the very first
/// byte of the stream is consumed as the 1-byte input-CLASS tag before the record
/// framing begins; the legacy bidi framing has no such prefix. Records are
/// self-describing (rec[0] is the input type), so the tag is only used to name the
/// class — dispatch stays identical to the single-stream path.
pub(super) async fn drain_input_stream(
    mut recv: wtransport::RecvStream,
    cap: &Capture,
    cfg: &Config,
    mouse: &input::SharedMouse,
    input_router: Option<&Arc<crate::realtime_input::InputRouter>>,
    has_tag: bool,
) {
    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 4096];
    let mut tag_pending = has_tag;
    while let Ok(Some(n)) = recv.read(&mut tmp).await {
        buf.extend_from_slice(&tmp[..n]);
        // Consume the leading class tag exactly once (per-type streams only).
        if tag_pending && !buf.is_empty() {
            let tag = buf.remove(0);
            tag_pending = false;
            eprintln!("[input] class stream tag={tag} ({})", input_class_name(tag));
        }
        loop {
            if buf.len() < 2 {
                break;
            }
            let len = u16::from_le_bytes([buf[0], buf[1]]) as usize;
            if buf.len() < 2 + len {
                break;
            }
            let rec: Vec<u8> = buf[2..2 + len].to_vec();
            buf.drain(..2 + len);
            input::handle(cap, cfg, mouse, input_router, &rec).await;
        }
    }
}
