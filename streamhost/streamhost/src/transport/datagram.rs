// Transport ingress: the DATAGRAM plane of one WebTransport session.
//
// Three things arrive here and only one of them may ever wait:
//   * type 9  — the client's RTT ping. Echoed VERBATIM, synchronously. It is the
//     client's liveness signal (600 ms timeout, three misses = hard reconnect),
//     so it is answered before anything else can be looked at.
//   * type 10 — T_STATS, the ABR feedback report (SECTION 3.1). Parsed and folded
//     under the controller's mutex; arithmetic, no I/O.
//   * everything else — an input record, handed to a channel.
//
// WHY THE RECEIVE LOOP OWNS NO INJECTION. `input::handle` is an await with no
// useful upper bound: its first act is `idle::wake_for_input()`, which on an
// idle-auto-paused guest takes the pauser state lock and issues a QMP `cont` over
// a fresh socket with 2 s read AND 2 s write timeouts (idle.rs `qmp_execute`), so
// ONE record can hold its caller for seconds whenever the QMP socket is busy —
// another transient client, an out-of-band driver's wake lease, the reconciler.
// While that ran inline, every ping queued behind it: win95 lost the echo for
// >1.8 s at 18:39:03 and 18:43:41 UTC on 2026-09-02 and the tab hard-reconnected
// with a perfectly healthy transport underneath it. Now a slow guest delays input,
// which it must, and nothing else.
//
// Both channels are UNBOUNDED, deliberately. The alternative they replace was not
// back-pressure — it was stalling the connection's whole control plane — and an
// input record must never be dropped or reordered on the way to the guest.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::abr::Abr;
use crate::capture::Capture;
use crate::config::Config;
use crate::input::{self, SharedMouse};
use crate::trace_session::SessionTrace;

use super::OP_STATS;

/// Everything one session's datagram plane needs. Bundled so the spawn site reads
/// as one hand-off instead of nine clones.
pub(super) struct DatagramCtx {
    pub conn: Arc<wtransport::Connection>,
    pub cfg: Arc<Config>,
    pub cap: Capture,
    pub mouse: SharedMouse,
    pub keys: crate::key_state::SharedKeys,
    pub input_router: Option<Arc<crate::realtime_input::InputRouter>>,
    pub abr: Arc<Abr>,
    /// The CONGESTION skip counter (backlog gate + ring overrun only), folded into
    /// the ABR backlog signal. NOT the client-facing `skip_count` — see the two
    /// counters where they are created in `transport/mod.rs`.
    pub skip_count: Arc<AtomicU64>,
    pub strace: Arc<SessionTrace>,
    pub sess_id: u64,
}

pub(super) fn spawn_datagram_plane(ctx: DatagramCtx) {
    let DatagramCtx {
        conn,
        cfg,
        cap,
        mouse,
        keys,
        input_router,
        abr,
        skip_count,
        strace,
        sess_id,
    } = ctx;

    // MOVE COALESCER for the dbus (abs/rel) stations — mirrors warpd.rs. The datagram
    // receive loop must NOT apply each move as an awaited dbus call_method
    // (SetAbsPosition/RelMotion waits for a QEMU method REPLY), because at
    // pointer-lock move rates (~1 record per mousemove, up to ~1 kHz) that serializes
    // the loop on the reply RTT and a backlog of SUPERSEDED positions piles up in
    // quinn -> the guest cursor lags behind + rubber-bands. Instead we funnel move
    // records into an mpsc; a drain-coalesce task takes ALL pending each wakeup, keeps
    // the LATEST absolute (type 1) / SUMS relative deltas (type 4), and issues ONE
    // dbus inject — so a burst collapses to the freshest position and receive_datagram
    // is never throttled. Buttons/keys/wheel ride the reliable stream and are never
    // pooled here. Warpd stations skip this (warpd.rs already coalesces downstream);
    // their moves take the serial drain below, which is just as unblocking.
    let move_tx = if matches!(
        cfg.input_backend,
        crate::config::InputBackend::DbusAbs | crate::config::InputBackend::DbusRel
    ) {
        // Item = (bytes, recv Instant for telemetry age; None when telemetry off).
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(Vec<u8>, Option<Instant>)>();
        let cap = cap.clone();
        let cfg = cfg.clone();
        let mouse = mouse.clone();
        let keys = keys.clone();
        tokio::spawn(async move {
            while let Some(first) = rx.recv().await {
                let mut batch = vec![first];
                while let Ok(m) = rx.try_recv() {
                    batch.push(m);
                }
                let (batch_len, oldest) = (batch.len() as u64, batch[0].1);
                let mut last_abs: Option<Vec<u8>> = None;
                let (mut sdx, mut sdy, mut have_rel) = (0i32, 0i32, false);
                for (rec, _) in &batch {
                    match rec.first() {
                        Some(1) if rec.len() >= 5 => last_abs = Some(rec.clone()),
                        Some(4) if rec.len() >= 5 => {
                            sdx += i16::from_le_bytes([rec[1], rec[2]]) as i32;
                            sdy += i16::from_le_bytes([rec[3], rec[4]]) as i32;
                            have_rel = true;
                        }
                        _ => {}
                    }
                }
                let t0 = crate::input_telemetry::enabled().then(Instant::now);
                if let Some(rec) = last_abs {
                    input::handle(&cap, &cfg, &mouse, &keys, None, &rec).await;
                } else if have_rel {
                    let dx = sdx.clamp(i16::MIN as i32, i16::MAX as i32) as i16;
                    let dy = sdy.clamp(i16::MIN as i32, i16::MAX as i32) as i16;
                    let mut rec = vec![4u8, 0, 0, 0, 0];
                    rec[1..3].copy_from_slice(&dx.to_le_bytes());
                    rec[3..5].copy_from_slice(&dy.to_le_bytes());
                    input::handle(&cap, &cfg, &mouse, &keys, None, &rec).await;
                }
                if let Some(t0) = t0 {
                    let age = oldest.map(|o| t0.saturating_duration_since(o).as_micros() as u64);
                    let rtt = t0.elapsed().as_micros() as u64;
                    crate::input_telemetry::record_inject("dbus", batch_len, rtt, age);
                }
                if cfg.abs_pace_ms > 0 {
                    tokio::time::sleep(Duration::from_millis(cfg.abs_pace_ms)).await;
                }
            }
        });
        Some(tx)
    } else {
        None
    };

    // The serial input drain (see the module doc): records leave the receive loop
    // here and are applied, in arrival order, by a task of their own.
    let rest_tx = {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
        let cap = cap.clone();
        let cfg = cfg.clone();
        let mouse = mouse.clone();
        let keys = keys.clone();
        let input_router = input_router.clone();
        tokio::spawn(async move {
            while let Some(rec) = rx.recv().await {
                input::handle(&cap, &cfg, &mouse, &keys, input_router.as_ref(), &rec).await;
            }
        });
        tx
    };

    // ---- the receive loop itself: demux only, never inject ----
    tokio::spawn({
        let conn = conn.clone();
        async move {
            while let Ok(dg) = conn.receive_datagram().await {
                let p = dg.payload();
                if p.is_empty() {
                    continue;
                }
                if p[0] == 9 {
                    let _ = conn.send_datagram(p.clone()); // RTT ping: echo verbatim
                } else if p[0] == OP_STATS {
                    // CLIENT->SERVER ABR feedback (SECTION 3.1); intercept
                    // BEFORE input::handle so opcode 10 never reaches input.
                    if let Some(r) = crate::abr::parse_report(&p) {
                        abr.submit(sess_id, r, skip_count.load(Ordering::Relaxed));
                    }
                } else if let (Some(tx), true) = (&move_tx, p[0] == 1 || p[0] == 4) {
                    // Move -> coalescer (never blocks). Instant only when tel on.
                    strace.mark_first_input("datagram");
                    let at = crate::input_telemetry::enabled().then(Instant::now);
                    let _ = tx.send((p.to_vec(), at));
                } else {
                    strace.mark_first_input("datagram");
                    // NEVER awaited here — see the module doc.
                    let _ = rest_tx.send(p.to_vec());
                }
            }
        }
    });
}
