//! Feature-reach probes — the daemon's half of the analytics plane
//! (`docs/ANALYTICS.md`).
//!
//! WHAT THIS IS FOR. The SPA plane answers "which code earns its keep" for the
//! tab. The same question is open on the box, and it is asked about a fleet of
//! 61 stations that share ONE binary: every input backend, every pointer
//! quirk and every ABR rung is compiled into every station, and nobody can say
//! from the source which of them any real visitor ever reaches. `SH_*` config
//! says what a station is ALLOWED to do; a probe says what it DID.
//!
//! THE DENOMINATOR IS THE WHOLE POINT, so the catalogue is DECLARED. A counter
//! can only report code that ran, and the interesting answer here is about code
//! that did not. `ALL` is the denominator: every probe is enumerable at zero
//! hits, and a station that dumps `abr.tier.down: 0` is making a statement.
//! That is why this is not a `HashMap<String, u64>` filled in at call time — a
//! dynamic registry cannot list what never fired, which is exactly the row you
//! came for. It also cannot be grepped, and the drift gate below depends on
//! being able to grep.
//!
//! WHY IT IS SHAPED LIKE THIS AND NOT LIKE THE TYPESCRIPT SIDE.
//!   * No `intent` ladder. There is no human on this side of the wire — by the
//!     time a record reaches `input.rs` the SPA has already graded it. A second
//!     grade computed from a byte on a datagram would be a guess wearing the
//!     same word, so this plane carries hit counts only.
//!   * No flows, no errors. The daemon already has journald for both, and
//!     `docs/ANALYTICS.md` §2 is explicit that a durable aggregate must not
//!     become a second copy of the debugging lane.
//!   * No line coverage, ever. Instrumenting a production binary that has a
//!     16 ms budget per frame is not a trade this daemon can make; the "tested"
//!     axis is `cargo llvm-cov` on the test binary, which costs the fleet
//!     nothing.
//!
//! COST, measured, not asserted. A `hit()` is one relaxed `fetch_add` on a
//! `&'static AtomicU64`: no lock, no allocation, no formatting, no branch on a
//! config flag. `hit_cost_is_negligible` measures it and prints the number:
//! **8.5 ns/hit** in the release profile that ships (95 ns in an unoptimised
//! test build), back-to-back on one cache line, which is the worst case a
//! single thread can construct. A station taking 250 pointer samples a second
//! therefore spends about two microseconds a second here. That is cheap enough
//! to leave unconditionally on — an `SH_PROBES=off` switch would cost a branch
//! to save a few nanoseconds, and would then make every dump ambiguous about
//! whether a zero meant "never fired" or "never enabled here". It is NOT
//! "zero-cost", and this file does not claim to be.
//!
//! WHERE THE COUNTS GO. `{base}/probes.json`, beside the station's
//! `signaling.json` and `cert_hash_b64.txt` — the directory
//! `/data/vms/streamhost/stations/<tile>/` is already where this daemon
//! publishes per-station runtime artifacts, and it is already bind-mounted
//! where a collector can read it. Written by the same tmp+rename dance
//! `cert.rs` uses, so a reader never sees half a file. Periodic
//! (`SH_PROBES_DUMP_SECS`, default 60) plus one final dump on SIGTERM/SIGINT.
//!
//! ADDING A PROBE. One entry in the `probes!` block below, one call site in the
//! file its `owner` names, in ONE commit — `catalogue_has_no_orphan_probes`
//! fails the build otherwise. Without that gate a zero has two meanings,
//! "nobody uses this feature" and "I declared it and never called it", and the
//! second kind is what gets working code deleted.

use std::sync::atomic::{AtomicU64, Ordering};

/// One instrumented thing.
pub struct Probe {
    pub id: &'static str,
    /// Source file (relative to `streamhost/streamhost/src/`) holding the call
    /// site. Gated — see the tests.
    pub owner: &'static str,
    /// Finish the sentence "this fired, therefore we know that…".
    pub what: &'static str,
    hits: AtomicU64,
}

impl Probe {
    const fn new(id: &'static str, owner: &'static str, what: &'static str) -> Self {
        Self {
            id,
            owner,
            what,
            hits: AtomicU64::new(0),
        }
    }

    /// The hot path. Relaxed because the only consumer is a periodic dump that
    /// wants a number, not an ordering: no other memory is published by a hit,
    /// so there is nothing for an Acquire/Release pair to protect.
    #[inline(always)]
    pub fn hit(&self) {
        self.hits.fetch_add(1, Ordering::Relaxed);
    }

    pub fn hits(&self) -> u64 {
        self.hits.load(Ordering::Relaxed)
    }
}

/// Declare the statics AND the denominator from one list, so `ALL` cannot drift
/// out of sync with the declarations the way a hand-written array would. A
/// probe that is declared is in the denominator by construction.
macro_rules! probes {
    ($($name:ident => ($id:literal, $owner:literal, $what:literal $(,)?)),* $(,)?) => {
        $(pub static $name: Probe = Probe::new($id, $owner, $what);)*
        /// THE DENOMINATOR. Every declared probe, fired or not.
        pub static ALL: &[&Probe] = &[$(&$name),*];
    };
}

probes! {
    // ---- which pointer backend the fleet actually uses -----------------------
    // Every station compiles in all of them and picks one by `SH_INPUT_BACKEND`.
    // Config says which is SELECTED; these say which ever carried a visitor's
    // hand. A backend at zero across the whole fleet for a month is a station
    // list to re-check and then a module to delete.
    INPUT_ABS_RAM_WRITE => (
        "input.abs.ramWrite",
        "ram_abs.rs",
        "the ramabs/1 guest-RAM-write pointer wire accepted a pointer sample",
    ),
    INPUT_ABS_X11_WARP => (
        "input.abs.x11Warp",
        "x11_warp.rs",
        "the X11 XTEST warp sink accepted a pointer sample",
    ),
    INPUT_ABS_WARPD => (
        "input.abs.warpd",
        "realtime_input_sinks.rs",
        "the warpd guest-agent sink accepted a pointer sample",
    ),
    // The abs->rel dead-reckoning bridge is the oldest and most expensive
    // pointer path in the daemon (pin, settle, walk, four re-home triggers) and
    // it exists only for guests with no usb-tablet. Its ratio against the sinks
    // above is "how much of the fleet still rides the emulated-delta hack".
    INPUT_ABS_REL_BRIDGE => (
        "input.abs.relBridge",
        "rel_bridge.rs",
        "an absolute client target was converted into a guest-relative delta",
    ),
    // Re-homing is the half of that bridge nobody can observe from outside: it
    // is meant to fire on reset/resume/focus/idle, and `mgactl-home-records-a-
    // bogus-hotspot` is open partly because nobody knows how often it runs.
    INPUT_REL_REHOMED => (
        "input.rel.rehomed",
        "rel_bridge.rs",
        "the rel bridge actually re-homed the guest cursor (pin -> settle -> walk)",
    ),

    // ---- keyboard quirks that may be dead for every current station ---------
    // Both are per-station opt-ins added for one machine each. If they never
    // fire, the station that motivated them has either been retired or is not
    // being typed at, and either answer changes what is worth carrying.
    KEY_QUIRK_REMAP => (
        "key.quirk.remap",
        "key_quirks.rs",
        "an SH_KEY_REMAP entry actually rewrote a wire keycode (identity maps do not count)",
    ),
    KEY_QUIRK_LEGACY_CURSOR => (
        "key.quirk.legacyCursor",
        "key_quirks.rs",
        "the SH_LEGACY_KBD pre-1986 quirk sent a BARE keypad cursor code instead of the enhanced form",
    ),

    // ---- ABR ---------------------------------------------------------------
    // Split up/down deliberately. A station that only ever goes DOWN is stuck
    // at a degraded tier and the upshift hysteresis is mis-tuned; equal counts
    // are a link that flaps; both at zero on the LAN is the controller behaving
    // exactly as designed and is the row that says so.
    ABR_TIER_DOWN => (
        "abr.tier.down",
        "abr.rs",
        "the global ABR tier stepped DOWN on a sustained network breach",
    ),
    ABR_TIER_UP => (
        "abr.tier.up",
        "abr.rs",
        "the global ABR tier stepped back UP after a sustained healthy window",
    ),

    // ---- which transport a visitor arrives on ------------------------------
    // WebTransport is the authoritative path; the WebRTC bridge is the fallback
    // for browsers without it. The pair is the whole question: the fallback
    // carries a second encode-independent egress and a whole sidecar process,
    // and nothing in the tree says whether anyone has ever used it.
    TRANSPORT_WT_SESSION => (
        "transport.wt.session",
        "transport/mod.rs",
        "a WebTransport session was admitted and accepted (the denominator for the pair below)",
    ),
    TRANSPORT_WEBRTC_SESSION => (
        "transport.webrtc.session",
        "webrtc_bridge.rs",
        "a real viewer took the WebRTC FALLBACK transport (a bridge lease started)",
    ),
}

/// `probe!(NAME)` — one relaxed increment. A macro rather than a bare `.hit()`
/// so a call site reads as instrumentation and greps as one token.
macro_rules! probe {
    ($name:ident) => {
        $crate::probes::$name.hit()
    };
}
pub(crate) use probe;

// ---------------------------------------------------------------------------
// Dump
// ---------------------------------------------------------------------------

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(default)
}

/// Default dump path: beside the station's other published runtime artifacts.
/// Env-overridable for a sandbox run that must not write into a live station's
/// directory.
pub fn dump_path(tile: &str) -> String {
    std::env::var("SH_PROBES_JSON")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| format!("/data/vms/streamhost/stations/{tile}/probes.json"))
}

/// The document. `what` and `owner` ride along on purpose: the collector then
/// needs no second copy of the catalogue, and a dump from an OLD binary carries
/// its own denominator rather than being read against today's list.
pub fn render(tile: &str, uptime_secs: u64) -> String {
    let probes: serde_json::Map<String, serde_json::Value> = ALL
        .iter()
        .map(|p| {
            (
                p.id.to_string(),
                serde_json::json!({ "hits": p.hits(), "owner": p.owner, "what": p.what }),
            )
        })
        .collect();
    let doc = serde_json::json!({
        "version": 1,
        "station": tile,
        "binary": env!("CARGO_PKG_VERSION"),
        "uptimeSecs": uptime_secs,
        "probes": probes,
    });
    format!(
        "{}\n",
        serde_json::to_string_pretty(&doc).unwrap_or_default()
    )
}

/// tmp + rename, exactly as `cert.rs` publishes signaling.json: a collector
/// polling this file never reads a half-written one.
pub fn dump(path: &str, tile: &str, uptime_secs: u64) -> std::io::Result<()> {
    let tmp = format!("{path}.tmp.{}", std::process::id());
    std::fs::write(&tmp, render(tile, uptime_secs))?;
    std::fs::rename(&tmp, path)
}

/// Periodic dump + one final dump on SIGTERM/SIGINT.
///
/// TRAP, and the reason this is not a plain `exit(0)`: `streamhost@.service` is
/// `Restart=on-failure`, so the process's EXIT DISPOSITION is load-bearing.
/// Handling SIGTERM and exiting 0 would silently convert "killed by SIGTERM"
/// into "exited cleanly" for every station in the fleet. So the handler dumps,
/// restores the default disposition, and re-raises — systemd sees precisely
/// what it saw before this module existed.
pub fn spawn(tile: &str) {
    let path = dump_path(tile);
    let tile = tile.to_string();
    let every = env_u64("SH_PROBES_DUMP_SECS", 60).max(1);
    let start = std::time::Instant::now();
    eprintln!(
        "[probes] {} probes -> {path} every {every}s (+ on SIGTERM/SIGINT)",
        ALL.len()
    );

    {
        let (path, tile) = (path.clone(), tile.clone());
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(every));
            loop {
                tick.tick().await;
                if let Err(e) = dump(&path, &tile, start.elapsed().as_secs()) {
                    eprintln!("[probes] dump to {path} failed: {e}");
                }
            }
        });
    }

    tokio::spawn(async move {
        use tokio::signal::unix::{signal, SignalKind};
        let (Ok(mut term), Ok(mut int)) = (
            signal(SignalKind::terminate()),
            signal(SignalKind::interrupt()),
        ) else {
            eprintln!("[probes] could not install the shutdown dump handler");
            return;
        };
        let sig = tokio::select! {
            _ = term.recv() => libc::SIGTERM,
            _ = int.recv() => libc::SIGINT,
        };
        let _ = dump(&path, &tile, start.elapsed().as_secs());
        // SAFETY: restoring SIG_DFL and re-raising is the documented way to die
        // exactly as we would have without a handler installed.
        unsafe {
            libc::signal(sig, libc::SIG_DFL);
            libc::raise(sig);
        }
    });
}

#[cfg(test)]
#[path = "probes_tests.rs"]
mod tests;
