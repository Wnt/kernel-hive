// Optional built-in plain-HTTP signaling endpoint (testing / live A-B only).
//
// PRODUCTION signaling is served same-origin over HTTPS by the SERVE agent,
// which simply serves the per-tile `signaling.json` that cert.rs publishes. This
// tiny dependency-free HTTP server exists so the standalone reference client
// (web/client.html) and live A/B probes can fetch {host,udpPort,certHashB64}
// without the SPA. It re-reads the file on every request so cert rotation is
// always reflected. Bind it to a LAN/localhost port; never expose it publicly.
//
//   GET /            -> the full signaling.json           (application/json)
//   GET /hash        -> the bare base64 cert hash         (text/plain)
//   (any)            -> 200 with the json; CORS: *

use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use crate::config::Config;

pub fn spawn_http(cfg: Arc<Config>, port: u16) {
    tokio::spawn(async move {
        let bind = format!("0.0.0.0:{port}");
        match TcpListener::bind(&bind).await {
            Ok(l) => {
                eprintln!("[signaling] plain-HTTP endpoint on http://{bind}/ (testing/A-B)");
                loop {
                    if let Ok((mut sock, _)) = l.accept().await {
                        let cfg = cfg.clone();
                        tokio::spawn(async move {
                            let mut buf = [0u8; 2048];
                            let n = sock.read(&mut buf).await.unwrap_or(0);
                            let req = String::from_utf8_lossy(&buf[..n]);
                            let want_hash = req.starts_with("GET /hash");
                            let (ctype, body) = if want_hash {
                                (
                                    "text/plain",
                                    std::fs::read_to_string(&cfg.hash_file).unwrap_or_default(),
                                )
                            } else {
                                (
                                    "application/json",
                                    std::fs::read_to_string(&cfg.signaling_json)
                                        .unwrap_or_default(),
                                )
                            };
                            let resp = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{body}",
                                body.len()
                            );
                            let _ = sock.write_all(resp.as_bytes()).await;
                            let _ = sock.flush().await;
                        });
                    }
                }
            }
            Err(e) => eprintln!("[signaling] could not bind {bind}: {e}"),
        }
    });
}
