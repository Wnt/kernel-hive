// Shared monotonic clock for A/V sync. Video capture timestamps and audio Opus
// packet timestamps are both taken from this single process-wide epoch so the
// client can line them up (WebCodecs timestamps are in microseconds).

use std::sync::OnceLock;
use std::time::Instant;

static EPOCH: OnceLock<Instant> = OnceLock::new();

pub fn init() {
    let _ = EPOCH.get_or_init(Instant::now);
}

/// Microseconds since process epoch, truncated to u32 (wraps ~71 min — fine for
/// relative A/V alignment; the client only ever diffs recent values).
pub fn now_us() -> u32 {
    EPOCH.get_or_init(Instant::now).elapsed().as_micros() as u32
}
