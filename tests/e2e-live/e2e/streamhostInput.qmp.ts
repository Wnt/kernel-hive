// ============================================================================
//  streamhostInput.qmp.ts — host-side framebuffer verification for the
//  streamhost (WebTransport+WebCodecs) tiles.
//  ---------------------------------------------------------------------------
//  The neko suites pixel-verify a guest reaction through the neko ADMIN API on a
//  second browser page. streamhost tiles have NO such admin API — instead every
//  tile is a QEMU process exposing a QMP unix socket at
//    /data/vms/streamhost/tiles/<stationDir>/qmp.sock
//  so we verify a guest reaction DIRECTLY off the authoritative guest framebuffer
//  via QMP `screendump` (PPM). This is stronger than the neko path: it reads the
//  real VGA framebuffer, not a re-encoded stream, and is completely independent
//  of what the browser managed to decode.
//
//  Because the tile QMP sockets are LOCAL unix sockets on the streamhost box, the
//  Playwright suite MUST run ON THE HOST (or anywhere with those sockets mounted).
//  Fresh Chromes on the dev Mac are additionally blocked from 192.168.x.x by
//  macOS local-network privacy, so on-host headless Chrome is the only runner.
// ============================================================================

import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';

/** Root dir holding each tile's qmp.sock (…/<stationDir>/qmp.sock). */
export const TILES_ROOT =
  process.env.STREAMHOST_TILES_DIR ?? '/data/vms/streamhost/tiles';

/** Scratch dir for the PPM screendumps QEMU writes (must be writable by QEMU). */
export const SHOT_DIR = process.env.STREAMHOST_SHOT_DIR ?? '/data/streamhost-input-test/shots';

export function qmpSock(stationDir: string): string {
  return path.join(TILES_ROOT, stationDir, 'qmp.sock');
}

export interface Ppm { w: number; h: number; data: Buffer; }
export interface DiffResult { changedFrac: number; meanDelta: number; note?: string; }

/**
 * Ask a tile's QEMU (over its QMP unix socket) to dump its current framebuffer to
 * `outPath` as a PPM. Resolves when QMP returns success (the file is fully written
 * before the `return`). Read-only w.r.t. the guest — screendump only READS the FB.
 */
export function screendump(sock: string, outPath: string, timeoutMs = 12000): Promise<string> {
  return new Promise((resolve, reject) => {
    const s = net.createConnection(sock);
    let buf = '';
    let stage = 0; // 0=await greeting 1=await caps-return 2=await screendump-return
    const to = setTimeout(() => { s.destroy(); reject(new Error(`qmp timeout @ ${sock}`)); }, timeoutMs);
    s.on('error', (e) => { clearTimeout(to); reject(e); });
    s.on('data', (d) => {
      buf += d.toString('utf8');
      let idx: number;
      while ((idx = buf.indexOf('\r\n')) >= 0) {
        const line = buf.slice(0, idx); buf = buf.slice(idx + 2);
        if (!line.trim()) continue;
        let msg: Record<string, unknown>;
        try { msg = JSON.parse(line); } catch { continue; }
        if (stage === 0 && 'QMP' in msg) {
          s.write(JSON.stringify({ execute: 'qmp_capabilities' }) + '\r\n'); stage = 1;
        } else if (stage === 1 && 'return' in msg) {
          s.write(JSON.stringify({ execute: 'screendump', arguments: { filename: outPath } }) + '\r\n');
          stage = 2;
        } else if (stage === 2 && 'return' in msg) {
          clearTimeout(to); s.end(); resolve(outPath);
        } else if ('error' in msg) {
          clearTimeout(to); s.destroy(); reject(new Error(`qmp error: ${JSON.stringify(msg.error)}`));
        }
      }
    });
  });
}

/** Parse a binary P6 PPM (the format QEMU screendump emits). */
export function readPpm(p: string): Ppm {
  const b = fs.readFileSync(p);
  if (b[0] !== 0x50 || b[1] !== 0x36) throw new Error(`not a P6 PPM: ${p}`);
  let i = 2; const toks: string[] = [];
  while (toks.length < 3) {
    while (i < b.length && /\s/.test(String.fromCharCode(b[i]))) i++;
    if (String.fromCharCode(b[i]) === '#') { while (i < b.length && b[i] !== 0x0a) i++; continue; }
    let t = ''; while (i < b.length && !/\s/.test(String.fromCharCode(b[i]))) { t += String.fromCharCode(b[i]); i++; }
    toks.push(t);
  }
  i++; // one whitespace byte after maxval
  const w = Number(toks[0]), h = Number(toks[1]);
  return { w, h, data: b.subarray(i, i + w * h * 3) };
}

/**
 * changedFrac = fraction of pixels whose max channel delta exceeds `thresh`;
 * meanDelta   = mean per-pixel mean-abs channel delta. A resolution change is
 * itself a strong reaction (mode switch), reported as a saturated diff.
 */
export function diffPpm(a: Ppm, b: Ppm, thresh = 24): DiffResult {
  if (a.w !== b.w || a.h !== b.h) return { changedFrac: 1, meanDelta: 255, note: 'dim-change' };
  const n = Math.min(a.data.length, b.data.length);
  let changed = 0, sum = 0; const px = n / 3;
  for (let i = 0; i < n; i += 3) {
    const dr = Math.abs(a.data[i] - b.data[i]);
    const dg = Math.abs(a.data[i + 1] - b.data[i + 1]);
    const db = Math.abs(a.data[i + 2] - b.data[i + 2]);
    sum += (dr + dg + db) / 3;
    if (dr > thresh || dg > thresh || db > thresh) changed++;
  }
  return { changedFrac: changed / px, meanDelta: sum / px };
}

export const fmtDiff = (d: DiffResult | null): string =>
  d ? `cf=${d.changedFrac.toExponential(2)} md=${d.meanDelta.toFixed(2)}${d.note ? ` (${d.note})` : ''}` : 'n/a';

/** Take a fresh screendump of a tile and parse it. */
export async function shot(stationDir: string, label: string): Promise<Ppm> {
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  const out = path.join(SHOT_DIR, `${stationDir}-${label}.ppm`);
  await screendump(qmpSock(stationDir), out);
  return readPpm(out);
}

/**
 * Run a raw QMP command on a tile and resolve with its `return`/`error` object.
 * (Used for the optional snapshot-reset hook.)
 */
export function qmp(sock: string, execute: string, args?: Record<string, unknown>, timeoutMs = 20000): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const s = net.createConnection(sock);
    let buf = ''; let stage = 0;
    const to = setTimeout(() => { s.destroy(); reject(new Error(`qmp timeout @ ${sock}`)); }, timeoutMs);
    s.on('error', (e) => { clearTimeout(to); reject(e); });
    s.on('data', (d) => {
      buf += d.toString('utf8');
      let idx: number;
      while ((idx = buf.indexOf('\r\n')) >= 0) {
        const line = buf.slice(0, idx); buf = buf.slice(idx + 2);
        if (!line.trim()) continue;
        let msg: Record<string, unknown>;
        try { msg = JSON.parse(line); } catch { continue; }
        if (stage === 0 && 'QMP' in msg) { s.write(JSON.stringify({ execute: 'qmp_capabilities' }) + '\r\n'); stage = 1; }
        else if (stage === 1 && 'return' in msg) {
          s.write(JSON.stringify(args ? { execute, arguments: args } : { execute }) + '\r\n'); stage = 2;
        } else if (stage === 2 && ('return' in msg || 'error' in msg)) { clearTimeout(to); s.end(); resolve(msg); }
      }
    });
  });
}

/**
 * OPTIONAL deterministic reset: restore a tile's guest to a named internal snapshot
 * (a curated "golden desktop" state — apps installed, logged in) via QMP, live, WITH
 * NO daemon restart. Enabled per-run with STREAMHOST_RESET_SNAP=<name>. This is the
 * right way to make the suite fully deterministic and non-destructive to the canonical
 * disk — but it REQUIRES those golden snapshots to have been created first
 * (`savevm <name>` on a writable qcow2; tiles currently launch with `-snapshot`, whose
 * overlay must be dropped for a snapshot to persist). No-op (and logged) when unset.
 */
export async function loadSnapshot(stationDir: string, name: string): Promise<boolean> {
  const r = await qmp(qmpSock(stationDir), 'human-monitor-command', { 'command-line': `loadvm ${name}` });
  const out = (r.return as string | undefined) ?? '';
  // HMP loadvm prints nothing on success; any text is an error (e.g. "no such snapshot").
  return !out || !/error|no such|Device.*does not/i.test(out);
}
