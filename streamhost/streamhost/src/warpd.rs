// warpd client — drives the in-guest X pointer agent (warpd.py) over TCP.
//
// Some guests cap the QEMU absolute tablet below the screen size (Solaris 10: the
// usbms/VUID kernel path maps the tablet's full 0..0x7FFF range onto a fixed
// 1024x768 box, so the cursor can't reach a 1920x1200 desktop; relative motion is
// ignored too). For those guests we DON'T use the QEMU tablet at all — a tiny
// Python+ctypes agent inside the guest (warpd.py) positions the X pointer directly
// via XTEST/XWarpPointer, which is true full-screen absolute. The daemon reaches it
// through a QEMU hostfwd (host 127.0.0.1:<port> -> guest :7777) and streams
// newline-delimited commands: "M x y" move, "P n x y"/"R n x y" button press/release,
// "B n x y" wheel click. Video/audio/keyboard still go over dbus as usual.
//
// PROTOCOL FREEZE: M/P/R/B are the shared core, and the existing live per-agent
// verbs (for example Solaris exec and bake/diagnostic verbs) remain supported as
// historical contracts. Add no new per-agent verbs and do not expand this
// protocol; new Solaris/QNX device work belongs behind RealtimeInputSink. The
// guest-agents/solaris-galleryhid/warpd-to-ghid-bridge.py shim is transitional
// debt and should disappear once gallery-hid subsumes the stations that still need
// it. That migration is intentionally not imminent for the six baked agents.
//
// A background task owns the TCP connection and reconnects on failure; callers just
// fire commands into an unbounded channel (never blocks the input path). Stale
// positions during a reconnect are harmless for a pointer stream.

use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::sync::mpsc;

/// Connect to the in-guest agent. Two transports, chosen by the address shape:
///   - a filesystem path or "unix:<path>"  -> a UNIX socket that backs a QEMU
///     serial chardev (`-chardev socket,path=…,server=on -device isa-serial`).
///     Preferred for legacy guests (Win9x/OS2/DOS/Win3.x): no TCP stack needed,
///     the agent just reads COM1. QEMU owns the socket (server=on), the daemon
///     connects as client and writes M/P/R/B bytes straight to the guest UART.
///   - otherwise "host:port" -> a TCP socket via a QEMU hostfwd (Solaris/9front,
///     which have a real TCP stack).
///
/// Both yield an AsyncWrite the same drain-coalesce loop writes to unchanged.
async fn connect_agent(
    addr: &str,
) -> std::io::Result<Box<dyn tokio::io::AsyncWrite + Unpin + Send>> {
    if addr.starts_with('/') || addr.starts_with("unix:") {
        let path = addr.strip_prefix("unix:").unwrap_or(addr);
        let s = tokio::net::UnixStream::connect(path).await?;
        Ok(Box::new(s))
    } else {
        let s = TcpStream::connect(addr).await?;
        let _ = s.set_nodelay(true);
        Ok(Box::new(s))
    }
}

pub struct WarpdClient {
    // (command line, recv Instant). The Instant threads oldest-sample age into
    // input telemetry and is None (no syscall) whenever telemetry is off.
    tx: mpsc::UnboundedSender<(String, Option<std::time::Instant>)>,
}

impl WarpdClient {
    /// `pace_ms` (SH_WARPD_PACE_MS, default 8): minimum interval between writes
    /// to the agent. Slow guest network stacks (Win95's Winsock-1.1 TCP over an
    /// emulated PCnet) can only absorb a limited segment rate; writing every
    /// browser pointer sample (60-250 Hz) builds an unbounded in-flight queue
    /// that the in-guest agent then replays position-by-position => seconds of
    /// rubber-band cursor lag that grows while the user moves. Pacing bounds the
    /// segment rate (~125/s at 8 ms) while the drain-coalesce below collapses
    /// everything that accumulated during the pause into ONE final position, so
    /// worst-case added latency is pace_ms but backlog becomes impossible.
    pub fn new_paced(addr: String, pace_ms: u64) -> Arc<Self> {
        let (tx, mut rx) = mpsc::unbounded_channel::<(String, Option<std::time::Instant>)>();
        tokio::spawn(async move {
            loop {
                match connect_agent(&addr).await {
                    Ok(mut stream) => {
                        eprintln!("[warpd] connected {addr}");
                        // Drain-coalesce-write: on each wakeup take ALL pending commands,
                        // collapse runs of consecutive moves to the last one (under a burst
                        // of pointer moves only the final position matters; buttons/wheel
                        // carry their own x,y so ordering vs. moves is preserved), and do a
                        // single write. Fewest syscalls + no backlog => lowest latency.
                        let mut broke = false;
                        while let Some(first) = rx.recv().await {
                            let mut batch = vec![first];
                            while let Ok(m) = rx.try_recv() {
                                batch.push(m);
                            }
                            let (batch_len, oldest) = (batch.len() as u64, batch[0].1);
                            let mut out = String::new();
                            let mut i = 0;
                            while i < batch.len() {
                                if batch[i].0.starts_with("M ") {
                                    let mut j = i;
                                    while j + 1 < batch.len() && batch[j + 1].0.starts_with("M ") {
                                        j += 1;
                                    }
                                    out.push_str(&batch[j].0);
                                    i = j + 1;
                                } else {
                                    out.push_str(&batch[i].0);
                                    i += 1;
                                }
                            }
                            let t0 =
                                crate::input_telemetry::enabled().then(std::time::Instant::now);
                            let write_res = stream.write_all(out.as_bytes()).await;
                            if let Some(t0) = t0 {
                                let age = oldest
                                    .map(|o| t0.saturating_duration_since(o).as_micros() as u64);
                                let rtt = t0.elapsed().as_micros() as u64;
                                crate::input_telemetry::record_inject("warpd", batch_len, rtt, age);
                            }
                            if write_res.is_err() {
                                eprintln!("[warpd] {addr} write failed -> reconnect");
                                broke = true;
                                break;
                            }
                            if pace_ms > 0 {
                                tokio::time::sleep(std::time::Duration::from_millis(pace_ms)).await;
                            }
                        }
                        if !broke && rx.is_closed() {
                            break; // station shutting down
                        }
                    }
                    Err(e) => {
                        // A WarpdClient is created per SESSION (transport.rs), so when the
                        // session ends while the agent is unreachable (guest paused/rebooting)
                        // this task must exit too — otherwise every visitor leaves an immortal
                        // 1 Hz reconnect loop behind.
                        if rx.is_closed() {
                            break;
                        }
                        eprintln!("[warpd] connect {addr} failed: {e} (retry 1s)");
                        tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
                    }
                }
            }
        });
        Arc::new(WarpdClient { tx })
    }

    /// Fire one command line (already newline-terminated). Never blocks; drops
    /// silently if the writer task is gone.
    pub fn send(&self, cmd: String) {
        let _ = self.tx.send((
            cmd,
            crate::input_telemetry::enabled().then(std::time::Instant::now),
        ));
    }
}
