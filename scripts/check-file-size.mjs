#!/usr/bin/env node
// scripts/check-file-size.mjs — cross-language line-count budget checker.
//
// This repo's hygiene rule: strict on debt
// and file growth, pragmatic on style. Each source dialect gets a soft cap (a
// `~` warning, still passes) and a hard cap (fails under `--strict`, i.e. CI).
//
//   Dialect         scope                                              soft  hard
//   TS/JS source    spa/src/**  (*.ts/.tsx/.js/.jsx, not *.test.*)       400   600
//   TS/JS test      **/*.test.*, spa/scripts/**, tests/**               800  1200
//   Rust            streamhost/**/src/**/*.rs                            500   800
//   Python          scripts/**/*.py (host tooling; py2.6 guest          400   600
//                   agents excluded)
//   Bash            **/*.sh  +  scripts/labctl                          400   600
//
// Usage:
//   node scripts/check-file-size.mjs            # local: warnings only, exit 0
//   node scripts/check-file-size.mjs --strict   # CI: hard breaches / stale
//                                               #     exclusions fail (exit 1)
//   node scripts/check-file-size.mjs --strict --committed
//                                               # pre-push: tracked ∪ staged
//                                               #     only (see the note below)
//
// size-exclusions.json (repo root) is a BIDIRECTIONAL ledger: "path" -> "reason".
// An excluded file MUST still be over its hard cap. The moment it drops to/under
// the cap, its exclusion is STALE and the check fails — forcing you to delete the
// stale entry so the budget re-arms. An exclusion pointing at a file we never
// scan (generated / removed / renamed) is stale too.
//
// Generated artifacts (see generated() in scripts/tiles-registry.py) and vendored
// trees are never budgeted — they are not hand-authored source.
//
// WHICH FILES ARE SCANNED — it depends on the CONTEXT, and the difference is
// load-bearing:
//
//   default (pre-commit, direct invocation, CI)
//       tracked ∪ staged ∪ (untracked ∧ not-ignored)
//   --committed (the pre-push hook)
//       tracked ∪ staged  — the state actually being pushed
//
// A pre-push hook that budgets untracked files blocks you on a SIBLING's
// in-flight work, which you cannot fix, which trains SKIP_GATE=1, which is how
// a gate stops protecting anything. By push time your own new file is committed
// and therefore tracked, so --committed still catches the breach below.
//
// The default set, and why it is the default:
// Scanning only `git ls-files` made a NEW file always pass its own pre-commit
// check: on 2026-08-10 a 606-line bash script was gated green while untracked,
// committed, and turned `main` red the instant it became tracked. Same
// silent-success class as the `decos` bug. So the candidate set is
// `git ls-files --cached --others --exclude-standard`: `--cached` covers
// tracked AND staged-new files, `--others --exclude-standard` adds the
// untracked files that a `git add -A` would commit while honouring .gitignore,
// .git/info/exclude and the global excludes — so node_modules/, build output
// and scratch dirs stay invisible exactly as before. Consequence, and it is the
// intended one: an in-flight untracked file is budgeted before it is committed.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const CAPS = {
  "ts-src": { soft: 400, hard: 600, label: "TS/JS source" },
  "ts-test": { soft: 800, hard: 1200, label: "TS/JS test" },
  rust: { soft: 500, hard: 800, label: "Rust" },
  python: { soft: 400, hard: 600, label: "Python" },
  bash: { soft: 400, hard: 600, label: "Bash" },
};

// Generated files — kept in lockstep with generated() in scripts/tiles-registry.py.
// These are emitted from the typed registry + templates; never hand-authored.
const GENERATED = new Set([
  "spa/src/data/posterIndex.ts",
  "spa/src/data/demoPrograms.ts",
  "spa/src/data/keyboards.ts",
  "spa/src/three/archetypeRegistry.ts",
  "spa/src/mock/manifest.json",
  "registry/index.json",
  "scripts/serve/tiles.json",
  "scripts/serve/golden-manifest.json",
  "scripts/serve/webroot/gallery-manifest.json",
  "scripts/serve/webroot/poster-docs.json",
  "scripts/tools/gallery-action-map.json",
  "scripts/build-guests/build-all.sh",
  "streamhost/tiles-manifest.sh",
  "streamhost/bring-up-all.sh",
]);
const GENERATED_PREFIXES = ["registry/generated/"];

// Vendored / non-source trees, and the agent scaffolding under .claude/.
const IGNORED_DIR_RE =
  /(^|\/)(node_modules|target|dist|build|vendor|\.git|\.claude)\//;

// Guest-baked helpers are Python 2.6 in-guest agents — outside the host budget.
const PY2_ASSET_PREFIX = "scripts/build-guests/assets/";

function repoRoot() {
  return execFileSync("git", ["rev-parse", "--show-toplevel"], {
    encoding: "utf8",
  }).trim();
}

// See the header note: committedOnly => tracked ∪ staged (the pushed state);
// otherwise tracked ∪ staged ∪ (untracked ∧ not-ignored).
function candidateFiles(root, committedOnly) {
  const args = ["ls-files", "-z", "--cached"];
  if (!committedOnly) args.push("--others", "--exclude-standard");
  const out = execFileSync("git", args, {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 1 << 28,
  });
  return [...new Set(out.split("\0").filter(Boolean))];
}

// wc -l semantics: number of newline characters.
function lineCount(text) {
  let n = 0;
  for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10) n++;
  return n;
}

function isPython2(text) {
  const firstLine = text.slice(0, 256).split("\n", 1)[0];
  return /python2(?:\.\d+)?\b/.test(firstLine);
}

// Classify by path alone. Python candidates return "python"; the py2 shebang
// downgrade needs file content and is applied by the caller.
function classify(path) {
  if (GENERATED.has(path)) return null;
  if (GENERATED_PREFIXES.some((p) => path.startsWith(p))) return null;
  if (IGNORED_DIR_RE.test("/" + path)) return null;

  // Tests first: a *.test.ts under spa/src is a test, not source.
  if (/\.test\.(ts|tsx|js|jsx|mjs|cjs)$/.test(path)) return "ts-test";
  if (
    /\.(ts|tsx|js|jsx|mjs|cjs)$/.test(path) &&
    (path.startsWith("spa/scripts/") || path.startsWith("tests/"))
  )
    return "ts-test";

  if (path.startsWith("spa/src/") && /\.(ts|tsx|js|jsx)$/.test(path))
    return "ts-src";

  if (path.startsWith("streamhost/") && path.includes("/src/") && path.endsWith(".rs"))
    return "rust";

  if (path.startsWith("scripts/") && path.endsWith(".py")) {
    if (path.startsWith(PY2_ASSET_PREFIX)) return null; // guest-baked py2.6
    return "python";
  }

  if (path.endsWith(".sh") || path === "scripts/labctl") return "bash";

  return null;
}

function main() {
  const strict = process.argv.includes("--strict");
  const committedOnly = process.argv.includes("--committed");
  const root = repoRoot();

  let exclusions = {};
  const exclPath = join(root, "size-exclusions.json");
  if (existsSync(exclPath)) {
    try {
      exclusions = JSON.parse(readFileSync(exclPath, "utf8"));
    } catch (e) {
      console.error(`check-file-size: cannot parse size-exclusions.json: ${e.message}`);
      process.exit(2);
    }
  }

  const usedExclusions = new Set();
  const hardBreaches = [];
  const softWarns = [];
  const staleExcl = [];
  const suppressed = [];
  const perDialect = {};

  for (const path of candidateFiles(root, committedOnly)) {
    const dialect = classify(path);
    if (!dialect) continue;

    const abs = join(root, path);
    if (!existsSync(abs)) continue;
    const text = readFileSync(abs, "utf8");

    if (dialect === "python" && isPython2(text)) continue; // py2 in-guest agent

    const n = lineCount(text);
    const cap = CAPS[dialect];
    perDialect[dialect] = (perDialect[dialect] || 0) + 1;

    if (Object.prototype.hasOwnProperty.call(exclusions, path)) {
      usedExclusions.add(path);
      const reason = exclusions[path];
      if (n <= cap.hard) {
        staleExcl.push({ path, n, hard: cap.hard, reason, kind: "under-cap" });
      } else {
        suppressed.push({ path, n, hard: cap.hard, reason });
      }
      continue; // excluded files never emit soft warnings
    }

    if (n > cap.hard) hardBreaches.push({ path, n, cap });
    else if (n > cap.soft) softWarns.push({ path, n, cap });
  }

  // Exclusions that never matched a scanned file are stale (generated file,
  // removed/renamed path, or wrong dialect scope). Keys starting with "_" are
  // metadata (e.g. _README), not paths.
  for (const key of Object.keys(exclusions)) {
    if (key.startsWith("_")) continue;
    if (!usedExclusions.has(key)) {
      staleExcl.push({ path: key, reason: exclusions[key], kind: "not-scanned" });
    }
  }

  // ---- report ----
  const pad = (s, w) => String(s).padEnd(w);
  if (suppressed.length) {
    console.log("Excluded (over hard cap, tracked in size-exclusions.json):");
    for (const e of suppressed.sort((a, b) => b.n - a.n))
      console.log(`  excl  ${pad(e.path, 52)} ${e.n} (> hard ${e.hard})  — ${e.reason}`);
  }
  if (softWarns.length) {
    console.log("Soft-cap overruns (warning only):");
    for (const w of softWarns.sort((a, b) => b.n - a.n))
      console.log(`  ~     ${pad(w.path, 52)} ${w.n} (soft ${w.cap.soft}, hard ${w.cap.hard})`);
  }
  if (hardBreaches.length) {
    console.log("HARD-cap breaches (need a split or a size-exclusions.json entry):");
    for (const b of hardBreaches.sort((a, b) => b.n - a.n))
      console.log(`  HARD  ${pad(b.path, 52)} ${b.n} (> hard ${b.cap.hard})`);
  }
  if (staleExcl.length) {
    console.log("STALE exclusions (remove the entry from size-exclusions.json):");
    for (const s of staleExcl) {
      if (s.kind === "under-cap")
        console.log(`  STALE ${pad(s.path, 52)} ${s.n} now <= hard ${s.hard} — delete stale exclusion`);
      else
        console.log(`  STALE ${pad(s.path, 52)} not scanned (generated/removed/renamed) — delete stale exclusion`);
    }
  }

  const scanned = Object.values(perDialect).reduce((a, b) => a + b, 0);
  const byDialect = Object.entries(perDialect)
    .map(([d, c]) => `${d}:${c}`)
    .join(" ");
  console.log(
    `\nchecked ${scanned} source files (${byDialect}) — ` +
      `${suppressed.length} excluded, ${softWarns.length} soft, ` +
      `${hardBreaches.length} hard, ${staleExcl.length} stale.`,
  );

  const failed = hardBreaches.length > 0 || staleExcl.length > 0;
  if (failed && strict) {
    console.log("check-file-size: FAIL (--strict)");
    process.exit(1);
  }
  if (failed) {
    console.log("check-file-size: warnings only (pass --strict to enforce)");
  } else {
    console.log("check-file-size: OK");
  }
  process.exit(0);
}

main();
