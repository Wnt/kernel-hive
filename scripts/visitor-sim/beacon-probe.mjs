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
// SINCE THE BEACON PROXY (scripts/serve/eum_proxy.py) it also answers the
// question that change created: are beacons actually FIRST-PARTY now, are
// they accepted, and do they still reach Instana? Those are three separate
// facts and it checks all three, because two of them can be true while the
// third quietly is not:
//
//   1. WHERE they go. Every beacon must be POSTed to this origin's /eum, and
//      NONE may go straight to an instana.io host. A direct beacon means the
//      served bundle predates the proxy — the exact "a push is not a deploy"
//      mistake — and it must fail loudly rather than look like success,
//      because a stale bundle keeps working perfectly for everyone whose DNS
//      is not filtered and vanishes for everyone whose is.
//   2. WHETHER WE ACCEPTED them. A 401/403/404/415 on /eum is the failure
//      mode this whole route has to be watched for: the fence is the same one
//      that once 401'd /vendor/ and silently deleted all browser telemetry.
//   3. WHETHER INSTANA GOT them. Ours accepting a beacon proves nothing about
//      the vendor — the forward happens on a background worker AFTER we have
//      already answered 200. So `--instana-check` queries the tenant's own
//      beacons API for this page load's `kh.sessionId`. That is the only
//      end-to-end proof; everything before it is proof of a prefix.
//
// See docs/lab/INSTANA-VIEW-INVENTORY.md §7 for the mechanism it verifies and
// the measured agent behaviour behind it.
//
// Usage:
//   cd scripts/visitor-sim && node beacon-probe.mjs [--url https://host] [--path /]
//   node beacon-probe.mjs --json out.json      # also write the raw capture
//   node beacon-probe.mjs --instana-check      # + prove it reached the tenant
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
// The FIRST-PARTY beacon path (scripts/serve/eum_proxy.py PATH). Beacons post
// here now; anything still going to REPORTING_HOST_RE above is a stale bundle.
const FIRST_PARTY_BEACON_PATH = '/eum';
// Where the tenant's API base and token live. Both are unpublishable, so they
// are read from the gitignored env file at run time and never defaulted to a
// literal — the same rule the rest of this repo follows for addresses.
const LOCAL_ENV = path.join(HERE, '..', '..', 'registry', 'local.env');
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
  --instana-check         after the load, poll the tenant's beacons API until
                          this page load's kh.sessionId appears (end-to-end
                          proof the proxy delivered); needs INSTANA_API_BASE +
                          INSTANA_API_TOKEN_FILE in registry/local.env
  --instana-wait <ms>     how long to poll for it            (default 180000)
  --allow-direct          do NOT fail on beacons sent straight to instana.io.
                          Only for measuring a pre-proxy bundle on purpose
  --json <file>           write the raw capture as JSON
  --insecure              accept the lab's self-signed cert (internal origins)
  --help
`);
}

/** `KEY=value` lines from registry/local.env, or {} when it is not there.
 *  A public clone has no such file and must still be able to run the probe. */
function readLocalEnv() {
  const env = {};
  let text;
  try {
    text = fs.readFileSync(LOCAL_ENV, 'utf8');
  } catch {
    return env;
  }
  for (const line of text.split('\n')) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)$/.exec(line);
    if (m) env[m[1]] = m[2].trim().replace(/^["']|["']$/g, '');
  }
  return env;
}

/** Poll the tenant for a PAGELOAD beacon carrying `sessionId` as kh.sessionId.
 *
 *  Returns `{checked: false, why}` when the credentials are not present —
 *  never a silent pass. A beacon is not queryable the instant it is accepted
 *  (our own worker forwards it asynchronously, and Instana's ingest is not
 *  instantaneous either), so this polls rather than asking once. */
async function instanaSawSession(sessionId, waitMs) {
  const env = readLocalEnv();
  const base = (env.INSTANA_API_BASE || '').replace(/\/+$/, '');
  const tokenFile = env.INSTANA_API_TOKEN_FILE || '';
  if (!base || !tokenFile) {
    return { checked: false, why: 'INSTANA_API_BASE / INSTANA_API_TOKEN_FILE not in registry/local.env' };
  }
  const abs = path.isAbsolute(tokenFile) ? tokenFile : path.join(HERE, '..', '..', tokenFile);
  let token;
  try {
    token = fs.readFileSync(abs, 'utf8').trim();
  } catch {
    return { checked: false, why: `token file unreadable (${tokenFile})` };
  }
  const deadline = Date.now() + waitMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${base}/api/website-monitoring/analyze/beacons`, {
        method: 'POST',
        headers: { authorization: `apiToken ${token}`, 'content-type': 'application/json' },
        // A short window and a generous page: this is looking for ONE beacon
        // minted seconds ago, not building a report.
        body: JSON.stringify({
          timeFrame: { windowSize: 30 * 60 * 1000, to: Date.now() },
          type: 'PAGELOAD',
          pagination: { retrievalSize: 200 },
        }),
      });
      if (!res.ok) {
        lastError = `HTTP ${res.status}`;
      } else {
        const doc = await res.json();
        const items = Array.isArray(doc.items) ? doc.items : [];
        const hit = items.find((it) => (it?.meta ?? {})['kh.sessionId'] === sessionId);
        if (hit) return { checked: true, found: true, beacon: hit, sampled: items.length };
        lastError = `not among ${items.length} PAGELOAD beacon(s) yet`;
      }
    } catch (err) {
      lastError = String(err && err.message ? err.message : err);
    }
    await new Promise((r) => setTimeout(r, 15000));
  }
  return { checked: true, found: false, why: lastError };
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
  const stmt = db.prepare('SELECT span_id, name, kind FROM span WHERE trace_id = ?');
  return (traceId) => {
    try {
      return stmt.all(traceId);
    } catch {
      return null;
    }
  };
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
  // WHERE each beacon went, kept apart rather than merged: the whole point of
  // the proxy is that one of these two lists is empty.
  const transports = { firstParty: 0, direct: 0 };
  const beaconRequests = [];
  page.on('request', (req) => {
    let url;
    try {
      url = new URL(req.url());
    } catch {
      return;
    }
    const direct = REPORTING_HOST_RE.test(url.hostname);
    const firstParty = url.origin === origin && url.pathname === FIRST_PARTY_BEACON_PATH;
    if (!direct && !firstParty) return;
    const body = req.postData();
    if (!body) return;
    transports[direct ? 'direct' : 'firstParty'] += 1;
    beaconRequests.push({ url: req.url(), method: req.method(), direct, status: null });
    for (const record of parseBeacons(body)) beacons.push(record);
  });
  // …and whether WE accepted it. A 401/403/404/415 here is the failure this
  // route has to be watched for; it looks identical to "no telemetry" from
  // every other vantage point, which is how /vendor/'s 401 survived so long.
  page.on('response', (res) => {
    const hit = beaconRequests.find((b) => b.url === res.url() && b.status === null);
    if (hit) hit.status = res.status();
  });

  const response = await page.goto(target, { waitUntil: 'load', timeout: 60000 });
  const headers = response ? response.headers() : {};
  const meta = await page.evaluate(() => {
    const el = document.querySelector('meta[name="traceparent"]');
    return el ? el.getAttribute('content') : null;
  });
  // The join key index.html's bootstrap stamps on every beacon as
  // `kh.sessionId`. It is what `--instana-check` looks this page load up by,
  // and it has to be read from the live page — it is minted per document.
  const sessionId = await page.evaluate(() => window.__kernelHiveErrorSessionId ?? null);
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
    sessionId,
    transports,
    beaconRequests,
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
  console.log(`kh.sessionId      ${sessionId ?? '(none)'}`);

  console.log(`\nbeacons captured  ${beacons.length}`);
  const counts = {};
  for (const b of beacons) counts[b.ty ?? '?'] = (counts[b.ty ?? '?'] ?? 0) + 1;
  console.log(`  by type         ${JSON.stringify(counts)}`);

  const resolve = await openTraceStore(tracesDb);
  if (!resolve) console.log(`  trace store     UNCHECKED (${tracesDb || 'disabled'})`);

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

  // ---- the beacon TRANSPORT ------------------------------------------------
  console.log(`\nbeacon transport  ${transports.firstParty} first-party (${FIRST_PARTY_BEACON_PATH}), `
    + `${transports.direct} direct to the vendor`);
  for (const b of beaconRequests) {
    const verdict = b.status === null ? 'NO RESPONSE SEEN' : b.status;
    console.log(`  ${b.direct ? 'DIRECT ' : 'ours   '} ${b.method} ${b.url}  -> ${verdict}`);
  }
  if (transports.firstParty + transports.direct === 0) {
    console.log('  FAULT: no beacon request at all — the agent never loaded, or the build is keyless');
    failures += 1;
  }
  if (transports.direct > 0 && !args.has('allow-direct')) {
    // A stale bundle. It works for everyone whose DNS is unfiltered and
    // silently loses everyone whose is not, which is the whole reason the
    // proxy exists — so it fails here rather than reading as a pass.
    console.log(`  FAULT: ${transports.direct} beacon(s) went straight to the vendor — the served`);
    console.log('         bundle predates the proxy. A push is not a deploy:');
    console.log('           scripts/serve-https-spa.sh build && scripts/serve-https-spa.sh deploy');
    failures += transports.direct;
  }
  for (const b of beaconRequests.filter((x) => !x.direct)) {
    // 2xx only. Our own 200 means "queued", not "delivered" — which is why
    // --instana-check exists below and why this assertion is not the end of it.
    if (b.status === null || b.status < 200 || b.status >= 300) {
      console.log(`  FAULT: ${FIRST_PARTY_BEACON_PATH} answered ${b.status ?? 'nothing'} — we refused our own beacon`);
      failures += 1;
    }
    if (b.method !== 'POST') {
      console.log(`  FAULT: beacon sent as ${b.method}; the proxy is POST-only by design`);
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

  // ---- did the VENDOR get it -----------------------------------------------
  // The only end-to-end proof. Everything above proves the browser reached US.
  if (args.has('instana-check')) {
    const waitMs = Number(args.get('instana-wait') ?? 180000);
    if (!sessionId) {
      console.log('\ninstana            UNCHECKED — no kh.sessionId on the page to look up');
    } else {
      console.log(`\ninstana            polling for kh.sessionId=${sessionId} (up to ${Math.round(waitMs / 1000)}s)…`);
      const seen = await instanaSawSession(sessionId, waitMs);
      report.instana = seen;
      if (!seen.checked) {
        console.log(`  UNCHECKED — ${seen.why}`);
      } else if (seen.found) {
        console.log(`  FOUND in the tenant (${seen.sampled} PAGELOAD beacon(s) sampled)`);
        console.log('  -> the beacon travelled browser -> our origin -> the box -> Instana.');
      } else {
        console.log(`  NOT FOUND — ${seen.why}`);
        console.log('  The proxy accepted the beacon and the forward did not arrive. Check');
        console.log("  journalctl -u osgallery-https for '[serve] EUM proxy upstream failure'.");
        failures += 1;
      }
    }
  }

  if (failures > 0) {
    console.log(`\nFAIL: ${failures} fault(s) — see the FAULT lines above.`);
    process.exitCode = 1;
  } else if (resolve) {
    console.log('\nOK: beacons are first-party, accepted, and every backendTraceId resolves.');
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
