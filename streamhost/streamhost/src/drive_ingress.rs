//! OPERATOR DRIVE ingress — how an agent drives a LIVE station without stopping it.
//!
//! THE WALL THIS REMOVES. Every absolute-pointer backend reaches its guest over a
//! socket that is single-client BY DESIGN: `ptr.sock` is a QEMU *chardev*
//! (`server=on,wait=off`) owned by the guest's `kh-ramabs`/`artist`/`mga` device,
//! and each launcher states the contract in a comment — "SINGLE INJECTOR
//! (BINDING): while ptr.sock is connected this device owns the pointer". This
//! daemon is that one client. A second connection does not error; it hangs with
//! no HELLO. So the only way to curate a scene, measure a pointer or debug input
//! used to be `systemctl stop streamhost@<x>`, re-run the launcher by hand on the
//! same sockets, drive, recapture, `systemctl start` — the station off the air
//! for the whole session, and a hand-rolled launcher run next to a live golden.
//!
//! THE SHAPE. We do NOT hand out a second connection to the guest device. The
//! daemon stays the single injector and the sole authority: this module is
//! another mouth on the SAME `input::handle` pipeline the browser feeds — the
//! daemon-wide `SharedMouse`, the abs→rel bridge, `cseq` ordering, key pacing,
//! the router, the idle-pause accounting. `webrtc_input.rs` already proved this
//! seam for the Safari fallback; an agent is simply a third client of it, and the
//! record wire is byte-identical (`input.rs`), so there is no second decoder and
//! no second way for a record to mean something.
//!
//! THE FENCE. This grants NOTHING to the public plane. The ingress is a Unix
//! socket at mode 0600 in a 0700 root-owned runtime directory: it is reachable
//! only by root on labhost, which is `ssh lab` — the one door — and root there
//! can already stop the unit and run the launcher by hand. **The capability is
//! one root already had; what is new is that exercising it no longer takes the
//! station down.** Nothing here touches `gate.py`, the invite roles, the
//! anonymous budget or the walk-in slot fences, and no visitor path can reach it.
//! That is exactly why an "interact-role invite" was rejected: it would have put
//! input rights into the authenticated *public* plane, where the blast radius is
//! every fence in `docs/lab/walkin/CONTRACT-LEDGER.md`.
//!
//! THE LEASE — auditable, singular, self-expiring.
//!   * A client must declare WHO it is (`holder`, in practice `$KH_SESSION`) and
//!     WHY (`reason`) before a single record is injected.
//!   * There is at most ONE lease per station. A second client is REFUSED — and
//!     told the current holder and expiry — rather than silently sharing the
//!     pointer (rule 8: "it exists" is not "it is mine", fail loudly).
//!   * It EXPIRES ON ITS OWN. `ttl` is clamped to `MAX_TTL_SECS`; at the deadline
//!     the daemon drops the connection whatever the client is doing. An agent
//!     that dies mid-drive does not leave a station held.
//!   * It is AUDITABLE while held: the journal gets a line on grant, refusal and
//!     release, and `<dir>/drive-<tile>.lease.json` states holder, reason, since
//!     and expiry for `labctl` to read. Release removes the file.
//!
//! WHY THIS DOES NOT REPEAT THE WAKELEASE TRAP. `guest_wake.WakeLease` keeps a
//! guest awake by ADDING a QMP client — so an observer can itself cause the stall
//! it is watching for. A drive lease adds no client to anything: it holds the
//! daemon's OWN `idle::SessionGuard`, the same bookkeeping a browser session
//! holds, so the guest stays awake for the drive by being counted, not by being
//! poked. `input::handle`'s `wake_for_input` still covers a guest frozen before
//! the lease was taken.
//!
//! WIRE (client → daemon, one connection per lease):
//!   `OSGDRV1`                       7-byte magic
//!   `<json>\n`                      lease request: {"holder":…,"reason":…,"ttl":…}
//!   ← `<json>\n`                    {"ok":true,"tile":…,"expires_unix":…,"ttl":…}
//!                                   or {"ok":false,"error":…,"holder":…,"expires_unix":…}
//!   `[len u32 LE][record…]`…        records, byte-identical to `input.rs`
//!
//! DISABLE with `SH_DRIVE_INGRESS=0`. `SH_DRIVE_DIR` relocates the runtime
//! directory (an isolated test or a sandbox clone); empty disables it too.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};

use crate::capture::Capture;
use crate::config::Config;

const DEFAULT_DIR: &str = "/run/osgallery-drive";
const MAGIC: &[u8; 7] = b"OSGDRV1";
const MAX_RECORD: usize = 4096;
/// A drive lease is a working session, not a tenancy: 15 minutes is long enough
/// to curate a scene and short enough that a dead agent frees the station on its
/// own. Longer work re-takes the lease, which re-states who is driving.
const MAX_TTL_SECS: u64 = 900;
const DEFAULT_TTL_SECS: u64 = 300;

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// What a client asked for. Parsed without serde-deriving a public type: the
/// request is three scalars and the daemon must survive any garbage on the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LeaseRequest {
    pub holder: String,
    pub reason: String,
    pub ttl: u64,
}

/// The one lease a station can have. `None` = nobody is driving.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lease {
    pub holder: String,
    pub reason: String,
    pub since: u64,
    pub expires: u64,
}

/// The decision, made as a pure function so every branch is a unit test rather
/// than a live-station experiment.
#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    /// Grant, and this is the lease to record.
    Grant(Lease),
    /// Refuse, naming who holds it and until when (an empty holder = a bad request).
    Refuse { why: String, held_by: Option<Lease> },
}

/// Clamp a requested TTL into something a forgotten agent cannot sit on.
pub fn clamp_ttl(requested: u64) -> u64 {
    if requested == 0 {
        DEFAULT_TTL_SECS
    } else {
        requested.min(MAX_TTL_SECS)
    }
}

/// THE SEAM. Given the lease currently held (if any) and a request, decide.
///
/// An EXPIRED lease is not a lease: it is stepped over without ceremony, because
/// the whole point of a deadline is that nobody has to come back and clear it.
pub fn decide(current: Option<&Lease>, req: &LeaseRequest, now: u64) -> Decision {
    if req.holder.trim().is_empty() {
        return Decision::Refuse {
            why: "a drive lease must name its holder".to_string(),
            held_by: None,
        };
    }
    if let Some(cur) = current {
        if cur.expires > now {
            return Decision::Refuse {
                why: format!(
                    "station is being driven by {} until unix {}",
                    cur.holder, cur.expires
                ),
                held_by: Some(cur.clone()),
            };
        }
    }
    let ttl = clamp_ttl(req.ttl);
    Decision::Grant(Lease {
        holder: req.holder.clone(),
        reason: req.reason.clone(),
        since: now,
        expires: now + ttl,
    })
}

/// Minimal JSON string field read. The request is machine-written by our own
/// client; anything else is refused rather than interpreted generously.
fn json_str(src: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\"");
    let i = src.find(&pat)? + pat.len();
    let rest = &src[i..];
    let rest = rest.trim_start();
    let rest = rest.strip_prefix(':')?.trim_start();
    let rest = rest.strip_prefix('"')?;
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => out.push(chars.next()?),
            _ => out.push(c),
        }
    }
    None
}

fn json_u64(src: &str, key: &str) -> Option<u64> {
    let pat = format!("\"{key}\"");
    let i = src.find(&pat)? + pat.len();
    let rest = src[i..].trim_start().strip_prefix(':')?.trim_start();
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// Parse a lease request line. `holder` is mandatory; the rest have defaults.
pub fn parse_request(line: &str) -> Option<LeaseRequest> {
    Some(LeaseRequest {
        holder: json_str(line, "holder")?,
        reason: json_str(line, "reason").unwrap_or_default(),
        ttl: json_u64(line, "ttl").unwrap_or(DEFAULT_TTL_SECS),
    })
}

fn escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// The audit record written beside the socket while a lease is held.
pub fn lease_json(tile: &str, l: &Lease) -> String {
    format!(
        "{{\"tile\":\"{}\",\"holder\":\"{}\",\"reason\":\"{}\",\"since_unix\":{},\"expires_unix\":{}}}\n",
        escape(tile),
        escape(&l.holder),
        escape(&l.reason),
        l.since,
        l.expires
    )
}

/// Runtime directory + socket path, or `None` when the ingress is switched off.
fn socket_dir() -> Option<PathBuf> {
    if std::env::var("SH_DRIVE_INGRESS").ok().as_deref() == Some("0") {
        return None;
    }
    match std::env::var_os("SH_DRIVE_DIR") {
        Some(v) if v.is_empty() => None,
        Some(v) => Some(PathBuf::from(v)),
        None => Some(PathBuf::from(DEFAULT_DIR)),
    }
}

/// The station's lease file — what `labctl` reads to answer "who is driving?".
pub fn lease_path(dir: &std::path::Path, tile: &str) -> PathBuf {
    dir.join(format!("drive-{tile}.lease.json"))
}

/// Set a path's mode and FAIL if it did not take — see the call sites in `spawn`.
fn harden(path: &std::path::Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))?;
    let got = std::fs::metadata(path)?.permissions().mode() & 0o777;
    if got != mode {
        return Err(std::io::Error::other(format!(
            "mode is {got:04o} after asking for {mode:04o}"
        )));
    }
    Ok(())
}

/// Per-station lease cell. A std Mutex: every critical section is a compare and a
/// clone, never an await, so the lease can also be consulted from a drop.
type Cell = Arc<StdMutex<Option<Lease>>>;

pub fn spawn(
    cfg: Arc<Config>,
    cap: Capture,
    mouse: crate::input::SharedMouse,
    router: Option<Arc<crate::realtime_input::InputRouter>>,
    key_reap_tx: tokio::sync::mpsc::UnboundedSender<Vec<u16>>,
    pauser: Option<Arc<crate::idle::IdlePauser>>,
) {
    let Some(dir) = socket_dir() else {
        eprintln!("[drive] operator drive ingress OFF (SH_DRIVE_INGRESS=0)");
        return;
    };
    tokio::spawn(async move {
        // 0700 root: the fence is the filesystem. Created here rather than as a
        // systemd RuntimeDirectory so a sandbox clone with SH_DRIVE_DIR gets the
        // same shape without editing a unit template.
        if let Err(e) = tokio::fs::create_dir_all(&dir).await {
            eprintln!("[drive] cannot create {}: {e}", dir.display());
            return;
        }
        // The permission call IS the fence, so its result is load-bearing. A
        // swallowed error here leaves the directory at whatever create_dir_all
        // and the umask produced (0755, typically) and the socket below
        // reachable by every local user — an input channel into a live guest,
        // failing OPEN and saying nothing. Everything else here that fences
        // fails closed (gate.py's default-deny, clone-guard); so does this. A
        // station with no drive ingress still works; a world-reachable one is
        // not a station anyone should be running.
        if let Err(e) = harden(&dir, 0o700) {
            eprintln!(
                "[drive] cannot secure {} (0700): {e} — ingress OFF",
                dir.display()
            );
            return;
        }
        let path = dir.join(format!("drive-{}.sock", cfg.tile));
        let _ = tokio::fs::remove_file(&path).await;
        let _ = tokio::fs::remove_file(lease_path(&dir, &cfg.tile)).await;
        let listener = match UnixListener::bind(&path) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("[drive] cannot bind {}: {e}", path.display());
                return;
            }
        };
        if let Err(e) = harden(&path, 0o600) {
            // Unlink it: a bound socket nobody could lock down is precisely the
            // thing that must not be left lying in the runtime directory.
            let _ = tokio::fs::remove_file(&path).await;
            eprintln!(
                "[drive] cannot secure {} (0600): {e} — ingress OFF",
                path.display()
            );
            return;
        }
        eprintln!(
            "[drive] operator drive ingress listening at {}",
            path.display()
        );
        let cell: Cell = Arc::new(StdMutex::new(None));
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    let (cfg, cap, mouse, router, cell, dir) = (
                        cfg.clone(),
                        cap.clone(),
                        mouse.clone(),
                        router.clone(),
                        cell.clone(),
                        dir.clone(),
                    );
                    let keys = crate::key_state::new_session(key_reap_tx.clone());
                    let pauser = pauser.clone();
                    tokio::spawn(async move {
                        if let Err(e) =
                            serve(stream, cfg, cap, mouse, router, keys, pauser, cell, dir).await
                        {
                            eprintln!("[drive] client ended: {e}");
                        }
                    });
                }
                Err(e) => {
                    eprintln!("[drive] accept failed: {e}");
                    return;
                }
            }
        }
    });
}

/// Release the lease IF this client still owns it, and clear the audit file.
/// Runs on every exit path — clean close, bad frame, expiry, a dropped agent.
fn release(cell: &Cell, dir: &std::path::Path, tile: &str, mine: &Lease) {
    let mut g = match cell.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    };
    if g.as_ref() == Some(mine) {
        *g = None;
        let _ = std::fs::remove_file(lease_path(dir, tile));
        eprintln!(
            "[drive] RELEASED tile={} holder={} held={}s",
            tile,
            mine.holder,
            now_unix().saturating_sub(mine.since)
        );
    }
}

#[allow(clippy::too_many_arguments)]
async fn serve(
    mut stream: UnixStream,
    cfg: Arc<Config>,
    cap: Capture,
    mouse: crate::input::SharedMouse,
    router: Option<Arc<crate::realtime_input::InputRouter>>,
    keys: crate::key_state::SharedKeys,
    pauser: Option<Arc<crate::idle::IdlePauser>>,
    cell: Cell,
    dir: PathBuf,
) -> anyhow::Result<()> {
    let mut magic = [0u8; MAGIC.len()];
    stream.read_exact(&mut magic).await?;
    if &magic != MAGIC {
        anyhow::bail!("bad drive handshake");
    }
    // The request line: read a byte at a time so the first input record cannot be
    // swallowed by an over-read.
    let mut line = Vec::new();
    loop {
        let mut b = [0u8; 1];
        stream.read_exact(&mut b).await?;
        if b[0] == b'\n' {
            break;
        }
        line.push(b[0]);
        if line.len() > MAX_RECORD {
            anyhow::bail!("lease request too long");
        }
    }
    let text = String::from_utf8_lossy(&line).to_string();
    let Some(req) = parse_request(&text) else {
        stream
            .write_all(b"{\"ok\":false,\"error\":\"unparseable lease request\"}\n")
            .await?;
        anyhow::bail!("unparseable lease request");
    };

    let decision = {
        let mut g = match cell.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        };
        let d = decide(g.as_ref(), &req, now_unix());
        if let Decision::Grant(l) = &d {
            *g = Some(l.clone());
        }
        d
    };
    let lease = match decision {
        Decision::Refuse { why, held_by } => {
            let extra = held_by
                .map(|l| {
                    format!(
                        ",\"holder\":\"{}\",\"expires_unix\":{}",
                        escape(&l.holder),
                        l.expires
                    )
                })
                .unwrap_or_default();
            eprintln!(
                "[drive] REFUSED tile={} want={} reason={why}",
                cfg.tile, req.holder
            );
            stream
                .write_all(
                    format!("{{\"ok\":false,\"error\":\"{}\"{extra}}}\n", escape(&why)).as_bytes(),
                )
                .await?;
            return Ok(());
        }
        Decision::Grant(l) => l,
    };

    // AUDIT: the journal line and the lease file are written BEFORE the first
    // record can be injected, so there is no window in which a station is being
    // driven by someone the box cannot name.
    eprintln!(
        "[drive] GRANTED tile={} holder={} ttl={}s reason={:?}",
        cfg.tile,
        lease.holder,
        lease.expires - lease.since,
        lease.reason
    );
    let _ = std::fs::write(lease_path(&dir, &cfg.tile), lease_json(&cfg.tile, &lease));
    stream
        .write_all(
            format!(
                "{{\"ok\":true,\"tile\":\"{}\",\"holder\":\"{}\",\"since_unix\":{},\"expires_unix\":{}}}\n",
                escape(&cfg.tile),
                escape(&lease.holder),
                lease.since,
                lease.expires
            )
            .as_bytes(),
        )
        .await?;

    // The guest must be AWAKE for the whole drive, and this is how without adding
    // a QMP client: the daemon's own session count, exactly as a browser session
    // and the WebRTC fallback peer do.
    let _session_guard = pauser.as_ref().map(|p| {
        let p = p.clone();
        tokio::spawn({
            let p = p.clone();
            async move { p.session_started().await }
        });
        crate::idle::SessionGuard::new(p)
    });
    // A fresh driver tracks the daemon-wide guest cursor rather than corner-chasing.
    mouse.lock().await.reset_for_session();

    let deadline = tokio::time::Instant::now()
        + std::time::Duration::from_secs(lease.expires.saturating_sub(lease.since));
    let router_ref = router.as_ref();
    let outcome = async {
        let mut len_buf = [0u8; 4];
        loop {
            if stream.read_exact(&mut len_buf).await.is_err() {
                return Ok::<(), anyhow::Error>(()); // client closed
            }
            let len = u32::from_le_bytes(len_buf) as usize;
            if !(1..=MAX_RECORD).contains(&len) {
                anyhow::bail!("bad drive frame length {len}");
            }
            let mut frame = vec![0u8; len];
            stream.read_exact(&mut frame).await?;
            // The SAME decoder and the SAME pipeline as every other client.
            crate::input::handle(&cap, &cfg, &mouse, &keys, router_ref, &frame).await;
        }
    };
    // THE DEADLINE IS ENFORCED HERE, not by the client's good manners.
    let r = tokio::time::timeout_at(deadline, outcome).await;
    if r.is_err() {
        eprintln!(
            "[drive] EXPIRED tile={} holder={} — lease deadline reached, dropping client",
            cfg.tile, lease.holder
        );
    }
    release(&cell, &dir, &cfg.tile, &lease);
    // Held keys are reaped by `key_state`'s reaper when `keys` drops, so an agent
    // killed mid-keystroke cannot leave a key down on a live exhibit.
    match r {
        Ok(inner) => inner,
        Err(_) => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(holder: &str, ttl: u64) -> LeaseRequest {
        LeaseRequest {
            holder: holder.to_string(),
            reason: "test".to_string(),
            ttl,
        }
    }

    #[test]
    fn a_lease_must_name_its_holder() {
        assert!(matches!(
            decide(None, &req("", 60), 1000),
            Decision::Refuse { held_by: None, .. }
        ));
        assert!(matches!(
            decide(None, &req("   ", 60), 1000),
            Decision::Refuse { held_by: None, .. }
        ));
    }

    #[test]
    fn ttl_is_clamped_and_defaulted() {
        assert_eq!(clamp_ttl(0), DEFAULT_TTL_SECS);
        assert_eq!(clamp_ttl(30), 30);
        assert_eq!(clamp_ttl(86_400), MAX_TTL_SECS);
        // The clamp is what the GRANT records, not what the client asked for.
        match decide(None, &req("live-drive", 86_400), 1000) {
            Decision::Grant(l) => assert_eq!(l.expires, 1000 + MAX_TTL_SECS),
            d => panic!("expected a grant, got {d:?}"),
        }
    }

    #[test]
    fn a_second_driver_is_refused_loudly_and_told_who_holds_it() {
        let held = match decide(None, &req("agent-a", 300), 1000) {
            Decision::Grant(l) => l,
            d => panic!("expected a grant, got {d:?}"),
        };
        match decide(Some(&held), &req("agent-b", 300), 1100) {
            Decision::Refuse { why, held_by } => {
                let by = held_by.expect("a refusal names the holder");
                assert_eq!(by.holder, "agent-a");
                assert_eq!(by.expires, 1300);
                assert!(why.contains("agent-a"), "the refusal says who: {why}");
            }
            d => panic!("expected a refusal, got {d:?}"),
        }
    }

    /// THE PROPERTY THAT MAKES THIS SAFE TO LEAVE UNATTENDED: an expired lease is
    /// not a lease. Nobody has to come back and clear it, so an agent that dies
    /// mid-drive cannot hold a live exhibit hostage past its deadline.
    #[test]
    fn an_expired_lease_does_not_block_the_next_driver() {
        let held = match decide(None, &req("dead-agent", 300), 1000) {
            Decision::Grant(l) => l,
            d => panic!("expected a grant, got {d:?}"),
        };
        assert_eq!(held.expires, 1300);
        // One second before the deadline it still holds…
        assert!(matches!(
            decide(Some(&held), &req("agent-b", 60), 1299),
            Decision::Refuse { .. }
        ));
        // …and at it, it does not.
        match decide(Some(&held), &req("agent-b", 60), 1300) {
            Decision::Grant(l) => assert_eq!(l.holder, "agent-b"),
            d => panic!("expected a grant at the deadline, got {d:?}"),
        }
    }

    #[test]
    fn request_parsing_takes_ours_and_refuses_garbage() {
        let r = parse_request(r#"{"holder":"live-drive","reason":"curate a scene","ttl":120}"#)
            .expect("our own client's line parses");
        assert_eq!(r.holder, "live-drive");
        assert_eq!(r.reason, "curate a scene");
        assert_eq!(r.ttl, 120);
        // Defaults, and the one mandatory field.
        assert_eq!(
            parse_request(r#"{"holder":"x"}"#).map(|r| r.ttl),
            Some(DEFAULT_TTL_SECS)
        );
        assert!(parse_request(r#"{"reason":"no holder"}"#).is_none());
        assert!(parse_request("not json at all").is_none());
    }

    #[test]
    fn the_audit_record_names_holder_reason_and_deadline() {
        let l = Lease {
            holder: "live-drive".to_string(),
            reason: "pointer measure".to_string(),
            since: 1000,
            expires: 1300,
        };
        let j = lease_json("os213", &l);
        for needle in [
            "\"tile\":\"os213\"",
            "\"holder\":\"live-drive\"",
            "\"reason\":\"pointer measure\"",
            "\"since_unix\":1000",
            "\"expires_unix\":1300",
        ] {
            assert!(j.contains(needle), "lease json missing {needle}: {j}");
        }
    }

    #[test]
    fn quotes_in_a_holder_name_cannot_break_the_audit_record() {
        let l = Lease {
            holder: "a\"b\\c".to_string(),
            reason: String::new(),
            since: 1,
            expires: 2,
        };
        assert!(lease_json("t", &l).contains("\"holder\":\"a\\\"b\\\\c\""));
    }

    #[test]
    fn the_ingress_can_be_switched_off() {
        // SAFETY: single-threaded test; no other thread reads this var concurrently.
        unsafe { std::env::set_var("SH_DRIVE_INGRESS", "0") };
        assert!(socket_dir().is_none());
        unsafe { std::env::remove_var("SH_DRIVE_INGRESS") };
        unsafe { std::env::set_var("SH_DRIVE_DIR", "") };
        assert!(socket_dir().is_none());
        unsafe { std::env::remove_var("SH_DRIVE_DIR") };
    }

    // ---- the filesystem fence ------------------------------------------
    // This ingress types into a LIVE guest, and its only fence is the mode on
    // the socket and its directory. So the mode is verified after it is set,
    // never assumed from a call that returned.

    #[test]
    fn harden_sets_the_mode_it_was_asked_for() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("kh-drive-h-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        harden(&dir, 0o700).unwrap();
        let mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700, "the fence must actually be 0700 on disk");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn harden_fails_on_a_path_that_is_not_there() {
        // The call site treats an error as "ingress OFF" — so it must BE an
        // error, not a silently ignored no-op.
        let missing = std::env::temp_dir().join(format!("kh-drive-none-{}", std::process::id()));
        let _ = std::fs::remove_file(&missing);
        assert!(harden(&missing, 0o600).is_err());
    }
}
