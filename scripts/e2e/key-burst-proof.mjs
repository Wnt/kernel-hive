// Key-burst proof: type a whole text into a station THROUGH THE DAEMON'S REAL
// RECEIVE PATH — a WebTransport session and its ICLASS_KEY reliable stream, the
// same records the SPA writes — with NO pacing at all.
//
// WHY. A visitor pasting a listing with AutoHotkey `SendText` fires browser key
// events as fast as Windows delivers them, so the daemon receives the line as
// one burst. That shape lost text on vic20 (2026-10-04): the sink's hand-off
// queue overflowed, and a module busy pacing the backlog was declared dead and
// KEYCLEARed. `key-replay.py` writes the emulator's ctl.sock directly and
// cannot see either failure; this probe can, because it goes through
// transport -> input::handle -> router -> sink -> module exactly as a browser
// does. Bypasses the gallery catalog (like direct-stream-proof.mjs), so it
// works on a sandbox daemon that is never published.
//
//   node key-burst-proof.mjs <signaling.json> <text-file> [--pace-ms N] [--hold-ms N]
//        [--char-ms N [--line-ms N] [--enter-ms N] [--wrap-cols N --wrap-ms N [--wrap-prompt N]]]
//
// <text-file>: what to type; each '\n' is Enter. Letters are sent UNSHIFTED
// (lower-case ASCII) and shifted punctuation gets real Shift_L edges round it,
// i.e. the host-key stream a US keyboard produces — upper-case input is sent
// as shifted letters, so keep listings for upper-case-only machines in lower
// case. --pace-ms 0 (default) writes every record at once; N > 0 waits N ms
// between records (a slow reference run). The session stays open --hold-ms
// (default 5000) after the last write so the daemon reads the whole stream.
//
// --wrap-cols N --wrap-ms M models registry typeIn.wrapPause: after every N-th
// character of a line (not the last) the next one waits M ms more;
// --wrap-prompt N counts N prompt columns on the line's first row.
//
// --char-ms N is the TYPE-IN EDITOR's shape instead of a paste: one character's
// edges at a time (Shift, key down, key up, Shift up, back to back — exactly
// what typeText() writes), then N ms; before each Enter --line-ms (default 260)
// and after it --enter-ms (default 600), typeLines()'s settles. Give it the
// station's typeIn.perCharMs to type at the editor's validated pace.
//
// PASS/FAIL is the framebuffer's, not this script's: screenshot the station
// (fb-wait.py --shm ... --out, or the module's SHOT verb) and compare.
// Prints the record count and how long the writes took.
import { chromium } from 'playwright';
import fs from 'node:fs';

const args = process.argv.slice(2);
const flag = (name, dflt) => {
  const i = args.indexOf(name);
  if (i < 0) return dflt;
  const v = Number(args[i + 1]);
  args.splice(i, 2);
  return v;
};
const PACE_MS = flag('--pace-ms', 0);
const HOLD_MS = flag('--hold-ms', 5000);
const CHAR_MS = flag('--char-ms', 0);
const LINE_MS = flag('--line-ms', 260);
const ENTER_MS = flag('--enter-ms', 600);
// typeIn.wrapPause: after every WRAP_COLS-th character of a line (not its last), WRAP_MS more.
const WRAP_COLS = flag('--wrap-cols', 0);
const WRAP_MS = flag('--wrap-ms', 0);
const WRAP_PROMPT = flag('--wrap-prompt', 0);
const [signalPath, textPath] = args;
if (!signalPath || !textPath) {
  console.error('usage: key-burst-proof.mjs <signaling.json> <text-file> [--pace-ms N] [--hold-ms N]');
  process.exit(2);
}

// XT set-1 scancodes of a US keyboard: char -> [scancode, shifted].
const US = {};
const row = (chars, codes, shifted) => [...chars].forEach((c, i) => { US[c] = [codes[i], shifted]; });
row('1234567890-=', [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d], false);
row('!@#$%^&*()_+', [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d], true);
row('qwertyuiop[]', [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b], false);
row('QWERTYUIOP{}', [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b], true);
row("asdfghjkl;'`", [0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29], false);
row('ASDFGHJKL:"~', [0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29], true);
row('\\zxcvbnm,./', [0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35], false);
row('|ZXCVBNM<>?', [0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35], true);
US[' '] = [0x39, false];
US['\n'] = [0x1c, false];
const SHIFT_L = 0x2a;

const text = fs.readFileSync(textPath, 'utf8').replace(/\r/g, '');
// [scancode, down, ms to wait after this edge]
const edges = [];
let col = 0; // characters typed on the current line
const lineLen = [];
for (const line of text.split('\n')) lineLen.push(line.length);
let lineNo = 0;
for (const ch of text) {
  const k = US[ch];
  if (!k) {
    console.error(`no US scancode for ${JSON.stringify(ch)}`);
    process.exit(2);
  }
  const [code, shifted] = k;
  // typeLines(): the line's own per-character wait, THEN lineDelayMs, then ENTER
  if (CHAR_MS > 0 && ch === '\n' && edges.length) edges.at(-1)[2] += LINE_MS;
  if (shifted) edges.push([SHIFT_L, 1, 0]);
  edges.push([code, 1, 0], [code, 0, 0]);
  if (shifted) edges.push([SHIFT_L, 0, 0]);
  if (CHAR_MS > 0) edges.at(-1)[2] = ch === '\n' ? ENTER_MS : CHAR_MS;
  if (ch === '\n') { col = 0; lineNo += 1; continue; }
  col += 1;
  if (WRAP_COLS > 0 && CHAR_MS > 0 && (col + WRAP_PROMPT) % WRAP_COLS === 0 && col < lineLen[lineNo]) edges.at(-1)[2] += WRAP_MS;
}

const sig = JSON.parse(fs.readFileSync(signalPath, 'utf8'));
const browser = await chromium.launch({
  headless: true, channel: 'chrome', args: ['--no-sandbox', '--ignore-certificate-errors'],
});
const page = await browser.newPage({ ignoreHTTPSErrors: true });
// Any secure origin will do; WebTransport authenticates the daemon by cert hash.
await page.goto(process.env.GALLERY_URL || 'https://192.0.2.10:8443/', {
  waitUntil: 'domcontentloaded', timeout: 30000,
});

const result = await page.evaluate(async ({ sig, edges, paceMs, holdMs }) => {
  const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const hash = Uint8Array.from(atob(sig.certHashB64), (c) => c.charCodeAt(0));
  const url = sig.url || `https://${sig.host}:${sig.udpPort}${sig.path || '/wt'}`;
  const wt = new WebTransport(url, {
    serverCertificateHashes: [{ algorithm: 'sha-256', value: hash.buffer }],
  });
  await wt.ready;
  // Drain (and drop) the video the daemon pushes, so its sends never stall.
  void (async () => {
    const incoming = wt.incomingUnidirectionalStreams.getReader();
    for (;;) {
      const { value, done } = await incoming.read();
      if (done) return;
      value.cancel().catch(() => {});
    }
  })();
  const stream = await wt.createUnidirectionalStream();
  const writer = stream.getWriter();
  await writer.write(new Uint8Array([1])); // ICLASS_KEY
  const t0 = performance.now();
  const pending = [];
  for (const [code, down, after] of edges) {
    const framed = new Uint8Array([4, 0, 3, down, code & 0xff, (code >> 8) & 0xff]);
    if (paceMs > 0) {
      await writer.write(framed);
      await delay(paceMs);
    } else if (after > 0) {
      pending.push(writer.write(framed)); // the editor: a character, then its wait
      await Promise.all(pending.splice(0));
      await delay(after);
    } else {
      pending.push(writer.write(framed)); // AHK shape: no wait between edges
    }
  }
  await Promise.all(pending);
  const writeMs = performance.now() - t0;
  await delay(holdMs);
  try { await writer.close(); } catch { /* session teardown */ }
  try { wt.close(); } catch { /* session teardown */ }
  return { url, records: edges.length, writeMs: Math.round(writeMs) };
}, { sig, edges, paceMs: PACE_MS, holdMs: HOLD_MS });

console.log(JSON.stringify({ ...result, chars: [...text].length, paceMs: PACE_MS, charMs: CHAR_MS }));
await browser.close();
