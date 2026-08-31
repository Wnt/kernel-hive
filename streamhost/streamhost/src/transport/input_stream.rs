// Transport reliable-input ingress: draining CLIENT->SERVER reliable input
// streams (both the legacy single bidi and the per-type uni class streams) into
// input::handle. Split out of the session core as the CLIENT->SERVER framing
// seam — byte-for-byte identical to the inline version; only the enclosing
// module changed.

use std::sync::Arc;

use crate::capture::Capture;
use crate::config::Config;
use crate::input;
use crate::input_trace;
use crate::trace_session::SessionTrace;

/// The per-session bundle every reliable-input reader needs. Cloning one
/// value instead of five separately (cap/cfg/mouse/keys/router) is why this
/// exists: the legacy bidi and per-type uni acceptors below each spawn one
/// reader task per accepted stream, so that quintet used to appear four
/// times over in `transport::serve`'s session fan-out.
#[derive(Clone)]
pub(super) struct SessionInputCtx {
    pub(super) cap: Capture,
    pub(super) cfg: Arc<Config>,
    pub(super) mouse: input::SharedMouse,
    pub(super) keys: crate::key_state::SharedKeys,
    pub(super) input_router: Option<Arc<crate::realtime_input::InputRouter>>,
}

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
    ctx: &SessionInputCtx,
    has_tag: bool,
    strace: &Arc<SessionTrace>,
) {
    let SessionInputCtx {
        cap,
        cfg,
        mouse,
        keys,
        input_router,
    } = ctx;
    let input_router = input_router.as_ref();
    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 4096];
    let mut tag_pending = has_tag;
    // Named for the span; the legacy single-bidi framing has no tag to name.
    let mut class: &'static str = if has_tag { "unknown" } else { "reliable" };
    while let Ok(Some(n)) = recv.read(&mut tmp).await {
        buf.extend_from_slice(&tmp[..n]);
        // Consume the leading class tag exactly once (per-type streams only).
        if tag_pending && !buf.is_empty() {
            let tag = buf.remove(0);
            tag_pending = false;
            class = input_class_name(tag);
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
            // `input.first_edge`: one AtomicBool swap per record after the
            // first. The CLASS is named; the record's bytes never are — no
            // keycode, no coordinate reaches a span (contract §7).
            strace.mark_first_input(class);
            // SAMPLED per-input tracing (docs/lab/TRACE-CONTEXT.md, the
            // in-datagram-record hop): `strip` is cheap on the 9-in-10
            // unsampled edges (input_trace.rs measures it) — one match on
            // rec[0] and a couple of length compares, no allocation. Only a
            // record the BROWSER chose to sample carries a suffix at all;
            // this daemon never decides to sample on its own (contract §5).
            let (body, ctx) = input_trace::strip(&rec);
            match ctx {
                Some(ctx) => {
                    let input_class = input_trace::input_class(body[0]);
                    let key_class = (body[0] == 3)
                        .then(|| input_trace::key_class(u16::from_le_bytes([body[2], body[3]])));
                    strace
                        .dispatch_sampled_input(ctx, input_class, key_class, async {
                            input::handle(cap, cfg, mouse, keys, input_router, body).await;
                        })
                        .await;
                }
                None => input::handle(cap, cfg, mouse, keys, input_router, body).await,
            }
        }
    }
}

/// Spawn the LEGACY single-bidi acceptor: one reader task per client-opened
/// bidi stream, `has_tag=false` (no leading class byte on this framing).
/// Kept running unconditionally so an old UI still drives input; a client
/// that only opens per-type uni streams simply never opens a bidi, so this
/// loop idles harmlessly.
pub(super) fn spawn_bi_readers(
    conn: Arc<wtransport::Connection>,
    ctx: SessionInputCtx,
    strace: Arc<SessionTrace>,
) {
    tokio::spawn(async move {
        while let Ok((_send, recv)) = conn.accept_bi().await {
            let ctx = ctx.clone();
            let st = strace.clone();
            tokio::spawn(async move { drain_input_stream(recv, &ctx, false, &st).await });
        }
    });
}

/// Spawn the PER-TYPE (HOL-avoidance) acceptor: one reader task per
/// client-opened unidirectional class stream, `has_tag=true` (the first
/// byte is the ICLASS_* tag). Always on — the shipped UI opens these
/// unconditionally.
pub(super) fn spawn_uni_readers(
    conn: Arc<wtransport::Connection>,
    ctx: SessionInputCtx,
    strace: Arc<SessionTrace>,
) {
    tokio::spawn(async move {
        while let Ok(recv) = conn.accept_uni().await {
            let ctx = ctx.clone();
            let st = strace.clone();
            tokio::spawn(async move { drain_input_stream(recv, &ctx, true, &st).await });
        }
    });
}
