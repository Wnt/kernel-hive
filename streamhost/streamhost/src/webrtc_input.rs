//! WebRTC fallback INPUT ingress.
//!
//! The native-decoder WebRTC fallback (Safari 17, Firefox-Android) reaches this
//! daemon's video through the shared Pion bridge (`webrtc_bridge.rs` mirrors AUs
//! out). Its INPUT arrives here: the bridge accepts the peer's two DataChannels
//! and forwards every message to this per-tile Unix socket, which feeds the SAME
//! input pipeline the WebTransport path feeds — `input::handle`, the daemon-wide
//! abs→rel `SharedMouse`, the per-session key state, the router. The decoder is
//! REUSED, never forked: records are byte-identical to the WebTransport wire.
//!
//! Bridge → daemon wire (one connection per WebRTC peer):
//!   handshake:  `OSGWI1`
//!   frames:     `[len u32 LE][channel u8][payload…]`   (len = 1 + payload)
//!               channel 0 = unreliable (moves + re-home hint)
//!               channel 1 = reliable   (buttons/keys/wheel)
//!   The FIRST reliable frame's payload is the session TICKET (the same
//!   `/wt/<exp>.<nonce>.<sig>` the WebTransport client uses). The bridge only
//!   forwards; THIS module verifies it before injecting anything, so an
//!   unticketed peer cannot drive the guest. A keyless LAN station's gate is
//!   inert (`session_ticket::admit`), exactly like the WebTransport path.
//!
//! ENV-GATED: the listener binds only when its directory exists — that directory
//! is the bridge's systemd `RuntimeDirectory`, so a host with no bridge never
//! creates a socket and nothing changes. `OSGALLERY_WEBRTC_INPUT_DIR` overrides
//! it (an isolated test); an empty value disables the ingress entirely.

use std::path::PathBuf;
use std::sync::Arc;

use tokio::io::AsyncReadExt;
use tokio::net::{UnixListener, UnixStream};

use crate::capture::Capture;
use crate::config::Config;

const DEFAULT_DIR: &str = "/run/osgallery-webrtc";
const MAGIC: &[u8; 6] = b"OSGWI1";
const CH_RELIABLE: u8 = 1;
const MAX_RECORD: usize = 4096;

/// What to do with one forwarded frame, decided WITHOUT touching the guest so it
/// can be unit-tested. The ticket is only ever the first reliable frame; until
/// it is verified every record is dropped, so an unticketed peer injects nothing.
#[derive(Debug, PartialEq, Eq)]
enum FrameAction {
    /// The leading reliable frame: verify its payload as a ticket.
    Ticket,
    /// A verified input record to dispatch to `input::handle`.
    Record,
    /// Pre-ticket noise (an early move) — ignore it.
    Drop,
}

fn classify(verified: bool, channel: u8) -> FrameAction {
    if verified {
        FrameAction::Record
    } else if channel == CH_RELIABLE {
        FrameAction::Ticket
    } else {
        FrameAction::Drop
    }
}

/// The per-tile input socket path, or `None` when the ingress is disabled (empty
/// override) or its directory is absent (no bridge on this host).
fn socket_path(tile: &str) -> Option<PathBuf> {
    let dir = match std::env::var_os("OSGALLERY_WEBRTC_INPUT_DIR") {
        Some(v) if v.is_empty() => return None, // explicit disable
        Some(v) => PathBuf::from(v),
        None => PathBuf::from(DEFAULT_DIR),
    };
    if !dir.is_dir() {
        return None;
    }
    Some(dir.join(format!("input-{tile}.sock")))
}

pub fn spawn(
    cfg: Arc<Config>,
    cap: Capture,
    mouse: crate::input::SharedMouse,
    router: Option<Arc<crate::realtime_input::InputRouter>>,
    key_reap_tx: tokio::sync::mpsc::UnboundedSender<Vec<u16>>,
) {
    let Some(path) = socket_path(&cfg.tile) else {
        eprintln!("[webrtc-input] ingress OFF (no bridge runtime dir / disabled)");
        return;
    };
    tokio::spawn(async move {
        // A stale socket from a previous run refuses `bind`; remove it first.
        let _ = tokio::fs::remove_file(&path).await;
        let listener = match UnixListener::bind(&path) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("[webrtc-input] cannot bind {}: {e}", path.display());
                return;
            }
        };
        // The bridge may run as another user; let it connect.
        if let Ok(perm) = std::fs::metadata(&path).map(|m| {
            use std::os::unix::fs::PermissionsExt;
            let mut p = m.permissions();
            p.set_mode(0o666);
            p
        }) {
            let _ = std::fs::set_permissions(&path, perm);
        }
        eprintln!("[webrtc-input] ingress listening at {}", path.display());
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    let cfg = cfg.clone();
                    let cap = cap.clone();
                    let mouse = mouse.clone();
                    let router = router.clone();
                    let keys = crate::key_state::new_session(key_reap_tx.clone());
                    tokio::spawn(async move {
                        if let Err(e) = handle_peer(stream, cfg, cap, mouse, router, keys).await {
                            eprintln!("[webrtc-input] peer ended: {e}");
                        }
                    });
                }
                Err(e) => {
                    eprintln!("[webrtc-input] accept failed: {e}");
                    return;
                }
            }
        }
    });
}

async fn handle_peer(
    mut stream: UnixStream,
    cfg: Arc<Config>,
    cap: Capture,
    mouse: crate::input::SharedMouse,
    router: Option<Arc<crate::realtime_input::InputRouter>>,
    keys: crate::key_state::SharedKeys,
) -> anyhow::Result<()> {
    let mut magic = [0u8; MAGIC.len()];
    stream.read_exact(&mut magic).await?;
    if &magic != MAGIC {
        anyhow::bail!("bad input handshake");
    }
    // A fresh peer keeps tracking the daemon-wide guest cursor (a reload does not
    // corner-chase) — the same contract the WebTransport session has.
    mouse.lock().await.reset_for_session();
    let router = router.as_ref();
    let mut verified = false;
    let mut len_buf = [0u8; 4];
    loop {
        if stream.read_exact(&mut len_buf).await.is_err() {
            return Ok(()); // peer closed
        }
        let len = u32::from_le_bytes(len_buf) as usize;
        if !(1..=MAX_RECORD + 1).contains(&len) {
            anyhow::bail!("bad input frame length {len}");
        }
        let mut frame = vec![0u8; len];
        stream.read_exact(&mut frame).await?;
        let channel = frame[0];
        let payload = &frame[1..];
        match classify(verified, channel) {
            FrameAction::Ticket => {
                let ticket = std::str::from_utf8(payload).unwrap_or("");
                match crate::session_ticket::admit(&cfg, ticket) {
                    Ok(()) => {
                        verified = true;
                        eprintln!("[webrtc-input] session admitted tile={}", cfg.tile);
                    }
                    Err(why) => {
                        eprintln!("[webrtc-input] REJECTED tile={} reason={why}", cfg.tile);
                        return Ok(());
                    }
                }
            }
            FrameAction::Drop => {}
            FrameAction::Record => {
                // REUSE the shared decoder: strip any browser trace suffix
                // exactly as the WebTransport reliable path does, then hand the
                // clean record to the one input pipeline (input_stream.rs mirror).
                let (body, _ctx) = crate::input_trace::strip(payload);
                crate::input::handle(&cap, &cfg, &mouse, &keys, router, body).await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ticket_is_the_first_reliable_frame_only() {
        // Before verification: a reliable frame is the ticket, a rel frame is dropped.
        assert_eq!(classify(false, CH_RELIABLE), FrameAction::Ticket);
        assert_eq!(classify(false, 0), FrameAction::Drop);
        // After verification: every frame, on either channel, is a record.
        assert_eq!(classify(true, CH_RELIABLE), FrameAction::Record);
        assert_eq!(classify(true, 0), FrameAction::Record);
    }

    #[test]
    fn disabled_by_empty_env_override() {
        // SAFETY: single-threaded test; no other thread reads this var concurrently.
        unsafe { std::env::set_var("OSGALLERY_WEBRTC_INPUT_DIR", "") };
        assert!(socket_path("win311").is_none());
        unsafe { std::env::remove_var("OSGALLERY_WEBRTC_INPUT_DIR") };
    }

    #[test]
    fn socket_path_lives_in_the_configured_dir() {
        let dir = std::env::temp_dir();
        // SAFETY: single-threaded test.
        unsafe { std::env::set_var("OSGALLERY_WEBRTC_INPUT_DIR", &dir) };
        let p = socket_path("win311").expect("temp dir exists");
        assert_eq!(p, dir.join("input-win311.sock"));
        unsafe { std::env::remove_var("OSGALLERY_WEBRTC_INPUT_DIR") };
    }
}
