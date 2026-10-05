#!/usr/bin/env node
// beacon-probe — drive ONE real page load and check what the tab's own trace
// plane put on the wire against this box's own trace store, and report WHICH
// BUNDLE the page said it was.
//
// WHY THIS EXISTS. Three properties of the trace plane can only be seen on the
// wire, never from inside a unit test: the `<meta name="traceparent">` the
// server injects into the page it serves (scripts/serve/static_files.py), the
// `traceresponse` header on that response, and the no-orphan invariant
// (docs/lab/TRACE-CONTEXT.md §8) — every outbound `traceparent` names a span
// the store actually received, and no telemetry path carries one at all.
//
// It is a DIAGNOSTIC, not a gate: it drives one real page load and prints what
// it saw. Nothing in CI runs it (it needs a credentialed session and the live
// gallery); run it by hand after any change to the traceparent meta, the
// response trace headers, or analytics/khFetch.ts.
//
// THE BUNDLE ID IS PART OF THE CAPTURE, for the reason docs/ANALYTICS.md §8.3
// gives: on 2026-09-01 a phone produced a full record on our own plane and
// "which bundle was that client running?" had no answer. The `/traces`
// resource envelope carries it now (spa/src/analytics/build.ts), and this probe
// says whether it is there.
//
// Usage:
//   cd scripts/visitor-sim && node beacon-probe.mjs [--url https://host] [--path /]
//   node beacon-probe.mjs --json out.json      # also write the raw capture
//
// Requires the same install as visitor-sim (`npm install` in this directory,
// `npx playwright install chromium`) and a credentialed session — see
// docs/lab/VISITOR-SIM.md. The gallery answers 401 to an anonymous `/`, so a
// probe without a session captures the login page, not the SPA.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_STATE = path.join(HERE, 'visitor-sim-runs', 'invite-session.json');
const DEFAULT_URL = 'https://kernelhive.madekivi.fi';
// Bind-mounted into CT950, so a probe running beside the gallery can answer
// "does this trace exist?" itself instead of printing a query for a human to run.
const DEFAULT_TRACES_DB = '/data/vms/streamhost/serve/traces.db';

function usage() {
  console.log(`beacon-probe — check the trace plane on the wire for one real page load

  --url <origin>          gallery origin              (default ${DEFAULT_URL})
  --path <path>           path to load                (default /)
  --storage-state <file>  Playwright storageState     (default visitor-sim-runs/invite-session.json)
  --settle <ms>           how long to stay on the page (default 15000; spans
                          are buffered and uploaded on the sink's own cadence)
  --traces-db <file>      trace store to resolve ids against
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
    // BOOLEAN FLAGS MUST BE LISTED HERE. Anything absent is treated as
    // taking a value, so it silently swallows the NEXT argument.
    if (['help', 'insecure'].includes(key)) args.set(key, true);
    else {
      i += 1;
      args.set(key, argv[i]);
    }
  }
  return args;
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

//: Paths this app deliberately opens no client span for — kept in step with
//: spa/src/analytics/telemetryPaths.ts's KH_TELEMETRY_PATHS. No span means no
//: span for a header to name, so an outbound `traceparent` on one of these is
//: by definition an id nothing will record.
const TELEMETRY_PATHS = ['/traces', '/logs', '/vitals', '/analytics', '/coverage', '/clientlog', '/usage', '/clientcmd'];

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

  // The plane's own uploads. Same page load, same tab: the resource envelope of
  // a /traces batch is where this app writes the build id it is running.
  const ownResources = [];
  page.on('request', (req) => {
    try {
      const url = new URL(req.url());
      if (url.origin !== origin || url.pathname !== '/traces' || req.method() !== 'POST') return;
      const body = req.postData();
      if (!body) return;
      const parsed = JSON.parse(body);
      if (parsed && parsed.resource) ownResources.push(parsed.resource);
    } catch {
      /* a probe must never fail on a body it cannot parse */
    }
  });
  // The OUTBOUND leg. analytics/khFetch.ts is the only writer of this header;
  // a comma means a second writer appended to it, which no parser accepts.
  const outbound = [];
  page.on('request', (req) => {
    try {
      const tp = req.headers()['traceparent'];
      if (tp && new URL(req.url()).origin === origin) outbound.push({ url: req.url(), traceparent: tp });
    } catch {
      /* header inspection is diagnostic only */
    }
  });
  const response = await page.goto(target, { waitUntil: 'load', timeout: 60000 });
  const headers = response ? response.headers() : {};
  const meta = await page.evaluate(() => {
    const el = document.querySelector('meta[name="traceparent"]');
    return el ? el.getAttribute('content') : null;
  });
  // The tab's session id (`session.id` on its spans) — what to search
  // /admin/observability for. Minted per document, so read from the live page.
  const sessionId = await page.evaluate(() => window.__kernelHiveErrorSessionId ?? null);
  // Spans are buffered and uploaded on the sink's own cadence, so a probe that
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
    sessionId,
    ownResources,
  };

  console.log(`page              ${target}`);
  console.log(`meta traceparent  ${meta ?? '(none)'}`);
  console.log(`traceresponse     ${report.traceresponse ?? '(none)'}`);
  if (injected) {
    console.log(`  trace id (32)   ${injected.traceId}`);
    console.log(`  span id  (16)   ${injected.spanId}`);
  }
  // WHICH BUNDLE. `unknown-build` is an honest answer (a build with no git); a
  // MISSING one means the resource envelope is not carrying it, which is the
  // regression this line exists to catch.
  const ownBuilds = [...new Set(ownResources.map((r) => r['kh.bundle']).filter(Boolean))];
  console.log(`\nbundle (our /traces)   ${ownBuilds.join(', ') || (ownResources.length ? 'MISSING from the resource envelope' : '(no /traces upload seen)')}`);
  console.log(`session id        ${sessionId ?? '(none)'}`);

  let failures = 0;
  if (ownResources.length && !ownBuilds.length) {
    console.log('  FAULT: /traces uploads carry no kh.bundle');
    failures += 1;
  }

  const store = await openTraceStore(tracesDb);
  if (!store) console.log(`  trace store     UNCHECKED (${tracesDb || 'disabled'})`);

  // ---- the page load itself ------------------------------------------------
  // static_files.py records a real `serve.page` span for the document it
  // served and names it in the meta tag. If the store does not hold it, every
  // span link this tab draws to its page load points at nothing.
  console.log('\npage-load trace');
  if (!injected) {
    console.log('  FAULT: no well-formed <meta name="traceparent"> on the served page');
    failures += 1;
  } else if (!store) {
    console.log('  UNCHECKED (no trace store)');
  } else {
    const spans = store.trace(injected.traceId);
    if (spans === null) {
      console.log('  UNCHECKED (query failed)');
    } else if (spans.length) {
      console.log(`  RESOLVES (${spans.length} span(s)): ${spans.map((r) => r.name).join(', ')}`);
    } else {
      console.log(`  FAULT: trace ${injected.traceId} is not in the store`);
      failures += 1;
    }
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
    console.log(`\nFAIL: ${failures} fault(s) — see the FAULT lines above.`);
    process.exitCode = 1;
  } else if (store) {
    console.log('\nOK: the page load resolves, and every outbound parent id names a stored span.');
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
