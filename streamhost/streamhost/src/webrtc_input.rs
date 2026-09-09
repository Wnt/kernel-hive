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
    pauser: Option<Arc<crate::idle::IdlePauser>>,
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
                    let pauser = pauser.clone();
                    tokio::spawn(async move {
                        if let Err(e) =
                            handle_peer(stream, cfg, cap, mouse, router, keys, pauser).await
                        {
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

/// Arm the idle-pause session guard for a peer WHOSE TICKET JUST VERIFIED.
///
/// Split out so the session-count seam (0→1 on admission, 1→0 on drop) is
/// testable with a bare `IdlePauser`, without a full `Config` — this peer's
/// pre-admission frames must never reach here (`FrameAction::Ticket`/`Drop`
/// never call it; only the `Ok` arm of ticket verification does), which is
/// what keeps "input before admission does not count" true by construction
/// rather than by a separate check.
async fn arm_session(
    pauser: &Option<Arc<crate::idle::IdlePauser>>,
) -> Option<crate::idle::SessionGuard> {
    let p = pauser.as_ref()?;
    p.session_started().await;
    Some(crate::idle::SessionGuard::new(p.clone()))
}

async fn handle_peer(
    mut stream: UnixStream,
    cfg: Arc<Config>,
    cap: Capture,
    mouse: crate::input::SharedMouse,
    router: Option<Arc<crate::realtime_input::InputRouter>>,
    keys: crate::key_state::SharedKeys,
    pauser: Option<Arc<crate::idle::IdlePauser>>,
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
    // Held for the rest of this peer's life once its ticket verifies; dropped
    // (any return path — clean close, a bad frame, the loop's own `?`) reports
    // the session end exactly the way `transport::mod.rs::handle_session`'s
    // `_pause_guard` does. A peer that never verifies never gets one: the
    // fleet auto-pause must count a fallback VIEWER (admitted), not a socket
    // that connected and said nothing useful.
    let mut _session_guard: Option<crate::idle::SessionGuard> = None;
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
                        _session_guard = arm_session(&pauser).await;
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

    /// A real `IdlePauser` with a `Signal` freezer whose pidfile never resolves
    /// to a live process: `session_started`/`session_ended` still update the
    /// session count (that bookkeeping does not depend on the freezer actually
    /// firing), and the reconciler it spawns has nothing to pause. Mirrors
    /// `key_state.rs`'s `held_for_test` pattern one module over.
    fn test_pauser() -> std::sync::Arc<crate::idle::IdlePauser> {
        crate::idle::IdlePauser::new(
            crate::idle::Freezer::Signal {
                pidfile: "/nonexistent/webrtc-input-test.pid".to_string(),
                proc_match: None,
            },
            60,
            0,
            "webrtc-input-test",
        )
        .expect("grace_secs != 0, so a pauser is always returned")
    }

    // THE SEAM: `arm_session` is the one function `handle_peer` calls on ticket
    // admission (its `Ok(())` arm — see the call site above), and it is the
    // only place in this file that touches the idle-pause session count. Every
    // pre-admission frame is `FrameAction::Drop` or `FrameAction::Ticket`,
    // neither of which reaches it — so "input before admission does not count"
    // is a fact about which branch calls this function, not a separate runtime
    // check, and this test proves the count moves only where that call is.
    #[tokio::test]
    async fn admission_arms_a_session_and_drop_releases_it() {
        let pauser = test_pauser();
        let some_pauser = Some(pauser.clone());

        // Pre-admission traffic on either channel never arms a session — the
        // loop in `handle_peer` would classify these as `Drop` or `Ticket`,
        // never `Record`, and only a verified `Ticket` (this test's next step)
        // ever calls `arm_session`.
        assert_eq!(classify(false, 0), FrameAction::Drop);
        assert_eq!(classify(false, CH_RELIABLE), FrameAction::Ticket);
        assert_eq!(pauser.sessions_for_test().await, 0, "no admission yet");

        // The ticket verifies (handle_peer's `Ok(())` arm): session count 0->1.
        let guard = arm_session(&some_pauser).await;
        assert!(guard.is_some());
        assert_eq!(pauser.sessions_for_test().await, 1, "admitted peer counts");

        // Once verified, every further frame — either channel — is a Record,
        // which never calls `arm_session` again (a second call would double
        // count one peer as two sessions).
        assert_eq!(classify(true, CH_RELIABLE), FrameAction::Record);
        assert_eq!(classify(true, 0), FrameAction::Record);

        // The peer disconnects: handle_peer returns and `_session_guard` drops.
        drop(guard);
        // `SessionGuard::drop` spawns `session_ended()` rather than awaiting it
        // inline (idle.rs) — give the runtime one tick to run it.
        tokio::task::yield_now().await;
        assert_eq!(
            pauser.sessions_for_test().await,
            0,
            "drop releases the session"
        );
    }

    #[tokio::test]
    async fn no_pauser_configured_arms_nothing() {
        // A host with idle-pause disabled (grace 0 => IdlePauser::new returns
        // None) must not panic or fabricate a session.
        assert!(arm_session(&None).await.is_none());
    }
}
