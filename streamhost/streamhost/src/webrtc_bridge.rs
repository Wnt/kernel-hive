//! Platform WebRTC bridge feed.
//!
//! Every instance of the shared streamhost binary automatically registers its
//! station id with one generic Pion bridge over a shared Unix socket. This mirrors
//! the already-encoded H.264 Annex-B AUs and Opus packets; it never captures or
//! encodes a second time and is independent of the WebTransport sink.
//!
//! The socket path is platform configuration, not station configuration. The
//! optional environment override is useful for an isolated platform test; no
//! `SH_*` station environment is consulted.
//!
//! Wire protocol v1:
//!   streamhost -> bridge handshake: `OSGWB1` + `[tile_len u16 LE]` + UTF-8 station
//!   streamhost -> bridge records: `[record_len u32 LE][kind u8][payload]`
//!     V: `[capture_ts_us u32 LE][key u8][Annex-B AU]`
//!     A: `[ts_us u32 LE][seq u32 LE][Opus packet]`
//!   bridge -> streamhost: `K` keyframe, `S` session lease start, `E` lease end.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::broadcast;

use crate::audio::AudioOut;
use crate::encode::EncoderOut;
use crate::idle::IdlePauser;

const DEFAULT_SOCKET: &str = "/run/osgallery-webrtc/feeds.sock";
const MAGIC: &[u8; 6] = b"OSGWB1";
const RECONNECT_DELAY: Duration = Duration::from_millis(1_000);
const ABSENT_LOG_INTERVAL: Duration = Duration::from_secs(60);

pub fn spawn(
    tile: String,
    enc: Arc<EncoderOut>,
    audio: Option<AudioOut>,
    pauser: Option<Arc<IdlePauser>>,
) {
    let path = std::env::var_os("OSGALLERY_WEBRTC_FEED_SOCKET")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| PathBuf::from(DEFAULT_SOCKET));
    tokio::spawn(async move {
        let mut last_absent_log = tokio::time::Instant::now() - ABSENT_LOG_INTERVAL;
        loop {
            match UnixStream::connect(&path).await {
                Ok(stream) => {
                    eprintln!("[webrtc-bridge] platform feed connected tile={tile}");
                    if let Err(err) =
                        relay(stream, &tile, enc.clone(), audio.clone(), pauser.clone()).await
                    {
                        eprintln!("[webrtc-bridge] platform feed disconnected tile={tile}: {err}");
                    }
                }
                Err(err) => {
                    if last_absent_log.elapsed() >= ABSENT_LOG_INTERVAL {
                        eprintln!(
                            "[webrtc-bridge] platform bridge unavailable at {}: {err}",
                            path.display()
                        );
                        last_absent_log = tokio::time::Instant::now();
                    }
                }
            }
            tokio::time::sleep(RECONNECT_DELAY).await;
        }
    });
}

async fn relay(
    mut stream: UnixStream,
    tile: &str,
    enc: Arc<EncoderOut>,
    audio: Option<AudioOut>,
    pauser: Option<Arc<IdlePauser>>,
) -> anyhow::Result<()> {
    let tile_bytes = tile.as_bytes();
    let tile_len = u16::try_from(tile_bytes.len())?;
    stream.write_all(MAGIC).await?;
    stream.write_all(&tile_len.to_le_bytes()).await?;
    stream.write_all(tile_bytes).await?;

    let (mut read, mut write) = stream.into_split();
    let key_enc = enc.clone();
    let mut key_requests = tokio::spawn(async move {
        let mut command = [0u8; 1];
        let mut leases = 0usize;
        loop {
            let Err(err) = read.read_exact(&mut command).await else {
                if command[0] == b'K' {
                    key_enc.request_keyframe();
                    eprintln!("[webrtc-bridge] keyframe requested by RTCP PLI/FIR");
                } else if command[0] == b'S' {
                    if let Some(p) = &pauser {
                        p.session_started().await;
                    }
                    leases = leases.saturating_add(1);
                    key_enc.request_keyframe();
                    eprintln!("[webrtc-bridge] WebRTC session lease started");
                } else if command[0] == b'E' && leases > 0 {
                    if let Some(p) = &pauser {
                        p.session_ended().await;
                    }
                    leases -= 1;
                    eprintln!("[webrtc-bridge] WebRTC session lease ended");
                }
                continue;
            };
            // A bridge crash cannot leak active viewer leases and keep a guest
            // running forever. Release every lease learned on this feed before
            // the outer loop reconnects and the new bridge replays live peers.
            if let Some(p) = &pauser {
                for _ in 0..leases {
                    p.session_ended().await;
                }
            }
            if leases > 0 {
                eprintln!("[webrtc-bridge] released {leases} leases after bridge disconnect");
            }
            return Err(err);
        }
    });

    let mut video_rx = enc.tx.subscribe();
    let mut audio_rx = audio.map(|a| a.tx.subscribe());
    enc.request_keyframe();
    loop {
        tokio::select! {
            video = video_rx.recv() => match video {
                Ok(au) => {
                    let record_len = u32::try_from(6usize.saturating_add(au.data.len()))?;
                    write.write_all(&record_len.to_le_bytes()).await?;
                    write.write_all(b"V").await?;
                    write.write_all(&au.capture_ts_us.to_le_bytes()).await?;
                    write.write_all(&[u8::from(au.is_key)]).await?;
                    write.write_all(au.data.as_slice()).await?;
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    eprintln!("[webrtc-bridge] video feed lagged by {n}; requesting keyframe");
                    enc.request_keyframe();
                }
                Err(broadcast::error::RecvError::Closed) => break,
            },
            packet = recv_audio(&mut audio_rx) => match packet {
                Some(Ok(packet)) => {
                    let record_len = u32::try_from(9usize.saturating_add(packet.data.len()))?;
                    write.write_all(&record_len.to_le_bytes()).await?;
                    write.write_all(b"A").await?;
                    write.write_all(&packet.ts_us.to_le_bytes()).await?;
                    write.write_all(&packet.seq.to_le_bytes()).await?;
                    write.write_all(packet.data.as_slice()).await?;
                }
                Some(Err(broadcast::error::RecvError::Lagged(n))) => {
                    eprintln!("[webrtc-bridge] audio feed lagged by {n}");
                }
                Some(Err(broadcast::error::RecvError::Closed)) => audio_rx = None,
                None => {},
            },
            commands = &mut key_requests => {
                match commands {
                    Ok(Ok(())) => anyhow::bail!("bridge command stream ended"),
                    Ok(Err(err)) => return Err(err.into()),
                    Err(err) => return Err(err.into()),
                }
            },
        }
    }
    key_requests.abort();
    Ok(())
}

async fn recv_audio(
    rx: &mut Option<broadcast::Receiver<crate::audio::AudioPacket>>,
) -> Option<Result<crate::audio::AudioPacket, broadcast::error::RecvError>> {
    match rx {
        Some(rx) => Some(rx.recv().await),
        None => std::future::pending().await,
    }
}
