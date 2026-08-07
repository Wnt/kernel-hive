// Guest-QEMU RSS guard.
//
// QEMU's dbus display has NO flow control on the copy path: every damage tick it
// fire-and-forget-queues an Update carrying the pixel payload into its
// GDBusWorker output queue. If the listener drains the socket slower than QEMU
// produces, that queue grows without bound in QEMU ANON HEAP until the guest's
// cgroup OOM-kills it. This guard watches the guest QEMU's RssAnon and, when it
// grows more than SH_QEMU_RSS_GUARD_MB above its low-water mark, drops +
// re-registers the listener connection (QEMU frees its whole queued backlog
// instantly on peer disconnect — verified: 4.6 GB -> 1.7 GB) so viewers see a
// sub-second freeze instead of the guest dying at its cgroup cap.

use std::sync::atomic::Ordering::Relaxed;
use std::sync::{Arc, Mutex};

use tokio::sync::Notify;

use super::frame::FrameState;
use super::listener::{register_listener, CapStats};

fn read_pidfile(path: &std::path::Path) -> Option<u32> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| s.trim().parse().ok())
}

fn read_rss_anon_kb(pid: u32) -> Option<u64> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    for l in s.lines() {
        if let Some(v) = l.strip_prefix("RssAnon:") {
            return v.trim().trim_end_matches(" kB").trim().parse().ok();
        }
    }
    None
}

/// One guard poll step (pure): track the low-water mark downward and decide
/// whether growth above it exceeds the threshold. Returns (new_low, trip).
fn guard_poll_step(cur_kb: u64, low_kb: u64, thresh_kb: u64) -> (u64, bool) {
    let low = low_kb.min(cur_kb);
    (low, cur_kb.saturating_sub(low) > thresh_kb)
}

/// Post-recycle low-water rebaseline (pure). On a successful post-trip read,
/// the fresh value becomes the new baseline unconditionally:
///   * backlog trip: the recycle freed the queued frames, `after` lands back
///     near the old low — baseline effectively unchanged, guard stays armed;
///   * legitimate guest-RAM growth (RAM fault-in after an early-boot attach,
///     -m 3072 tiles, `loadvm golden` restoring a full RAM image): the recycle
///     frees ~nothing, `after ≈ cur` — the baseline moves UP so the guard
///     measures only NEW growth from here, instead of re-tripping against a
///     stale low every debounce interval forever.
///
/// On a failed read (None) keep the previous baseline untouched — feeding a
/// 0 in would make every subsequent poll compare full RssAnon vs the
/// threshold and loop-trip any >=2 GB guest.
fn rebaseline_low(prev_low_kb: u64, after_kb: Option<u64>) -> u64 {
    after_kb.unwrap_or(prev_low_kb)
}

/// Guest-QEMU RSS guard: QEMU's dbus display queues copy-path frames without
/// bound when the listener socket backpressures. If the guest's anon RSS grows
/// more than SH_QEMU_RSS_GUARD_MB (default 2048; 0 disables) above its
/// low-water mark, drop + re-register the listener connection: QEMU frees the
/// entire queued backlog on peer disconnect and re-sends a full scanout on
/// re-register. This bounds worst-case guest growth on BOTH pathologies
/// (fast attach-burst and slow sustained-interaction backlog) at the cost of a
/// sub-second capture gap — instead of a cgroup OOM kill of the guest.
/// The low-water mark is rebaselined from a fresh read after every recycle
/// (see `rebaseline_low`), so legitimate guest-RAM growth trips at most once
/// and the 2048 MB default is safe even for -m 3072 tiles.
pub(super) async fn rss_guard(
    qmp_path: String,
    main_conn: zbus::Connection,
    listener: Arc<Mutex<Option<zbus::Connection>>>,
    state: Arc<Mutex<FrameState>>,
    damage: Arc<Notify>,
    stats: Arc<CapStats>,
) {
    let thresh_mb: u64 = std::env::var("SH_QEMU_RSS_GUARD_MB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2048);
    if thresh_mb == 0 {
        eprintln!("[capture] rss-guard disabled (SH_QEMU_RSS_GUARD_MB=0)");
        return;
    }
    let pidfile = match std::env::var_os("SH_QEMU_PIDFILE") {
        Some(path) => std::path::PathBuf::from(path),
        None => match std::path::Path::new(&qmp_path).parent() {
            Some(d) => d.join("qemu.pid"),
            None => return,
        },
    };
    let mut pid: u32 = match read_pidfile(&pidfile) {
        Some(p) => p,
        None => {
            eprintln!(
                "[capture] rss-guard OFF: no readable pidfile at {}",
                pidfile.display()
            );
            return;
        }
    };
    let mut low = match read_rss_anon_kb(pid) {
        Some(v) => v,
        None => {
            eprintln!("[capture] rss-guard OFF: cannot read /proc/{pid}/status");
            return;
        }
    };
    eprintln!(
        "[capture] rss-guard ON: qemu pid={} anon={} MB, trip at +{} MB",
        pid,
        low / 1024,
        thresh_mb
    );
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        // Re-read the pidfile every poll: `labctl reset`/tile restarts can
        // replace QEMU under us. A changed pid means the old baseline is
        // meaningless — re-baseline from a fresh read. A vanished pidfile or
        // /proc entry means the tile is being torn down: stop the guard
        // cleanly, never trip against a dead/unrelated pid.
        match read_pidfile(&pidfile) {
            None => {
                eprintln!(
                    "[capture] rss-guard: pidfile gone at {} — guard exiting",
                    pidfile.display()
                );
                return;
            }
            Some(p) if p != pid => {
                pid = p;
                match read_rss_anon_kb(pid) {
                    Some(v) => {
                        low = v;
                        eprintln!(
                            "[capture] rss-guard: qemu pid changed -> {pid}; low-water re-baselined at {} MB",
                            low / 1024
                        );
                        continue;
                    }
                    None => {
                        eprintln!("[capture] rss-guard: new qemu pid {pid} unreadable in /proc — guard exiting");
                        return;
                    }
                }
            }
            Some(_) => {}
        }
        let cur = match read_rss_anon_kb(pid) {
            Some(v) => v,
            None => {
                eprintln!("[capture] rss-guard: qemu pid {pid} gone — guard exiting");
                return;
            }
        };
        let (new_low, trip) = guard_poll_step(cur, low, thresh_mb * 1024);
        low = new_low;
        if trip {
            stats.guard_trips.fetch_add(1, Relaxed);
            eprintln!(
                "[capture] rss-guard TRIP: qemu anon {} MB (low-water {} MB, +{} MB > {} MB) — recycling listener connection",
                cur / 1024,
                low / 1024,
                (cur - low) / 1024,
                thresh_mb
            );
            let old = listener.lock().unwrap().take();
            drop(old); // closes the p2p socket -> QEMU frees its queued backlog
            tokio::time::sleep(std::time::Duration::from_millis(750)).await;
            // Bound the re-register: if QEMU never answers RegisterListener,
            // capture stays frozen with no error — that must not be silent.
            // Time out after 10 s and exit 86 so systemd (Restart=on-failure)
            // brings up a fresh daemon.
            match tokio::time::timeout(
                std::time::Duration::from_secs(10),
                register_listener(&main_conn, &state, &damage, &stats),
            )
            .await
            {
                Err(_elapsed) => {
                    eprintln!("[capture] rss-guard: re-register TIMED OUT after 10 s — exiting for systemd restart");
                    std::process::exit(86);
                }
                Ok(Ok(c)) => {
                    *listener.lock().unwrap() = Some(c);
                    let after = read_rss_anon_kb(pid);
                    match after {
                        Some(a) => eprintln!(
                            "[capture] rss-guard: listener re-registered; qemu anon now {} MB (freed ~{} MB); low-water rebaselined",
                            a / 1024,
                            cur.saturating_sub(a) / 1024
                        ),
                        None => eprintln!(
                            "[capture] rss-guard: listener re-registered; post-trip RssAnon read failed — keeping low-water {} MB",
                            low / 1024
                        ),
                    }
                    low = rebaseline_low(low, after);
                }
                Ok(Err(e)) => {
                    eprintln!("[capture] rss-guard: re-register FAILED ({e:?}) — exiting for systemd restart");
                    std::process::exit(86);
                }
            }
            // debounce: don't re-trip within 10 s
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{guard_poll_step, rebaseline_low};

    const MB: u64 = 1024; // kB per MB
    const THRESH: u64 = 2048 * MB; // default SH_QEMU_RSS_GUARD_MB

    #[test]
    fn no_trip_below_threshold() {
        let (low, trip) = guard_poll_step(2000 * MB, 500 * MB, THRESH);
        assert_eq!(low, 500 * MB);
        assert!(!trip);
    }

    #[test]
    fn low_tracks_downward() {
        let (low, trip) = guard_poll_step(400 * MB, 500 * MB, THRESH);
        assert_eq!(low, 400 * MB);
        assert!(!trip);
    }

    #[test]
    fn backlog_trip_then_recycle_frees_baseline_stays_low() {
        // Copy-path backlog: 500 MB baseline balloons to 4600 MB -> trip.
        let (low, trip) = guard_poll_step(4600 * MB, 500 * MB, THRESH);
        assert!(trip);
        // Recycle frees the backlog: after lands near the old low.
        let low = rebaseline_low(low, Some(600 * MB));
        assert_eq!(low, 600 * MB);
        // Guard is still armed against the next backlog.
        let (_, trip) = guard_poll_step(3000 * MB, low, THRESH);
        assert!(trip);
    }

    #[test]
    fn ram_fault_in_rebaselines_up_no_trip_storm() {
        // serenityos attach-during-early-boot / -m 3072 tiles / loadvm golden:
        // low-water was captured tiny, guest RAM legitimately faults in.
        let low0 = 200 * MB;
        let (low, trip) = guard_poll_step(2900 * MB, low0, THRESH);
        assert!(trip); // one trip is expected...
                       // ...recycle frees ~nothing (there was no backlog): after ≈ cur.
        let low = rebaseline_low(low, Some(2850 * MB));
        assert_eq!(low, 2850 * MB);
        // The old `low = after.min(low.max(1))` kept 200 MB here and the guard
        // re-tripped every debounce interval forever. Now: healthy, no re-trip.
        let (_, trip) = guard_poll_step(2900 * MB, low, THRESH);
        assert!(!trip);
    }

    #[test]
    fn failed_post_trip_read_keeps_previous_low() {
        // The old `.unwrap_or(0)` made low=0, after which every poll compared
        // FULL RssAnon against the threshold -> permanent loop for >=2 GB guests.
        let low = rebaseline_low(500 * MB, None);
        assert_eq!(low, 500 * MB);
        let (_, trip) = guard_poll_step(2400 * MB, low, THRESH);
        assert!(!trip); // 2400 MB total but only +1900 MB over baseline
    }

    #[test]
    fn growth_exactly_at_threshold_does_not_trip() {
        let (_, trip) = guard_poll_step(2548 * MB, 500 * MB, THRESH);
        assert!(!trip); // strictly-greater-than semantics, unchanged
    }
}
