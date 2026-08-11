// ff-attach-order.mjs — stall rate vs acceptor attach order, N sessions each.
import { firefox } from 'playwright';
const N = Number(process.argv[2] || 10);
const browser = await firefox.launch({ headless: true });
const page = await browser.newPage({ ignoreHTTPSErrors: true });
await page.goto('https://192.0.2.10:8443/', { waitUntil: 'domcontentloaded' });
for (const mode of ['pre-ready', 'post-ready-first', 'input-streams-first']) {
  let ok = 0, stall = 0;
  for (let i = 0; i < N; i++) {
    const streams = await page.evaluate(async ({ mode }) => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const sig = await (await fetch('/signal/freedos.json', { cache: 'no-store' })).json();
      const hash = Uint8Array.from(atob(sig.certHashB64), (c) => c.charCodeAt(0));
      // sig.path carries the signed session ticket when the station runs with
      // SH_SESSION_KEY; a hardcoded /wt is refused before accept() in that case.
      const wt = new WebTransport(`https://${sig.host}:${sig.udpPort}${sig.path || '/wt'}`, { serverCertificateHashes: [{ algorithm: 'sha-256', value: hash.buffer }] });
      let streams = 0;
      let acceptor;
      const startAccept = () => {
        acceptor = wt.incomingUnidirectionalStreams.getReader();
        (async () => {
          for (;;) {
            const { value, done } = await acceptor.read();
            if (done) break;
            streams++;
            (async () => { try { const r = value.getReader(); for (;;) { const { done } = await r.read(); if (done) break; } } catch { } })();
          }
        })().catch(() => {});
      };
      if (mode === 'pre-ready') startAccept();
      await wt.ready;
      if (mode === 'post-ready-first') startAccept();
      // dgWriter + 3 input uni streams (streamClient order)
      try { wt.datagrams.writable.getWriter(); } catch { }
      for (const tag of [1, 2, 3]) {
        try { const s = await wt.createUnidirectionalStream(); const w = s.getWriter(); await w.write(new Uint8Array([tag])); } catch { }
      }
      if (mode === 'input-streams-first') startAccept();
      await sleep(3500);
      const n = streams;
      try { wt.close(); } catch { }
      await sleep(150);
      return n;
    }, { mode });
    if (streams > 3) ok++; else stall++;
  }
  console.log(`${mode.padEnd(20)} OK=${ok}/${N} STALL=${stall}/${N}`);
}
await browser.close();
