//! What every socket input sink shares: how much a burst may queue in front
//! of the sink's writer task, and how that task decides the module on the far
//! end of the socket is dead.
//!
//! vicesock, mamesock, mgactl, artistctl and ramabs each carried their own
//! copy of both, and every copy carried the same two defects. Both surfaced on
//! the live vic20 on 2026-10-04, when a visitor pasted a listing as keystrokes
//! (AutoHotkey `SendText`, browser key events as fast as it can fire them):
//! `[input-router] vicesock accepted=3500 dropped=137 overflow=137` and eight
//! `[vicesock] ack timeout (7..28 outstanding); reconnecting`, each of which
//! KEYCLEARed the module and threw the rest of the paste away.
//!
//! 1. CAPACITY. The hand-off queue between the browser receive path
//!    (`try_key`, synchronous) and the writer task held 64 edges. A paste
//!    arrives as ONE batch: the reliable-stream reader dispatches every record
//!    of a 4 KiB read (up to 682 six-byte key records) without yielding until
//!    tokio's cooperative budget (128 units; each record's `keys.lock()` spends
//!    one) forces it to, and the writer it woke sits in that worker's LIFO
//!    slot, which no other worker may steal. So ~128 edges land before the
//!    writer drains one — a 25-character line with its Shift edges is 64.
//!    `ORDERED_CAPACITY` now covers a whole read, and keys never depend on it
//!    anyway: `InputRouter::key` waits for the writer to make `room` and
//!    re-offers instead of dropping. The modules behind these sockets queue
//!    without bound and read their sockets freely, so the daemon's queue is
//!    only ever a hand-off, never the backlog.
//!
//! 2. LIVENESS BY AGE. The deadline was the OLDEST unacked write's send time
//!    plus 5 s plus 200 ms x the CURRENT outstanding count. These modules ack an
//!    edge when they APPLY it, at the guest's own pace (vic20: hold/gap 60/60
//!    with EXCL, ~8 keys/s), so after a long burst the oldest edge has
//!    legitimately waited behind everything sent with it — and as the backlog
//!    drains the allowance SHRINKS, because it counts what is left rather than
//!    what was ahead. A healthy module ~10 s into a 200-edge paste was declared
//!    dead with ~20 edges to go. Liveness is now PROGRESS: the head of the
//!    outstanding list gets `ACK_BASE` (+ one paced allowance) from the moment
//!    it BECAME the head — when the module retired the write before it — or
//!    from its own send, whichever is later. A module that keeps applying edges
//!    is never timed out however deep its queue; one that stops is caught
//!    `ACK_BASE` after its last progress, sooner than before.
//!
//! Writes are bounded too (`write_verb`): a module that stops READING is as
//! dead as one that stops acking, and an unbounded `write_all` would park the
//! writer where no liveness check can see it.

use std::collections::VecDeque;
use std::time::Duration;

use tokio::io::AsyncWriteExt;
use tokio::net::unix::OwnedWriteHalf;
use tokio::time::Instant;

/// Hand-off queue bound shared by every socket sink. Covers one full 4 KiB
/// transport read of key records (682) with margin; see the module doc.
pub(crate) const ORDERED_CAPACITY: usize = 1024;

/// How long the HEAD write may go unacked once it is at the head: covers
/// connection setup, a paused machine's frame-drain pickup (~40-50 ms) and the
/// MAME edge deferral behind an in-flight MOVEA (give-up cap ~1.6 s).
pub(crate) const ACK_BASE: Duration = Duration::from_secs(5);

/// Extra allowance when the head is a pace-delayed verb (a KEY waiting out
/// its hold/gap/EXCL dwell, a button edge, a draining MOVEP).
pub(crate) const ACK_PER_PACED: Duration = Duration::from_millis(200);

/// One in-flight seq-stamped write awaiting its OK/ERR ack.
pub(crate) struct Sent {
    pub(crate) seq: u64,
    pub(crate) at: Instant,
    pub(crate) paced: bool,
    /// KEY verb: its ack closes a `[key-tel]` tx/ack pair (keyboard-lag chain).
    pub(crate) key: bool,
}

/// The writes a connection has outstanding, in send order, and the progress
/// clock that decides when the module is dead. One per connection.
#[derive(Default)]
pub(crate) struct AckLedger {
    outstanding: VecDeque<Sent>,
    /// When the module last retired the HEAD write — the moment the current
    /// head became the head. Acks for later writes (a release overtaking a
    /// press waiting on the EXCL gate, a MOVEA acked on accept) do not move it:
    /// they prove the module is alive, but not that the head is moving.
    head_since: Option<Instant>,
}

impl AckLedger {
    pub(crate) fn sent(&mut self, seq: u64, paced: bool, key: bool) {
        self.outstanding.push_back(Sent {
            seq,
            at: Instant::now(),
            paced,
            key,
        });
    }

    /// Retire `seq`. `None` for a seq this connection is not waiting on.
    pub(crate) fn ack(&mut self, seq: u64) -> Option<Sent> {
        let i = self.outstanding.iter().position(|s| s.seq == seq)?;
        if i == 0 {
            self.head_since = Some(Instant::now());
        }
        self.outstanding.remove(i)
    }

    /// When the module is to be declared dead, or `None` with nothing
    /// outstanding.
    pub(crate) fn deadline(&self) -> Option<Instant> {
        let head = self.outstanding.front()?;
        let since = self.head_since.map_or(head.at, |t| t.max(head.at));
        let paced = if head.paced {
            ACK_PER_PACED
        } else {
            Duration::ZERO
        };
        Some(since + ACK_BASE + paced)
    }

    pub(crate) fn len(&self) -> usize {
        self.outstanding.len()
    }
}

/// `<seq> OK …` / `<seq> ERR …` -> `(seq, is_err)`. `DATA` rows, `EV`
/// broadcasts and anything else are not acks. An ERR is an ack for liveness —
/// the module processed the verb — even though the verb did not apply.
pub(crate) fn parse_ack(line: &str) -> Option<(u64, bool)> {
    let mut tok = line.splitn(3, ' ');
    let seq = tok.next()?.parse::<u64>().ok()?;
    match tok.next()? {
        "OK" => Some((seq, false)),
        "ERR" => Some((seq, true)),
        _ => None,
    }
}

/// Write one seq-stamped verb line, bounded by `ACK_BASE`.
pub(crate) async fn write_verb(
    wr: &mut OwnedWriteHalf,
    seq: u64,
    line: &str,
) -> std::io::Result<()> {
    tokio::time::timeout(ACK_BASE, wr.write_all(format!("{seq} {line}\n").as_bytes()))
        .await
        .map_err(|_| {
            std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "module stopped reading its socket",
            )
        })?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_ack_reads_ok_and_err_and_nothing_else() {
        assert_eq!(parse_ack("12 OK"), Some((12, false)));
        assert_eq!(parse_ack("12 OK coalesced"), Some((12, false)));
        assert_eq!(parse_ack("7 ERR nokeymap no such keysym"), Some((7, true)));
        assert_eq!(parse_ack("7 DATA rows=16"), None);
        assert_eq!(parse_ack("EV MOVEA done"), None);
        assert_eq!(parse_ack("OK"), None);
    }

    /// The incident arithmetic, on the paused clock: 300 edges sent at once,
    /// retired one per 60 ms. The old age-based deadline (oldest send + 5 s +
    /// 200 ms x outstanding) passes at edge ~250, 15 s in; the progress
    /// deadline never does, because the head keeps moving.
    #[tokio::test(start_paused = true)]
    async fn a_moving_head_never_expires_however_deep_the_backlog() {
        let mut ledger = AckLedger::default();
        for seq in 1..=300 {
            ledger.sent(seq, true, true);
        }
        let t0 = Instant::now();
        for seq in 1..=300 {
            tokio::time::advance(Duration::from_millis(60)).await;
            let deadline = ledger.deadline().unwrap();
            assert!(Instant::now() < deadline, "declared dead at edge {seq}");
            let old_age_based = t0 + ACK_BASE + ACK_PER_PACED * ledger.len() as u32;
            if seq == 260 {
                assert!(
                    Instant::now() > old_age_based,
                    "the old rule must fail here"
                );
            }
            assert!(ledger.ack(seq).is_some());
        }
        assert!(ledger.deadline().is_none());
    }

    /// A stuck head is caught ACK_BASE (+ pacing) after it became the head,
    /// even while acks for LATER writes keep arriving.
    #[tokio::test(start_paused = true)]
    async fn a_stuck_head_expires_even_while_later_writes_are_acked() {
        let mut ledger = AckLedger::default();
        for seq in 1..=5 {
            ledger.sent(seq, true, true);
        }
        tokio::time::advance(Duration::from_millis(60)).await;
        ledger.ack(1);
        let became_head = Instant::now();
        for seq in 3..=5 {
            tokio::time::advance(Duration::from_secs(1)).await;
            ledger.ack(seq);
        }
        assert_eq!(
            ledger.deadline(),
            Some(became_head + ACK_BASE + ACK_PER_PACED)
        );
    }

    /// A write sent into an idle connection starts its own clock: an ancient
    /// head retirement must not make a fresh write look overdue.
    #[tokio::test(start_paused = true)]
    async fn a_fresh_write_after_idle_starts_its_own_clock() {
        let mut ledger = AckLedger::default();
        ledger.sent(1, false, false);
        ledger.ack(1);
        tokio::time::advance(Duration::from_secs(60)).await;
        ledger.sent(2, false, false);
        assert_eq!(ledger.deadline(), Some(Instant::now() + ACK_BASE));
    }
}
