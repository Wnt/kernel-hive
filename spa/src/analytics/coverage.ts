// ============================================================================
//  analytics/coverage — which LINES of the shipped bundle ever ran.
//  ---------------------------------------------------------------------------
//  THIS MODULE IS NOT IN THE GALLERY. It reaches a bundle only when
//  vite-plugins/coverage.ts injects it, which happens only when
//  VITE_KH_COVERAGE is armed with its exact string. The default bundle is
//  byte-identical without it.
//
//  It follows sink.ts's three rules, and departs from it in one place on
//  purpose:
//
//  1. NEVER THROW. Every entry point is wrapped. A gallery that loads beats a
//     gallery that measures.
//  2. A NETWORK failure keeps the evidence, an HTTP REFUSAL settles it. The
//     refusal case matters MORE here than in sink.ts: a signed-out tab at the
//     walk-in door 401s, and this payload is a hundred times a counter batch.
//     One refusal disarms the reporter for the life of the tab.
//  3. THE LAST MOMENT IS THE ONLY MOMENT. Coverage is monotonic — a line that
//     ran stays run — so unlike counters there is nothing to gain by sending
//     early and everything to lose (n requests of the same shape, each a
//     superset of the last). One send, at `pagehide`, plus `visibilitychange`
//     to hidden because iOS Safari can skip pagehide, with `keepalive`.
//
//  SETS, NOT COUNTS — the size decision. `window.__coverage__` is a per-
//  statement HIT COUNT map plus a full statementMap of source positions; as
//  JSON it is on the order of a megabyte for this SPA, which is not a thing to
//  put on the wire at pagehide and not a thing to store per session. The
//  question is "did this line run", so the counts are thrown away in the tab
//  and what travels is two LINE SETS per file — the instrumented lines and the
//  executed subset — run-length encoded. That is a ~99% reduction, it is
//  losslessly mergeable across sessions by union, and it removes the one part
//  of the payload that was starting to look like a behavioural trace: how many
//  times each branch of the app ran tells you what somebody DID, and a durable
//  aggregate has no business knowing that.
// ============================================================================

import { clientClass } from './intent';
import { postTelemetry } from './beacon';

/** Istanbul's per-file shape, narrowed to the two fields this reads. */
interface FileCoverage {
  statementMap?: Record<string, { start?: { line?: number } }>;
  s?: Record<string, number>;
}

/** One file's two line sets, run-length encoded. */
export interface CoverageFileRow { f: string; a: string; h: string }

/** Attempts allowed in one tab. A page restored from bfcache fires pagehide
 *  again; without a ceiling a flapping network would retry on every one. */
const MAX_ATTEMPTS = 3;

let build = '';
let installed = false;
let attempts = 0;
let refused = false;

/**
 * Arm the reporter for one instrumented build. Called from the top of
 * main.tsx by the coverage plugin, and by nothing else — there is no runtime
 * flag, because a runtime flag would mean shipping this module in the gallery.
 */
export function installCoverageReporter(buildId: string): void {
  try {
    build = buildId;
    if (installed || typeof window === 'undefined') return;
    installed = true;
    window.addEventListener('pagehide', () => send(true));
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') send(true);
    });
  } catch { /* no lifecycle hooks: nothing is reported, and nothing breaks */ }
}

function send(final = false): void {
  try {
    if (refused || attempts >= MAX_ATTEMPTS) return;
    const files = collect();
    if (!files.length) return;
    attempts += 1;
    const body = JSON.stringify({ build, class: clientClass(), files });
    // A settled NO — no session, body too large, plane disabled — is an
    // answer, not a hiccup. Stop asking for the life of the tab. A network
    // failure is not an answer: leave `refused` alone so a later hidden/
    // pagehide gets one more go, bounded by MAX_ATTEMPTS. `keepalive` only on
    // the final flush — `analytics/beacon.ts`.
    void postTelemetry('/coverage', body, { final }).then((result) => {
      if (result === 'refused') refused = true;
    });
  } catch { /* instrumentation never throws into the app */ }
}

/** Reduce `window.__coverage__` to two run-length line sets per file. */
export function collect(): CoverageFileRow[] {
  const raw = (globalThis as { __coverage__?: Record<string, FileCoverage> }).__coverage__;
  if (!raw) return [];
  const out: CoverageFileRow[] = [];
  for (const key of Object.keys(raw).sort()) {
    const entry = raw[key];
    const map = entry?.statementMap;
    if (!map) continue;
    const counts = entry.s ?? {};
    const all = new Set<number>();
    const hit = new Set<number>();
    for (const idx of Object.keys(map)) {
      const line = map[idx]?.start?.line;
      if (typeof line !== 'number' || line <= 0) continue;
      all.add(line);
      if (counts[idx]) hit.add(line);
    }
    if (!all.size) continue;
    out.push({ f: relative(key), a: encodeLines(all), h: encodeLines(hit) });
  }
  return out;
}

/** The build machine's absolute path is neither useful nor ours to publish;
 *  everything downstream keys on the spa-relative path the repo uses. */
function relative(key: string): string {
  const norm = key.replace(/\\/g, '/');
  const at = norm.lastIndexOf('/spa/');
  return at === -1 ? norm.replace(/^\/+/, '') : norm.slice(at + '/spa/'.length);
}

/**
 * A sorted line set as alternating GAP and RUN lengths in base 36, dot
 * separated: `1c.3.2.1` is "skip 48, then 3 lines, skip 2, then 1 line".
 * Source lines cluster hard — whole functions run or do not — so runs are long
 * and this is several times smaller than a list of numbers, while staying a
 * plain string that SQLite stores and Python re-reads without a codec.
 */
export function encodeLines(lines: Set<number>): string {
  const sorted = [...lines].sort((a, b) => a - b);
  const parts: string[] = [];
  let prev = 0;
  let i = 0;
  while (i < sorted.length) {
    const start = sorted[i];
    let run = 1;
    while (i + run < sorted.length && sorted[i + run] === start + run) run += 1;
    parts.push((start - prev).toString(36), run.toString(36));
    prev = start + run - 1;
    i += run;
  }
  return parts.join('.');
}
