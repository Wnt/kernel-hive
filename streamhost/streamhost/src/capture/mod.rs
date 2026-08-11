// QEMU framebuffer capture over `-display dbus,p2p=on`.
// Ported from SPIKE A (validated end-to-end): QMP getfd(SCM_RIGHTS) +
// add_client "@dbus-display" -> zbus p2p client -> Console_0.RegisterListener(fd)
// -> we serve /org/qemu/Display1/Listener implementing the Unix.Map (zero-copy
// shared-memory scanout) interface plus the v1 copy-path fallback.
//
// Exposes:
//   * `main_conn`   : the p2p zbus Connection to QEMU (used ALSO for input inject)
//   * `FrameState`  : latest mmap'd framebuffer geometry + a Notify pulsed on damage
// The encoder pulls the current frame bytes on demand (damage-gated).
//
// Module layout (behavior-preserving split of the former capture.rs god-file):
//   * `frame`    : `FrameState`/`DamageRect`/`DamageSnapshot` — surface geometry,
//                  damage accounting, BGRA snapshotting (no zbus/network).
//   * `listener` : the p2p Listener server (Unix.Map + v1 copy path), `CapStats`,
//                  and `register_listener`.
//   * `guard`    : the guest-QEMU RSS guard (recycles the listener on backlog).
//   * this file  : constants, the `Capture` handle, the QMP handshake, and
//                  `connect()` wiring it all together.
//
// FLOW-CONTROL NOTE (shm attach-burst root cause, 2026-07):
// QEMU's dbus display has NO flow control on the copy path: every damage tick
// it fire-and-forget-queues an Update method call carrying the pixel payload
// into its GDBusWorker output queue. If this listener drains the socket slower
// than QEMU produces, that queue grows without bound in QEMU ANON HEAP until
// the guest's cgroup OOM-kills it (observed ~55-90 MB/s on the Debian-12
// emulator-bridge kiosks, whose 32bpp KMS surface is guest-VRAM-backed and
// therefore NOT memfd-shareable -> QEMU silently falls back to the copy path
// even when the client advertises Unix.Map). Three defenses live here:
//   1. v1 Scanout/Update take `&[u8]` (zvariant borrowed-bytes fast path). The
//      old `Vec<u8>` args went through serde's per-element seq visitor —
//      ~3 MB per message through a per-byte loop was the drain bottleneck.
//   2. A v1 Scanout invalidates (munmaps) any previously offered shm map: the
//      copy path is now authoritative. Without this, a stale pre-guest-init
//      640x480 placeholder ScanoutMap (sent on FIRST attach to a daemon-less
//      QEMU whose console never refreshed) wins snapshot_bgra() forever and
//      the station streams dead pixels while the real frames flood the fallback.
//   3. An RSS guard (SH_QEMU_RSS_GUARD_MB, default 2048, 0=off) watches the
//      guest QEMU's RssAnon via SH_QEMU_PIDFILE, or qemu.pid beside QMP. If it
//      grows more than the threshold above its low-water mark, the listener
//      connection is dropped (QEMU frees its whole queued backlog instantly —
//      verified: 4.6 GB -> 1.7 GB on disconnect) and re-registered. Viewers
//      see a sub-second freeze instead of the guest dying at its cgroup cap.
//
// SH_CAP_TRACE=1 prints per-2s dispatch counters (rates, bytes, handler time).

use std::io::{BufRead, BufReader, IoSlice, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, RawFd};
use std::os::unix::net::UnixStream as StdUnixStream;
use std::sync::atomic::Ordering::Relaxed;
use std::sync::{Arc, Mutex};

use nix::sys::socket::{
    sendmsg, socketpair, AddressFamily, ControlMessage, MsgFlags, SockFlag, SockType,
};
use tokio::sync::Notify;

mod frame;
mod guard;
mod listener;
mod shm;
mod x11;

pub use shm::connect_shm;
pub use x11::connect_x11;

pub use frame::{DamageRect, FrameState};
// Re-exported to keep `capture::DamageSnapshot` in the public API (it is the
// return type of `FrameState::snapshot_damage_bgra`). The daemon bin compiles
// this source under a PRIVATE `mod capture`, where the re-export alias itself is
// never named — a false positive from that target's point of view (the lib
// target exposes it as genuine public API).
#[allow(unused_imports)]
pub use frame::DamageSnapshot;
pub use listener::CapStats;

use guard::rss_guard;
use listener::register_listener;

pub const CONSOLE: &str = "/org/qemu/Display1/Console_0";
pub const I_MOUSE: &str = "org.qemu.Display1.Mouse";
pub const I_KBD: &str = "org.qemu.Display1.Keyboard";
pub const I_CONSOLE: &str = "org.qemu.Display1.Console";

#[derive(Clone)]
pub struct Capture {
    pub state: Arc<Mutex<FrameState>>,
    pub damage: Arc<Notify>,
    /// The p2p zbus Connection to QEMU (capture + dbus input inject + audio).
    /// `None` for non-QEMU frame sources (`CaptureBackend::X11`/`Shm`), whose input
    /// rides an out-of-band sink (XTEST / the emulator's command file) and which
    /// have no dbus audiodev — every
    /// consumer of this field guards on `Some` (dbus input is only reached on a
    /// dbus/qemu station; audio only starts when this is present).
    pub main_conn: Option<zbus::Connection>,
    // Keep the listener p2p connection alive; if it drops, QEMU stops pushing
    // damage/scanout updates (frozen capture). Slotted so the RSS guard can
    // replace it at runtime (drop = QEMU frees its queued display backlog).
    // Never READ outside this module, but load-bearing: the Arc keeps the
    // connection (and the stats sink) alive for the process lifetime.
    #[allow(dead_code)]
    pub listener: Arc<Mutex<Option<zbus::Connection>>>,
    #[allow(dead_code)]
    pub stats: Arc<CapStats>,
}

fn qmp_line(reader: &mut impl BufRead) -> String {
    let mut l = String::new();
    reader.read_line(&mut l).unwrap();
    l.trim().to_string()
}

async fn build_conn_client(fd: RawFd) -> zbus::Connection {
    let std_stream = unsafe { StdUnixStream::from_raw_fd(fd) };
    std_stream.set_nonblocking(true).unwrap();
    let tok = tokio::net::UnixStream::from_std(std_stream).unwrap();
    zbus::connection::Builder::unix_stream(tok)
        .p2p()
        .build()
        .await
        .expect("build main p2p client")
}

/// Connect to a running QEMU's QMP socket and wire up dbus-display capture.
pub async fn connect(qmp_path: &str) -> anyhow::Result<Capture> {
    // ---- QMP handshake (blocking) ----
    let qmp = StdUnixStream::connect(qmp_path)?;
    let mut reader = BufReader::new(qmp.try_clone()?);
    let mut w = qmp.try_clone()?;
    let _greeting = qmp_line(&mut reader);
    writeln!(w, "{{\"execute\":\"qmp_capabilities\"}}")?;
    let _caps = qmp_line(&mut reader);

    let (main_a, main_b) = socketpair(
        AddressFamily::Unix,
        SockType::Stream,
        None,
        SockFlag::empty(),
    )?;
    let getfd = b"{\"execute\":\"getfd\",\"arguments\":{\"fdname\":\"dbusdisp\"}}\n";
    let iov = [IoSlice::new(getfd)];
    let fds = [main_b.as_raw_fd()];
    let cmsg = [ControlMessage::ScmRights(&fds)];
    sendmsg::<()>(qmp.as_raw_fd(), &iov, &cmsg, MsgFlags::empty(), None)?;
    let _ = qmp_line(&mut reader);
    drop(main_b);
    writeln!(
        w,
        "{{\"execute\":\"add_client\",\"arguments\":{{\"protocol\":\"@dbus-display\",\"fdname\":\"dbusdisp\"}}}}"
    )?;
    let _ = qmp_line(&mut reader);

    let main_fd: RawFd = main_a.into_raw_fd();
    let main_conn = build_conn_client(main_fd).await;

    let state = Arc::new(Mutex::new(FrameState::new()));
    let damage = Arc::new(Notify::new());
    let stats = Arc::new(CapStats::default());

    let server_conn = register_listener(&main_conn, &state, &damage, &stats).await?;
    let listener = Arc::new(Mutex::new(Some(server_conn)));

    // let the first ScanoutMap + UpdateMap land
    tokio::time::sleep(std::time::Duration::from_millis(600)).await;

    // Guest-QEMU RSS guard (see fn docs). Env-gated, on by default.
    tokio::spawn(rss_guard(
        qmp_path.to_string(),
        main_conn.clone(),
        listener.clone(),
        state.clone(),
        damage.clone(),
        stats.clone(),
    ));

    // SH_CAP_TRACE=1 — per-2s listener dispatch counters. Gate on the VALUE:
    // is_ok() would treat SH_CAP_TRACE=0 as enabled (config::env_flag).
    if crate::config::env_flag("SH_CAP_TRACE") {
        let st = stats.clone();
        tokio::spawn(async move {
            let (mut ms0, mut mu0, mut vs0, mut vu0, mut vb0, mut hu0) = (0u64, 0, 0, 0, 0, 0);
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                let (ms, mu, vs, vu, vb, hu, gt) = (
                    st.map_scanout.load(Relaxed),
                    st.map_update.load(Relaxed),
                    st.v1_scanout.load(Relaxed),
                    st.v1_update.load(Relaxed),
                    st.v1_bytes.load(Relaxed),
                    st.handler_us.load(Relaxed),
                    st.guard_trips.load(Relaxed),
                );
                eprintln!(
                    "[capstat] 2s: map_scanout={} map_update={} v1_scanout={} v1_update={} v1_MB={:.1} ({:.1} MB/s) handler_ms={:.1} guard_trips={}",
                    ms - ms0,
                    mu - mu0,
                    vs - vs0,
                    vu - vu0,
                    (vb - vb0) as f64 / 1e6,
                    (vb - vb0) as f64 / 2e6,
                    (hu - hu0) as f64 / 1e3,
                    gt
                );
                (ms0, mu0, vs0, vu0, vb0, hu0) = (ms, mu, vs, vu, vb, hu);
            }
        });
    }

    Ok(Capture {
        state,
        damage,
        main_conn: Some(main_conn),
        listener,
        stats,
    })
}
