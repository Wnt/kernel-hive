//! devwatch — the dev-mode watcher for the station registry's single-source files.
//!
//! Watches the hand-written sources (registry/tiles, registry/posters,
//! registry-v1.json, templates, streamhost/tiles fixtures, spa/src) and, on
//! every debounced change, runs `tiles-registry.py generate` (which validates
//! first). Only when the change PARSES does anything deploy: runtime manifests
//! (gallery-manifest.json, poster-docs.json, tiles.json, golden-manifest.json)
//! publish to labhost via `serve-https-spa.sh manifests`; UI-compiled outputs
//! request (or, with --spa-autodeploy, run) a Vite build + deploy.
//!
//! Never automated: per-station re-emit and `systemctl restart streamhost@<tile>`
//! — a daemon restart resets a checkpoint-scene station, so scene edits print the
//! recipe instead of applying it.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use clap::Parser;
use notify::{EventKind, RecursiveMode};
use notify_debouncer_full::{new_debouncer, DebounceEventResult, DebouncedEvent};

/// Generated outputs that `serve-https-spa.sh manifests` publishes to labhost.
const MANIFEST_OUTPUTS: &[&str] = &[
    "scripts/serve/tiles.json",
    "scripts/serve/webroot/gallery-manifest.json",
    "scripts/serve/webroot/poster-docs.json",
    "scripts/serve/golden-manifest.json",
];

/// Generated outputs compiled into the UI bundle: changing them needs a build.
const SPA_OUTPUTS: &[&str] = &[
    "spa/src/three/archetypeRegistry.ts",
    "spa/src/mock/manifest.json",
    "spa/src/data/posterIndex.ts",
    "spa/src/data/demoPrograms.ts",
    "spa/src/data/keyboards.ts",
];

const PLACEHOLDER_HOST_IP: &str = "192.0.2.10";

#[derive(Parser)]
#[command(about = "watch registry sources; regenerate + publish when the change parses")]
struct Args {
    /// Repo root (default: walk up from the current directory)
    #[arg(long)]
    repo: Option<PathBuf>,
    /// registry/local.env to read deploy hosts from (default: this repo's,
    /// then the main checkout's when running from a worktree)
    #[arg(long)]
    local_env: Option<PathBuf>,
    /// Also run `serve-https-spa.sh build` + `deploy` when UI sources change
    #[arg(long)]
    spa_autodeploy: bool,
    /// Validate + regenerate only; never run a deploy command
    #[arg(long)]
    dry_run: bool,
}

#[derive(Default)]
struct Dirty {
    registry: bool,
    spa: bool,
    fixtures: BTreeSet<String>,
    tile_kit: BTreeSet<String>,
}

impl Dirty {
    fn is_empty(&self) -> bool {
        !self.registry && !self.spa && self.tile_kit.is_empty()
    }
    fn merge(&mut self, other: Dirty) {
        self.registry |= other.registry;
        self.spa |= other.spa;
        self.fixtures.extend(other.fixtures);
        self.tile_kit.extend(other.tile_kit);
    }
}

fn find_repo(start: &Path) -> Result<PathBuf> {
    let mut dir = start.to_path_buf();
    loop {
        if dir.join("scripts/tiles-registry.py").is_file() && dir.join("registry/tiles").is_dir() {
            return Ok(dir);
        }
        if !dir.pop() {
            bail!("not inside a kernel-hive checkout (scripts/tiles-registry.py not found); pass --repo");
        }
    }
}

/// SH_* values from registry/local.env, exported to every child so the serve
/// script resolves the real host even when devwatch runs from a worktree
/// (local.env lives only in the main checkout).
fn load_local_env(
    repo: &Path,
    explicit: Option<&Path>,
) -> (Vec<(String, String)>, Option<PathBuf>) {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(path) = explicit {
        candidates.push(path.to_path_buf());
    }
    candidates.push(repo.join("registry/local.env"));
    if let Ok(out) = Command::new("git")
        .args(["rev-parse", "--git-common-dir"])
        .current_dir(repo)
        .output()
    {
        if out.status.success() {
            let common = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
            let common = if common.is_absolute() {
                common
            } else {
                repo.join(common)
            };
            if let Some(main_root) = common.parent() {
                candidates.push(main_root.join("registry/local.env"));
            }
        }
    }
    for path in candidates {
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        let mut vars = Vec::new();
        for line in text.lines() {
            let line = line.trim().trim_start_matches("export ");
            if line.starts_with('#') || !line.contains('=') {
                continue;
            }
            let (key, value) = line.split_once('=').unwrap();
            if key.starts_with("SH_") {
                vars.push((
                    key.to_string(),
                    value.trim_matches('"').trim_matches('\'').to_string(),
                ));
            }
        }
        return (vars, Some(path));
    }
    (Vec::new(), None)
}

fn generated_paths(repo: &Path) -> Result<BTreeSet<String>> {
    let out = Command::new("python3")
        .args(["scripts/tiles-registry.py", "paths"])
        .current_dir(repo)
        .output()
        .context("running tiles-registry.py paths")?;
    if !out.status.success() {
        bail!(
            "tiles-registry.py paths failed:\n{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_string)
        .collect())
}

fn ignorable(rel: &str) -> bool {
    let name = rel.rsplit('/').next().unwrap_or(rel);
    name.ends_with('~')
        || name.ends_with(".swp")
        || name.ends_with(".swx")
        || name.ends_with(".tmp")
        || name.starts_with('.')
        || name.starts_with('#')
}

fn classify(repo: &Path, generated: &BTreeSet<String>, paths: &[PathBuf]) -> Dirty {
    let mut dirty = Dirty::default();
    for path in paths {
        let Ok(rel) = path.strip_prefix(repo) else {
            continue;
        };
        let rel = rel.to_string_lossy().replace('\\', "/");
        if ignorable(&rel) || generated.contains(rel.as_str()) {
            continue;
        }
        if let Some(rest) = rel.strip_prefix("streamhost/tiles/") {
            let tile = rest.split('/').next().unwrap_or("").to_string();
            if rest.ends_with("tile.env.fixture") {
                // index.json embeds fixture keys, so a fixture edit is a registry change too.
                dirty.registry = true;
                dirty.fixtures.insert(tile);
            } else if !tile.is_empty() {
                dirty.tile_kit.insert(tile);
            }
        } else if rel.starts_with("registry/") {
            dirty.registry = true;
        } else if rel.starts_with("spa/src/")
            || rel.starts_with("spa/public/")
            || rel == "spa/index.html"
        {
            dirty.spa = true;
        }
    }
    dirty
}

fn snapshot(repo: &Path, paths: &BTreeSet<String>) -> Vec<(String, Option<Vec<u8>>)> {
    paths
        .iter()
        .map(|p| (p.clone(), std::fs::read(repo.join(p)).ok()))
        .collect()
}

fn run(repo: &Path, env: &[(String, String)], program: &str, args: &[&str]) -> Result<bool> {
    let started = Instant::now();
    let display = format!("{program} {}", args.join(" "));
    let status = Command::new(program)
        .args(args)
        .current_dir(repo)
        .envs(env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .status()
        .with_context(|| format!("spawning {display}"))?;
    let secs = started.elapsed().as_secs_f32();
    if status.success() {
        println!("devwatch: {display} ok ({secs:.1}s)");
    } else {
        println!("devwatch: {display} FAILED ({secs:.1}s) — nothing deployed");
    }
    Ok(status.success())
}

fn generate(repo: &Path) -> Result<bool> {
    let started = Instant::now();
    let out = Command::new("python3")
        .args(["scripts/tiles-registry.py", "generate"])
        .current_dir(repo)
        .output()
        .context("running tiles-registry.py generate")?;
    let secs = started.elapsed().as_secs_f32();
    if out.status.success() {
        println!("devwatch: generate ok ({secs:.1}s)");
        return Ok(true);
    }
    println!("devwatch: generate REJECTED the change ({secs:.1}s) — fix and save again:");
    print!("{}", String::from_utf8_lossy(&out.stderr));
    Ok(false)
}

#[allow(clippy::too_many_lines)]
fn pipeline(
    repo: &Path,
    env: &[(String, String)],
    generated: &BTreeSet<String>,
    dirty: &Dirty,
    args: &Args,
    deploys_enabled: bool,
) -> Result<()> {
    let mut spa_dirty = dirty.spa;

    if dirty.registry {
        let before = snapshot(repo, generated);
        if !generate(repo)? {
            return Ok(());
        }
        let changed: BTreeSet<String> = before
            .into_iter()
            .filter(|(path, old)| std::fs::read(repo.join(path)).ok() != *old)
            .map(|(path, _)| path)
            .collect();
        if changed.is_empty() {
            println!("devwatch: no generated output changed");
        } else {
            println!(
                "devwatch: {} generated output(s) changed: {}",
                changed.len(),
                changed.iter().cloned().collect::<Vec<_>>().join(", ")
            );
        }
        if changed
            .iter()
            .any(|p| MANIFEST_OUTPUTS.contains(&p.as_str()))
        {
            if args.dry_run || !deploys_enabled {
                println!("devwatch: would publish runtime manifests (scripts/serve-https-spa.sh manifests)");
            } else {
                run(
                    repo,
                    env,
                    "bash",
                    &["scripts/serve-https-spa.sh", "manifests"],
                )?;
            }
        }
        spa_dirty |= changed.iter().any(|p| SPA_OUTPUTS.contains(&p.as_str()));
        let ops: Vec<&String> = changed
            .iter()
            .filter(|p| {
                !MANIFEST_OUTPUTS.contains(&p.as_str()) && !SPA_OUTPUTS.contains(&p.as_str())
            })
            .collect();
        if !ops.is_empty() {
            println!(
                "devwatch: box-side artifacts changed ({}); sync before pushing: scripts/dev/box-sync-push.sh --apply",
                ops.iter().map(|p| p.as_str()).collect::<Vec<_>>().join(", ")
            );
        }
    }

    for tile in &dirty.fixtures {
        println!(
            "devwatch: {tile}/tile.env.fixture changed — NOT auto-deployed. Re-emit per \
             docs (stage emit kit + registry/local.env, byte-review the diff, then \
             `systemctl restart streamhost@{tile}`; the restart RESETS a golden tile)."
        );
    }
    for tile in &dirty.tile_kit {
        println!("devwatch: emit-kit file changed for {tile} (launcher/aux); re-emit to apply on the box");
    }

    if spa_dirty {
        if args.dry_run || !deploys_enabled || !args.spa_autodeploy {
            println!("devwatch: SPA bundle is stale — run: scripts/serve-https-spa.sh build deploy (or pass --spa-autodeploy)");
        } else if run(repo, env, "bash", &["scripts/serve-https-spa.sh", "build"])? {
            run(repo, env, "bash", &["scripts/serve-https-spa.sh", "deploy"])?;
        }
    }
    Ok(())
}

fn main() -> Result<()> {
    let args = Args::parse();
    let repo = match &args.repo {
        Some(path) => path.canonicalize().context("--repo does not exist")?,
        None => find_repo(&std::env::current_dir()?)?,
    };
    let generated = generated_paths(&repo)?;
    let (env, env_path) = load_local_env(&repo, args.local_env.as_deref());
    let host_ip = std::env::var("SH_HOST_IP").ok().or_else(|| {
        env.iter()
            .find(|(k, _)| k == "SH_HOST_IP")
            .map(|(_, v)| v.clone())
    });
    // Fail loudly instead of falling back: without a real host every deploy
    // would ssh a documentation address, so deploys are OFF, not guessed.
    let deploys_enabled =
        matches!(&host_ip, Some(ip) if !ip.is_empty() && ip != PLACEHOLDER_HOST_IP);

    println!("devwatch: repo {}", repo.display());
    match (&env_path, deploys_enabled) {
        (Some(path), true) => println!("devwatch: deploys ON (local.env: {})", path.display()),
        (Some(path), false) => println!(
            "devwatch: deploys OFF — {} carries no real SH_HOST_IP",
            path.display()
        ),
        (None, true) => println!("devwatch: deploys ON (SH_HOST_IP from environment)"),
        (None, false) => {
            println!("devwatch: deploys OFF — no registry/local.env found (validate/generate only)")
        }
    }
    if args.dry_run {
        println!(
            "devwatch: --dry-run: validate/generate only, deploy commands are printed not run"
        );
    }

    let (tx, rx) = mpsc::channel();
    let mut debouncer = new_debouncer(Duration::from_millis(300), None, tx)?;
    for root in ["registry", "streamhost/tiles", "spa/src", "spa/public"] {
        debouncer
            .watch(repo.join(root), RecursiveMode::Recursive)
            .with_context(|| format!("watching {root}"))?;
    }
    println!("devwatch: watching registry/, streamhost/tiles/, spa/ — Ctrl-C to stop");

    let classify_batch = |dirty: &mut Dirty, batch: DebounceEventResult| match batch {
        Ok(events) => {
            for event in &events {
                // The pipeline's own `generate` READS every source file; acting
                // on Access events would make the watcher re-trigger itself.
                if mutates(event) {
                    dirty.merge(classify(&repo, &generated, &event.paths));
                }
            }
        }
        Err(errors) => {
            for error in errors {
                println!("devwatch: watch error: {error}");
            }
        }
    };

    loop {
        let mut dirty = Dirty::default();
        classify_batch(&mut dirty, rx.recv().context("watcher channel closed")?);
        while let Ok(more) = rx.try_recv() {
            classify_batch(&mut dirty, more);
        }
        if dirty.is_empty() {
            continue;
        }
        pipeline(&repo, &env, &generated, &dirty, &args, deploys_enabled)?;
    }
}

fn mutates(event: &DebouncedEvent) -> bool {
    matches!(
        event.kind,
        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
    )
}
