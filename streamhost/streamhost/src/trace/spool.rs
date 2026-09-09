//! Where the spans go, and why they go to a DIRECTORY rather than over a socket.
//!
//! THE CHOICE. `traces.py` accepts `POST /traces` with a batch body, so the
//! obvious design is for the daemon to post its own spans. It is the wrong one
//! here, for three reasons in order:
//!
//!   1. **The exhibit outranks the telemetry.** A station that cannot reach the
//!      collector must keep streaming (contract §7). A POST means a client that
//!      can hang, retry, hold a connection open and compete for the runtime with
//!      the 16 ms frame budget — and it means writing the failure policy for all
//!      of that. A `rename(2)` into a directory has no failure mode that can
//!      reach the encoder.
//!   2. **There is no HTTP client in this binary and the collector is HTTPS.**
//!      Adding one means adding a TLS stack to a daemon that deliberately
//!      carries none (its own QUIC cert is self-signed and hand-rolled in
//!      `cert.rs`). `probes.rs` set the precedent — publish a file beside
//!      `signaling.json`, let something that already speaks HTTPS ship it — and
//!      a second answer to the same question in the same daemon would be worse
//!      than either answer alone.
//!   3. **The file IS the request body.** Each spool file is exactly the JSON
//!      `POST /traces` accepts, so the shipper is `curl -d @file` and nothing is
//!      needed server-side. That was the brief's requirement and it falls out.
//!
//! WHAT IT COSTS WHEN NOBODY COLLECTS. `SPOOL_MAX` files, oldest deleted first.
//! A station whose collector never runs loses its oldest spans and keeps
//! streaming; it does not fill `/data`. Spans are one-off per session and per
//! daemon start (never per frame — see `trace/mod.rs`), so the default ceiling
//! is days of a busy station, not hours.
//!
//! DURABILITY IS tmp+rename, the same dance `cert.rs` and `probes.rs` use: a
//! collector polling this directory never reads a half-written file, and never
//! has to guess whether a file is finished.

use std::path::{Path, PathBuf};

/// Spool directory: beside the station's other published runtime artifacts
/// (`signaling.json`, `cert_hash_b64.txt`, `probes.json`), which is already the
/// bind-mounted place a collector can read. `SH_TRACE_DIR` overrides it, for a
/// sandbox run that must not write into a live station's directory.
pub fn spool_dir(tile: &str) -> PathBuf {
    match std::env::var("SH_TRACE_DIR") {
        Ok(s) if !s.trim().is_empty() => PathBuf::from(s.trim()),
        _ => PathBuf::from(format!("/data/vms/streamhost/stations/{tile}/traces")),
    }
}

/// Log spool directory: the sibling of `traces/`, beside it under the station's
/// published runtime artifacts, so ONE shipper walks both. `SH_LOG_DIR`
/// overrides it for a sandbox run.
pub fn log_spool_dir(tile: &str) -> PathBuf {
    match std::env::var("SH_LOG_DIR") {
        Ok(s) if !s.trim().is_empty() => PathBuf::from(s.trim()),
        _ => PathBuf::from(format!("/data/vms/streamhost/stations/{tile}/logs")),
    }
}

/// One batch body, exactly as `POST /logs` accepts it.
///
/// Unlike the span batch, this one CAN name its resource honestly: a log record
/// is a fact about this process, so `service.instance.id` is the station and
/// `service.name` is the daemon. `session.id` stays `"unknown"` for the same
/// reason it does above — the tab's analytics session is not something this
/// process can know, and a per-record `sid` is the seam if it ever becomes one.
pub fn log_batch(tile: &str, records: &[String]) -> String {
    let mut s = String::with_capacity(128 + records.iter().map(|x| x.len() + 1).sum::<usize>());
    s.push_str("{\"resource\":{\"service.name\":\"kernel-hive-daemon\",\"service.instance.id\":\"");
    // The tile name is a registry id (`^[a-z0-9-]+$`, enforced by
    // stations-registry.py), so it needs no escaping — but it is escaped
    // anyway, because "the caller always passes a safe value" is the assumption
    // that eventually is not true.
    crate::trace::push_str_json_pub(&mut s, tile);
    s.push_str("\",\"session.id\":\"unknown\"},\"logs\":[");
    for (i, rec) in records.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(rec);
    }
    s.push_str("]}\n");
    s
}

/// One batch body, exactly as `POST /traces` accepts it.
///
/// `session.id` is deliberately `"unknown"`. That field is the TAB's analytics
/// session and this process cannot know it: a batch here spans every visitor
/// the station had in the flush window. `traces.py` already normalises an
/// unusable value to `"unknown"`, and its trace summary keeps whichever batch
/// created the row — in practice the tab's, which flushes every ~20 s while the
/// daemon's session span cannot exist until the session ends. Claiming the
/// station id here would put a station name in a column that means "one tab",
/// which is the kind of quiet lie that costs an afternoon later.
///
/// `kh.class` is `"unknown"` for the same reason: human-vs-probe is a judgement
/// the SPA makes about its own operator, and the daemon sees a QUIC session.
pub fn batch(spans: &[String]) -> String {
    let mut s = String::with_capacity(64 + spans.iter().map(|x| x.len() + 1).sum::<usize>());
    s.push_str("{\"resource\":{\"session.id\":\"unknown\",\"kh.class\":\"unknown\"},\"spans\":[");
    for (i, span) in spans.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(span);
    }
    s.push_str("]}\n");
    s
}

/// Write one batch. tmp + rename, so a reader never sees half a file.
pub fn write_batch(dir: &Path, seq: u64, body: &str) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    let now_ms = crate::trace::now_unix_ms();
    let name = format!("{now_ms:013}-{}-{seq:06}.json", std::process::id());
    let path = dir.join(&name);
    let tmp = dir.join(format!("{name}.tmp"));
    std::fs::write(&tmp, body)?;
    std::fs::rename(&tmp, &path)?;
    Ok(path)
}

/// Keep at most `max` batch files, deleting the oldest. Names begin with a
/// zero-padded millisecond stamp, so lexical order IS chronological order and
/// this needs no `stat` per file.
pub fn prune(dir: &Path, max: usize) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    let mut files: Vec<PathBuf> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .collect();
    if files.len() <= max {
        return;
    }
    files.sort();
    for p in files.iter().take(files.len() - max) {
        let _ = std::fs::remove_file(p);
    }
}
