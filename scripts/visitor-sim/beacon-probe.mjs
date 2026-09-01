#!/usr/bin/env node
// beacon-probe — capture the Instana EUM beacons a REAL page load produces,
// and check each one's backendTraceId against this box's own trace store.
//
// WHY THIS EXISTS. "Does a page load correlate to a backend trace?" is not a
// question any document can answer. Instana's own docs contradict themselves
// on the precedence (docs/lab/INSTANA-VIEW-INVENTORY.md §7), and the answer
// depends on the pinned agent build, on our `<meta name="traceparent">`
// injection (scripts/serve/static_files.py), and on the `Server-Timing: intid`
// header (scripts/serve/tracing_http.py) all at once. The only authority is a
// beacon on the wire. This tool captures one.
//
// It is a DIAGNOSTIC, not a gate: it drives one real page load and prints what
// it saw. Nothing in CI runs it (it needs a credentialed session and the live
// gallery); run it by hand after any change to the traceparent meta, the
// Server-Timing header, or the `ineum(...)` bootstrap in spa/index.html.
//
// See docs/lab/INSTANA-VIEW-INVENTORY.md §7 for the mechanism it verifies and
// the measured agent behaviour behind it.
//
// Usage:
//   cd scripts/visitor-sim && node beacon-probe.mjs [--url https://host] [--path /]
//   node beacon-probe.mjs --json out.json      # also write the raw capture
//
// Requires the same install as visitor-sim (`npm install` in this directory,
// `npx playwright install chromium`) and a credentialed session — see
// docs/lab/VISITOR-SIM.md. The gallery answers 401 to an anonymous `/`, so a
// probe without a session captures a beacon for the login page, not the SPA.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_STATE = path.join(HERE, 'visitor-sim-runs', 'invite-session.json');
const DEFAULT_URL = 'https://kernelhive.madekivi.fi';
// The beacon endpoint is always on the vendor's own domain, whatever tenant
// path registry/local.env points at — so match the domain, never a full URL
// (which is tenant-specific and must not be committed).
const REPORTING_HOST_RE = /(^|\.)instana\.io$/i;
// Bind-mounted into CT950, so a probe running beside the gallery can answer
// "does this bt exist?" itself instead of printing a query for a human to run.
const DEFAULT_TRACES_DB = '/data/vms/streamhost/serve/traces.db';

function usage() {
  console.log(`beacon-probe — capture Instana EUM beacons from one real page load

  --url <origin>          gallery origin              (default ${DEFAULT_URL})
  --path <path>           path to load                (default /)
  --storage-state <file>  Playwright storageState     (default visitor-sim-runs/invite-session.json)
  --settle <ms>           how long to stay on the page (default 15000; the
                          page-load beacon is held ~5 s by the agent itself)
  --traces-db <file>      trace store to resolve each bt against
                          (default ${DEFAULT_TRACES_DB}; '' to skip)
  --json <file>           write the raw capture as JSON
  --insecure              accept the lab's self-signed cert (internal origins)
  --help
`);
}

function parseArgs(argv) {
  const args = new Map();
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    if (key === 'help' || key === 'insecure') args.set(key, true);
    else {
      i += 1;
      args.set(key, argv[i]);
    }
  }
  return args;
}

/** Split one beacon POST body into records.
 *
 *  The wire format is the agent's own `Hb()`: records separated by a BLANK
 *  line, fields within a record one per line as `key<TAB>value`, with `\`,
 *  newline and tab escaped in both halves. Decoding the escapes matters —
 *  a JS error's stack arrives as one field with escaped newlines in it. */
export function parseBeacons(body) {
  const unescape = (s) => s.replace(/\\(.)/g, (_, c) => (c === 'n' ? '\n' : c === 't' ? '\t' : c));
  return body
    .split('\n\n')
    .map((record) => {
      const fields = {};
      for (const line of record.split('\n')) {
        if (!line) continue;
        const tab = line.indexOf('\t');
        if (tab < 0) continue;
        fields[unescape(line.slice(0, tab))] = unescape(line.slice(tab + 1));
      }
      return fields;
    })
    .filter((r) => Object.keys(r).length > 0);
}

/** The `00-<32hex>-<16hex>-<2hex>` parts of a traceparent, or null. */
export function parseTraceparent(value) {
  if (typeof value !== 'string') return null;
  const p = value.split('-');
  if (p.length !== 4 || p[0] !== '00' || p[1].length !== 32 || p[2].length !== 16) return null;
  return { traceId: p[1], spanId: p[2], flags: p[3] };
}

/** Open the trace store read-only and return `(traceId) => spans[] | null`.
 *
 *  Returns a resolver that always answers `null` when the store is not
 *  reachable — a laptop, a public clone, a node without `node:sqlite`. Not
 *  being able to check is a REPORTED absence, never a silent pass: the caller
 *  prints "unchecked" and does not claim the beacon resolved. */
async function openTraceStore(file) {
  if (!file || !fs.existsSync(file)) return null;
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import('node:sqlite'));
  } catch {
    return null;
  }
  let db;
  try {
    db = new DatabaseSync(file, { readOnly: true });
  } catch {
    return null;
  }
  const byTrace = db.prepare('SELECT span_id, name, kind FROM span WHERE trace_id = ?');
  const bySpan = db.prepare('SELECT trace_id, name, kind FROM span WHERE span_id = ?');
  return {
    trace: (traceId) => {
      try {
        return byTrace.all(traceId);
      } catch {
        return null;
      }
    },
    // The no-orphan invariant's acceptance query (docs/lab/TRACE-CONTEXT.md
    // §8): whatever this tab put in an outbound `traceparent` has to be a
    // span the store actually holds. Before 2026-09-01 it routinely was not.
    span: (spanId) => {
      try {
        return bySpan.all(spanId);
      } catch {
        return null;
      }
    },
  };
}

//: Paths this app deliberately opens no client span for — the one list, kept
//: in step with spa/src/analytics/instana.ts's KH_TELEMETRY_PATHS. No span
//: means no span for a header to name, so an outbound `traceparent` on one of
//: these is by definition an id nothing will record.
const TELEMETRY_PATHS = ['/traces', '/analytics', '/coverage', '/clientlog', '/usage', '/clientcmd'];

function isTelemetryPath(url) {
  try {
    const { pathname } = new URL(url);
    return TELEMETRY_PATHS.some((p) => pathname === p || pathname.startsWith(`${p}/`) || pathname.startsWith(`${p}?`));
  } catch {
    return false;
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.has('help')) return usage();

  const origin = String(args.get('url') ?? DEFAULT_URL).replace(/\/+$/, '');
  const target = origin + String(args.get('path') ?? '/');
  const statePath = String(args.get('storage-state') ?? DEFAULT_STATE);
  const settle = Number(args.get('settle') ?? 15000);
  const tracesDb = args.has('traces-db') ? String(args.get('traces-db')) : DEFAULT_TRACES_DB;

  if (!fs.existsSync(statePath)) {
    console.error(`beacon-probe: no storageState at ${statePath}`);
    console.error('  The gallery answers 401 to an anonymous "/" — a probe without a');
    console.error('  session captures the login page, not the SPA. Create one with:');
    console.error('    node visitor-sim.mjs --stations win311 --visitors 1 --duration 1m --invite <url>');
    process.exitCode = 2;
    return;
  }

  const browser = await chromium.launch();
  const context = await browser.newContext({
    storageState: statePath,
    ignoreHTTPSErrors: Boolean(args.get('insecure')),
  });
  const page = await context.newPage();

  const beacons = [];
  // The OUTBOUND leg, watched for the collision analytics/khFetch.ts documents:
  // Instana's agent APPENDS its own traceparent when enableW3CHeaders is on, so
  // depending on monkey-patch order our header can arrive as two comma-joined
  // values that no parser accepts. One comma here is the whole tell.
  const outbound = [];
  page.on('request', (req) => {
    try {
      const tp = req.headers()['traceparent'];
      if (tp && new URL(req.url()).origin === origin) outbound.push({ url: req.url(), traceparent: tp });
    } catch {
      /* header inspection is diagnostic only */
    }
  });
  page.on('request', (req) => {
    let host;
    try {
      host = new URL(req.url()).hostname;
    } catch {
      return;
    }
    if (!REPORTING_HOST_RE.test(host)) return;
    const body = req.postData();
    if (!body) return;
    for (const record of parseBeacons(body)) beacons.push(record);
  });

  const response = await page.goto(target, { waitUntil: 'load', timeout: 60000 });
  const headers = response ? response.headers() : {};
  const meta = await page.evaluate(() => {
    const el = document.querySelector('meta[name="traceparent"]');
    return el ? el.getAttribute('content') : null;
  });
  // The agent holds the page-load beacon ~5 s (its own `f.Ea`) while the tab is
  // visible, and batches xhr beacons behind a short timer, so a probe that
  // leaves immediately captures nothing. Waiting is the whole method.
  await page.waitForTimeout(settle);
  await context.close();
  await browser.close();

  const injected = parseTraceparent(meta);
  const report = {
    url: target,
    metaTraceparent: meta,
    injected,
    traceresponse: headers.traceresponse ?? null,
    outbound,
    serverTiming: headers['server-timing'] ?? null,
    beacons,
  };

  console.log(`page              ${target}`);
  console.log(`meta traceparent  ${meta ?? '(none)'}`);
  console.log(`traceresponse     ${report.traceresponse ?? '(none)'}`);
  console.log(`Server-Timing     ${report.serverTiming ?? '(none)'}`);
  if (injected) {
    console.log(`  trace id (32)   ${injected.traceId}`);
    console.log(`  span id  (16)   ${injected.spanId}`);
  }
  console.log(`\nbeacons captured  ${beacons.length}`);
  const counts = {};
  for (const b of beacons) counts[b.ty ?? '?'] = (counts[b.ty ?? '?'] ?? 0) + 1;
  console.log(`  by type         ${JSON.stringify(counts)}`);

  const store = await openTraceStore(tracesDb);
  const resolve = store ? store.trace : null;
  if (!store) console.log(`  trace store     UNCHECKED (${tracesDb || 'disabled'})`);

  const shape = (bt) => {
    if (!injected) return '(no meta traceparent to compare against)';
    if (bt === injected.traceId) return 'the meta TRACE id';
    if (bt === injected.spanId) return 'the meta SPAN id — 16 hex, can never resolve';
    return 'an independent id';
  };

  let failures = 0;
  for (const b of beacons) {
    if (b.ty !== 'pl' && b.ty !== 'xhr' && b.ty !== 'cus' && b.ty !== 'err') continue;
    const where = b.u ? ` ${b.u}` : '';
    console.log(`  ${String(b.ty).padEnd(4)} t=${b.t ?? '-'} s=${b.s ?? '-'}${where}`);
    if (!b.bt) {
      // Legitimate for a route the tracing allowlist leaves out (a rendered
      // JSON document, a static asset): no server span, so no Server-Timing,
      // so nothing to correlate. Only a page-load with no bt is a fault.
      console.log(`       no bt${b.ty === 'pl' ? '   <-- FAULT: the page load correlates to nothing' : ''}`);
      if (b.ty === 'pl') failures += 1;
      continue;
    }
    const spans = resolve ? resolve(b.bt) : null;
    const verdict =
      spans === null ? 'unchecked' : spans.length ? `RESOLVES (${spans.length} span(s))` : 'DOES NOT RESOLVE';
    console.log(`       bt=${b.bt}  ${shape(b.bt)}`);
    console.log(`       ${verdict}${spans && spans.length ? ': ' + spans.map((r) => r.name).join(', ') : ''}`);
    if (spans !== null && spans.length === 0) failures += 1;
  }

  const corrupted = outbound.filter((o) => o.traceparent.includes(','));
  console.log(`\noutbound traceparent headers  ${outbound.length} (same-origin)`);
  if (corrupted.length) {
    console.log(`  ${corrupted.length} COMMA-JOINED — a second writer is appending:`);
    for (const o of corrupted) console.log(`    ${o.traceparent}  ${o.url}`);
    failures += corrupted.length;
  } else if (outbound.length) {
    console.log('  all single-valued — this app owns the header');
  }

  // ---- the no-orphan invariant, on the real wire --------------------------
  // Two questions, and neither can be answered from inside the tab: does a
  // telemetry path still carry a header it has no span for, and does every
  // header this page DID send name a span the store actually received?
  // Measured 2026-09-01, before the fix: 42.9% of the spans in a six-hour
  // window declared a parent that had never been stored.
  const onTelemetry = outbound.filter((o) => isTelemetryPath(o.url));
  console.log(`\nno-orphan invariant (TRACE-CONTEXT.md §8)`);
  if (onTelemetry.length) {
    console.log(`  FAULT: ${onTelemetry.length} traceparent(s) on an excluded telemetry path:`);
    for (const o of onTelemetry) console.log(`    ${o.url}  ${o.traceparent}`);
    failures += onTelemetry.length;
  } else {
    console.log('  no traceparent on any excluded telemetry path');
  }
  if (!store) {
    console.log('  parents        UNCHECKED (no trace store)');
  } else {
    // A span is buffered when it ENDS and uploaded on the next flush, so give
    // the tab's own eager root-end flush time to land before asking.
    const dangling = [];
    for (const o of outbound) {
      const parsed = parseTraceparent(o.traceparent.split(',')[0].trim());
      if (!parsed) continue;
      const rows = store.span(parsed.spanId);
      if (rows && rows.length === 0) dangling.push({ ...o, spanId: parsed.spanId });
    }
    if (dangling.length) {
      console.log(`  FAULT: ${dangling.length} traceparent(s) name a span the store never received:`);
      for (const o of dangling) console.log(`    ${o.spanId}  ${o.url}`);
      failures += dangling.length;
    } else {
      console.log(`  every outbound parent id resolves in the store (${outbound.length} checked)`);
    }
  }

  if (failures > 0) {
    console.log(`\nFAIL: ${failures} beacon(s) carry a backendTraceId that resolves to no trace.`);
    process.exitCode = 1;
  } else if (resolve) {
    console.log('\nOK: every beacon that carries a backendTraceId resolves in the store.');
  }

  const out = args.get('json');
  if (out) {
    fs.writeFileSync(String(out), JSON.stringify(report, null, 2));
    console.log(`\nraw capture -> ${out}`);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
}
