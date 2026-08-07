// ff-decode-matrix.mjs — empirical WebCodecs VideoDecoder permutation matrix.
// Feeds REAL captured streamhost AUs (capture-aus.mjs output) to VideoDecoder
// under every {mode × flush × hardwareAcceleration} permutation and reports
// decoded-frame counts. Runs inside a page on the SPA https origin (WebCodecs
// is SecureContext-only in Firefox).
//
// Usage: node ff-decode-matrix.mjs [firefox|chromium] [aus-file] [--quick]
//   --quick: only the interesting subset (annexb/avc-keep/avc-strip × none/each ×
//            no-preference) for fast re-verification.
import { chromium, firefox } from 'playwright';
import fs from 'node:fs';

const BROWSER = process.argv[2] || 'firefox';
const AUS_FILE = process.argv[3] && !process.argv[3].startsWith('--')
  ? process.argv[3] : `${process.env.HOME}/e2e/aus-freedos.json`;
const QUICK = process.argv.includes('--quick');
const ORIGIN = process.env.GALLERY_URL || 'https://192.0.2.10:8443';

const aus = JSON.parse(fs.readFileSync(AUS_FILE, 'utf8'));
if (!aus.length || !aus[0].isKey) throw new Error('AU set must start with a key AU');
console.log(`[matrix] ${BROWSER} · ${aus.length} AUs from ${AUS_FILE}`);

const launcher = BROWSER === 'chromium' ? chromium : firefox;
const launchOpts = BROWSER === 'chromium'
  ? { headless: true, args: ['--no-sandbox', '--ignore-certificate-errors'] }
  : { headless: true };
const browser = await launcher.launch(launchOpts);
const page = await browser.newPage({ ignoreHTTPSErrors: true });
page.on('console', (m) => { if (process.env.VERBOSE) console.log('[page]', m.text().slice(0, 300)); });
await page.goto(ORIGIN + '/', { waitUntil: 'domcontentloaded' });

const results = await page.evaluate(async ({ ausB64, quick }) => {
  const aus = ausB64.map((a) => ({
    frameId: a.frameId, isKey: a.isKey, ts: a.ts,
    bytes: Uint8Array.from(atob(a.b64), (c) => c.charCodeAt(0)),
  }));

  // ---- Annex-B helpers (mirror spa/src/three/annexb.ts) ----
  function scanAnnexB(au) {
    const nals = []; const n = au.length; let ps = -1; let i = 0;
    while (i + 2 < n) {
      if (au[i] === 0 && au[i + 1] === 0 && au[i + 2] === 1) {
        if (ps >= 0) { let e = i; if (e > ps && au[e - 1] === 0) e--; if (e > ps) nals.push({ type: au[ps] & 0x1f, start: ps, end: e }); }
        ps = i + 3; i += 3;
      } else if (au[i + 2] > 1) i += 3; else i++;
    }
    if (ps >= 0 && au.length > ps) nals.push({ type: au[ps] & 0x1f, start: ps, end: au.length });
    return nals;
  }
  function toAvcc(au, stripTypes) {
    const nals = scanAnnexB(au).filter((n) => !stripTypes.includes(n.type));
    let size = 0; for (const n of nals) size += 4 + (n.end - n.start);
    const out = new Uint8Array(size); let o = 0;
    for (const n of nals) {
      const len = n.end - n.start;
      out[o++] = (len >>> 24) & 0xff; out[o++] = (len >>> 16) & 0xff;
      out[o++] = (len >>> 8) & 0xff; out[o++] = len & 0xff;
      out.set(au.subarray(n.start, n.end), o); o += len;
    }
    return out;
  }
  const key = aus[0].bytes;
  let sps = null, pps = null;
  for (const n of scanAnnexB(key)) {
    if (n.type === 7 && !sps) sps = key.slice(n.start, n.end);
    if (n.type === 8 && !pps) pps = key.slice(n.start, n.end);
  }
  const avcC = (() => {
    const out = new Uint8Array(5 + 1 + 2 + sps.length + 1 + 2 + pps.length); let o = 0;
    out[o++] = 1; out[o++] = sps[1]; out[o++] = sps[2]; out[o++] = sps[3];
    out[o++] = 0xfc | 3; out[o++] = 0xe0 | 1;
    out[o++] = sps.length >> 8; out[o++] = sps.length & 0xff; out.set(sps, o); o += sps.length;
    out[o++] = 1; out[o++] = pps.length >> 8; out[o++] = pps.length & 0xff; out.set(pps, o);
    return out;
  })();
  const h = (b) => (b & 0xff).toString(16).padStart(2, '0');
  const codec = `avc1.${h(sps[1])}${h(sps[2])}${h(sps[3])}`;

  const support = {};
  for (const c of [codec, 'avc1.42e01e']) {
    try { support[c] = (await VideoDecoder.isConfigSupported({ codec: c, optimizeForLatency: true })).supported; }
    catch (e) { support[c] = String(e).slice(0, 80); }
  }
  try {
    support[codec + '+desc'] = (await VideoDecoder.isConfigSupported({
      codec, description: avcC, optimizeForLatency: true,
    })).supported;
  } catch (e) { support[codec + '+desc'] = String(e).slice(0, 80); }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  async function runPerm(mode, flushMode, hw) {
    // mode: 'annexb' | 'avc-strip' (strip 7/8, CURRENT) | 'avc-keep' | 'avc-stripsei'
    let outputs = 0, firstOutIdx = -1, firstError = null, fed = 0;
    const outSizes = [];
    const dec = new VideoDecoder({
      output: (f) => { outputs++; if (firstOutIdx < 0) firstOutIdx = fed; outSizes.push(`${f.codedWidth}x${f.codedHeight}`); f.close(); },
      error: (e) => { if (!firstError) firstError = String(e).slice(0, 160); },
    });
    const cfg = { codec, optimizeForLatency: true };
    if (mode !== 'annexb') cfg.description = avcC;
    if (hw !== 'omit') cfg.hardwareAcceleration = hw;
    try { dec.configure(cfg); } catch (e) {
      return { mode, flushMode, hw, fed: 0, outputs: 0, error: `configure threw: ${String(e).slice(0, 120)}` };
    }
    const strip = mode === 'avc-strip' ? [7, 8] : mode === 'avc-stripsei' ? [6, 7, 8] : mode === 'avc-keep' ? [] : null;
    let flushRejected = null;
    for (const a of aus) {
      if (dec.state === 'closed') break;
      const data = mode === 'annexb' ? a.bytes : toAvcc(a.bytes, strip);
      if (!data.length) continue;
      try {
        dec.decode(new EncodedVideoChunk({ type: a.isKey ? 'key' : 'delta', timestamp: a.ts, data }));
        fed++;
      } catch (e) { if (!firstError) firstError = `decode threw: ${String(e).slice(0, 120)}`; break; }
      if (flushMode === 'each' || (flushMode === 'after-key' && a.isKey)) {
        try { await Promise.race([dec.flush(), sleep(1500).then(() => { throw new Error('flush timeout'); })]); }
        catch (e) { if (!flushRejected) flushRejected = String(e).slice(0, 100); }
      }
    }
    // settle: wait up to 2s for late async outputs
    const t0 = performance.now();
    while (outputs < fed && performance.now() - t0 < 2000) await sleep(50);
    const during = outputs;
    const qAfterFeed = dec.state === 'closed' ? -1 : dec.decodeQueueSize;
    // final flush — does held output arrive only now?
    let finalFlushErr = null;
    if (dec.state === 'configured') {
      try { await Promise.race([dec.flush(), sleep(2000).then(() => { throw new Error('flush timeout'); })]); }
      catch (e) { finalFlushErr = String(e).slice(0, 100); }
    }
    await sleep(100);
    const total = outputs;
    try { dec.close(); } catch { /* noop */ }
    return {
      mode, flushMode, hw, fed, during, total, firstOutIdx, qAfterFeed,
      firstError, flushRejected, finalFlushErr,
      sizes: outSizes.slice(0, 2).join(','),
    };
  }

  const modes = quick ? ['annexb', 'avc-strip', 'avc-keep'] : ['annexb', 'avc-strip', 'avc-keep', 'avc-stripsei'];
  const flushes = quick ? ['none', 'each'] : ['none', 'after-key', 'each'];
  const hws = quick ? ['no-preference'] : ['no-preference', 'prefer-software', 'omit'];
  const rows = [];
  for (const mode of modes) for (const fl of flushes) for (const hw of hws) {
    rows.push(await runPerm(mode, fl, hw));
  }
  return { codec, avcCLen: avcC.length, support, rows, ua: navigator.userAgent };
}, { ausB64: aus, quick: QUICK });

console.log(`UA: ${results.ua}`);
console.log(`codec=${results.codec} avcC=${results.avcCLen}B support=${JSON.stringify(results.support)}`);
console.log('mode         flush      hw               fed  during total 1stOutIdx q  error');
for (const r of results.rows) {
  console.log(
    `${r.mode.padEnd(12)} ${r.flushMode.padEnd(10)} ${String(r.hw).padEnd(16)} ${String(r.fed).padStart(3)}  ${String(r.during ?? 0).padStart(5)} ${String(r.total ?? 0).padStart(5)} ${String(r.firstOutIdx ?? -1).padStart(6)}   ${String(r.qAfterFeed ?? '-').padStart(2)} ${r.error ?? r.firstError ?? r.flushRejected ?? r.finalFlushErr ?? ''} ${r.sizes ? '[' + r.sizes + ']' : ''}`,
  );
}
fs.writeFileSync(`${process.env.HOME}/e2e/matrix-${BROWSER}.json`, JSON.stringify(results, null, 2));
await browser.close();
