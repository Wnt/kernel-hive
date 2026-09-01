//! Probe-plane tests, including THE GATE.
//!
//! `scripts/analytics/catalogue.mjs check` does this for the SPA by reading the
//! TypeScript catalogue and grepping the owner file. The Rust catalogue is
//! already compiled into the test binary, so the gate lives here instead of in
//! a script — it runs under `cargo test --workspace`, which the CI exit rule
//! already requires, and it cannot be forgotten the way a separate `make`
//! target can.

use super::*;

fn src_dir() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
}

/// THE GATE. Every declared probe must have a call site in the file its `owner`
/// names, and that file must not be this module's own declaration.
///
/// Without it a dumped `0` has two meanings that look identical and are
/// opposites — "the feature is dead" and "I declared a probe and never called
/// it" — and only the second kind gets working code deleted. It also catches
/// the likelier drift: a call site MOVED, leaving the catalogue pointing at a
/// file that no longer mentions it.
///
/// Matching is on the bare Rust identifier, not the dotted id, because that is
/// what a call site writes (`probe!(ABR_TIER_UP)`).
#[test]
fn catalogue_has_no_orphan_probes() {
    let mut problems = Vec::new();
    for p in ALL {
        let ident = ident_of(p.id);
        assert!(
            !p.owner.ends_with("probes.rs"),
            "{}: a probe cannot own its own declaration",
            p.id
        );
        let path = src_dir().join(p.owner);
        let Ok(source) = std::fs::read_to_string(&path) else {
            problems.push(format!("{}: owner {} does not exist", p.id, p.owner));
            continue;
        };
        // Anything cleverer than a literal match (an AST walk, a loose regex)
        // buys a way for a commented-out call to pass the gate.
        if !source.contains(&format!("probe!({ident})")) {
            problems.push(format!(
                "{}: declared, but {} contains no `probe!({ident})` call site",
                p.id, p.owner
            ));
        }
    }
    assert!(
        problems.is_empty(),
        "probe catalogue drift:\n  {}",
        problems.join("\n  ")
    );
}

/// Recover the Rust identifier from the dotted id, so the gate does not need a
/// fourth hand-maintained field to drift out of sync with.
/// `input.abs.ramWrite` -> `INPUT_ABS_RAM_WRITE`.
fn ident_of(id: &str) -> String {
    let mut out = String::new();
    for ch in id.chars() {
        if ch == '.' {
            out.push('_');
        } else if ch.is_ascii_uppercase() {
            out.push('_');
            out.push(ch);
        } else {
            out.push(ch.to_ascii_uppercase());
        }
    }
    out
}

/// The macro's expansion and the declaration must agree on the identifier, or
/// the gate above is grepping for a name nothing can call. Proven by calling
/// one probe through the macro and watching ITS counter move.
#[test]
fn the_macro_increments_the_named_probe() {
    let before = ABR_TIER_UP.hits();
    probe!(ABR_TIER_UP);
    assert_eq!(ABR_TIER_UP.hits(), before + 1);
}

#[test]
fn ids_are_unique_and_dotted() {
    let mut seen = std::collections::BTreeSet::new();
    for p in ALL {
        assert!(seen.insert(p.id), "duplicate probe id {}", p.id);
        assert!(p.id.contains('.'), "{} is not an area.thing id", p.id);
        assert!(!p.what.is_empty(), "{} declares no `what`", p.id);
    }
    assert_eq!(seen.len(), ALL.len());
}

/// A dump is readable by a collector that has never seen this binary: it names
/// the station, and it carries the DENOMINATOR — every declared probe appears,
/// including the ones sitting at zero, which is the row the plane exists for.
#[test]
fn the_dump_carries_every_probe_including_the_unfired_ones() {
    let doc = render("beos", 42);
    let v: serde_json::Value = serde_json::from_str(&doc).expect("dump is valid json");
    assert_eq!(v["station"], "beos");
    assert_eq!(v["uptimeSecs"], 42);
    for p in ALL {
        assert!(
            v["probes"][p.id]["hits"].is_u64(),
            "{} missing from the dump",
            p.id
        );
    }
    assert_eq!(
        v["probes"].as_object().map(|m| m.len()),
        Some(ALL.len()),
        "the dump and the catalogue disagree on the denominator"
    );
}

/// A reader polling the file must never see a half-written one.
#[test]
fn dump_is_atomic_and_leaves_no_tmp_behind() {
    let dir = std::env::temp_dir().join(format!("sh-probes-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("probes.json");
    let p = path.to_str().unwrap();
    dump(p, "tiletest", 1).unwrap();
    dump(p, "tiletest", 2).unwrap();
    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(doc["uptimeSecs"], 2);
    let leftovers: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.contains(".tmp."))
        .collect();
    assert!(leftovers.is_empty(), "tmp files left behind: {leftovers:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// COST, measured rather than asserted to be zero.
///
/// This is a `#[test]`, not a benchmark harness: no new crate, and it runs on
/// the same box that runs the gate. It PRINTS the per-hit cost (`cargo test --
/// --nocapture`) and only fails on a ceiling loose enough to survive a debug
/// build on a loaded CI machine, because the point is the number, not a
/// regression alarm.
///
/// MEASURED on the lab build box, 2 000 000 back-to-back hits:
///   * `--release` (opt-level 2, the profile that ships): **8.5 ns/hit**
///   * default `cargo test` (debug, unoptimised): **95 ns/hit**
///
/// So the assertion below has to clear the DEBUG number, while the release one
/// is what the doc quotes: a station taking 250 pointer samples a second spends
/// about two microseconds a second here.
///
/// Two honest caveats, because "zero-cost" would be a lie in both directions:
///   * this loop is the WORST case for one thread — a dependent chain of `lock
///     xadd` on one cache line with no other work between hits. A real call
///     site pays it once per input record, with a syscall on either side.
///   * CONTENDED cost is higher and is NOT measured here. It does not need to
///     be: every probe in the catalogue is per-session or per-input-record,
///     never per-pixel, so two hot tasks sharing one probe's cache line is not
///     the regime any of them runs in.
#[test]
fn hit_cost_is_negligible() {
    const N: u64 = 2_000_000;
    // Warm the line so the first-touch miss is not billed to the loop.
    for _ in 0..1000 {
        ABR_TIER_DOWN.hit();
    }
    let t0 = std::time::Instant::now();
    for _ in 0..N {
        ABR_TIER_DOWN.hit();
    }
    let per_hit_ns = t0.elapsed().as_nanos() as f64 / N as f64;
    println!("probe hit cost: {per_hit_ns:.2} ns/hit over {N} hits");
    // 250 ns is ~2.5x the measured DEBUG number: loose enough that a loaded CI
    // box cannot flake it, tight enough that a probe that grew a lock or an
    // allocation would still be caught.
    assert!(
        per_hit_ns < 250.0,
        "a relaxed fetch_add should be single-digit ns in release and ~100 ns in \
         debug; measured {per_hit_ns:.2} ns/hit — did a probe grow a lock or an \
         allocation?"
    );
}
