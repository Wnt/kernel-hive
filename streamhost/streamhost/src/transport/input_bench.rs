// ============================================================================
//  transport/input_bench — Stage-D's comparable T0 input ingress.
//  ---------------------------------------------------------------------------
//  Opt-in (SH_INPUT_BENCH), loopback-only, and off in production. It lives in
//  its own module rather than in transport/mod.rs because it is a measurement
//  harness, not part of the session path: nothing in the WebTransport flow
//  calls into it, and it calls only the same process-wide input router.
//
//  Lifted verbatim out of the transport god-module; the wire (`M x y`) and its
//  T0 timestamp are unchanged, so the harness's observer still reads it.
// ============================================================================

use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::TcpListener;

use crate::capture::Capture;

/// Stage-D's comparable T0 ingress. This is opt-in, loopback-only, and calls the
/// same process-wide router used by WebTransport. The old harness wire (`M x y`)
/// is retained so its observer and T0 timestamp remain unchanged.
pub(super) fn spawn_input_bench(
    addr: String,
    cap: Capture,
    router: Arc<crate::realtime_input::InputRouter>,
) {
    tokio::spawn(async move {
        let listener = match TcpListener::bind(&addr).await {
            Ok(listener) => listener,
            Err(e) => {
                eprintln!("[input-bench] bind {addr} failed: {e}");
                return;
            }
        };
        match listener.local_addr() {
            Ok(a) if a.ip().is_loopback() => {}
            Ok(a) => {
                eprintln!("[input-bench] refusing non-loopback listener {a}");
                return;
            }
            Err(e) => {
                eprintln!("[input-bench] local_addr failed: {e}");
                return;
            }
        }
        eprintln!(
            "[input-bench] LISTENING {addr} -> {} health={:?} (production router)",
            router.backend(),
            router.health(),
        );
        while let Ok((stream, peer)) = listener.accept().await {
            if !peer.ip().is_loopback() {
                continue;
            }
            let cap = cap.clone();
            let router = router.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stream).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let mut fields = line.split_ascii_whitespace();
                    let Some(verb) = fields.next() else { continue };
                    // `K <xt-scancode> <0|1>` — a keyboard edge through the
                    // production router, added for the de-bridging campaign:
                    // every MAME bridge tile is keyboard-only, so keymap
                    // acceptance needs the same loopback the pointer has.
                    if verb == "K" {
                        let (Some(code), Some(down)) = (fields.next(), fields.next()) else {
                            continue;
                        };
                        let code = code.strip_prefix("0x").unwrap_or(code);
                        if let (Ok(code), Ok(down)) =
                            (u16::from_str_radix(code, 16), down.parse::<u8>())
                        {
                            let _ = router.try_key(code, down != 0, false);
                        }
                        continue;
                    }
                    let parsed = match verb {
                        "M" | "D" | "U" => {
                            let (Some(x), Some(y)) = (fields.next(), fields.next()) else {
                                continue;
                            };
                            (x.parse::<u32>(), y.parse::<u32>(), None)
                        }
                        "P" | "R" | "B" => {
                            let (Some(button), Some(x), Some(y)) =
                                (fields.next(), fields.next(), fields.next())
                            else {
                                continue;
                            };
                            (
                                x.parse::<u32>(),
                                y.parse::<u32>(),
                                button.parse::<u8>().ok(),
                            )
                        }
                        _ => continue,
                    };
                    let (Ok(x), Ok(y), button) = parsed else {
                        continue;
                    };
                    let (width, height) = {
                        let state = cap.state.lock().unwrap();
                        (
                            state.width.max(state.fb_w).max(1),
                            state.height.max(state.fb_h).max(1),
                        )
                    };
                    let _ = router.try_move(x, y, width, height);
                    match verb {
                        "D" => {
                            let _ = router.try_button(0, true);
                        }
                        "U" => {
                            let _ = router.try_button(0, false);
                        }
                        "P" => {
                            if let Some(button) = button.and_then(|b| b.checked_sub(1)) {
                                let _ = router.try_button(button, true);
                            }
                        }
                        "R" => {
                            if let Some(button) = button.and_then(|b| b.checked_sub(1)) {
                                let _ = router.try_button(button, false);
                            }
                        }
                        "B" => match button {
                            Some(4) => {
                                let _ = router.try_wheel(0, -1);
                            }
                            Some(5) => {
                                let _ = router.try_wheel(0, 1);
                            }
                            _ => {}
                        },
                        _ => {}
                    }
                }
            });
        }
    });
}
