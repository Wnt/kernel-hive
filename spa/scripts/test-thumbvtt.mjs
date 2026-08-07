// ============================================================================
//  test-thumbvtt.mjs — framework-free unit tests for src/ui/grid/thumbVtt.ts
//  ---------------------------------------------------------------------------
//  Run: npm run test:thumbvtt   (node --experimental-strip-types, no vitest —
//  thumbVtt.ts is erasable-TS so node can strip and execute it directly).
//  Covers the boot-video scrub-preview parser: canonical cue blocks, the WEBVTT
//  header + NOTE blocks being skipped, CRLF tolerance, media-fragment #xywh
//  extraction, relative sprite-URL resolution against the .vtt base, and the
//  thumbAt() cue lookup (in-window + past-end fallback + empty).
// ============================================================================
import assert from 'node:assert/strict';
import { parseThumbVtt, thumbAt } from '../src/ui/grid/thumbVtt.ts';

const BASE = 'https://host/boot/win95/thumbs.vtt';
let n = 0;
const ok = (name, fn) => { fn(); n++; console.log(`  ok ${n} — ${name}`); };

// A representative track exactly as the box generator emits (spec §6.3): a
// WEBVTT header, then one cue per N-second window, payload = sprite crop.
const VTT = [
  'WEBVTT',
  '',
  '00:00:00.000 --> 00:00:02.000',
  'sprite.jpg#xywh=0,0,160,90',
  '',
  '00:00:02.000 --> 00:00:04.000',
  'sprite.jpg#xywh=160,0,160,90',
  '',
  '00:00:04.000 --> 00:00:06.500',
  'sprite.jpg#xywh=320,0,160,90',
  '',
].join('\n');

ok('parse: three cues, header skipped, exact times/crops', () => {
  const cues = parseThumbVtt(VTT, BASE);
  assert.equal(cues.length, 3);
  assert.deepEqual(
    cues.map((c) => [c.t0, c.t1]),
    [[0, 2], [2, 4], [4, 6.5]],
  );
  assert.deepEqual(
    cues.map((c) => [c.x, c.y, c.w, c.h]),
    [[0, 0, 160, 90], [160, 0, 160, 90], [320, 0, 160, 90]],
  );
});

ok('parse: sprite URL resolved relative to the .vtt base', () => {
  const cues = parseThumbVtt(VTT, BASE);
  assert.equal(cues[0].src, 'https://host/boot/win95/sprite.jpg');
  assert.equal(cues[2].src, 'https://host/boot/win95/sprite.jpg');
});

ok('parse: CRLF line endings tolerated', () => {
  const cues = parseThumbVtt(VTT.replace(/\n/g, '\r\n'), BASE);
  assert.equal(cues.length, 3);
  assert.deepEqual([cues[1].t0, cues[1].x], [2, 160]);
});

ok('parse: NOTE / non-thumbnail / empty blocks are skipped', () => {
  const withNote = [
    'WEBVTT',
    '',
    'NOTE this is a comment block',
    '',
    '00:00:00.000 --> 00:00:02.000',
    'sprite.jpg#xywh=0,0,160,120',
    '',
    'garbage that is not a cue',
    '',
  ].join('\n');
  const cues = parseThumbVtt(withNote, BASE);
  assert.equal(cues.length, 1);
  assert.deepEqual([cues[0].w, cues[0].h], [160, 120]);
});

ok('parse: fully malformed / empty input → []', () => {
  assert.deepEqual(parseThumbVtt('', BASE), []);
  assert.deepEqual(parseThumbVtt('WEBVTT\n\nnot a cue at all', BASE), []);
});

ok('parse: multi-digit x/y offsets (later sprite rows)', () => {
  const v = 'WEBVTT\n\n00:01:05.500 --> 00:01:07.000\nsprite.jpg#xywh=1440,270,160,90\n';
  const cues = parseThumbVtt(v, BASE);
  assert.equal(cues.length, 1);
  assert.deepEqual(
    [cues[0].t0, cues[0].t1, cues[0].x, cues[0].y],
    [65.5, 67, 1440, 270],
  );
});

// ---- thumbAt lookup ----------------------------------------------------------
ok('thumbAt: in-window pick (half-open [t0,t1))', () => {
  const cues = parseThumbVtt(VTT, BASE);
  assert.equal(thumbAt(cues, 0).x, 0);
  assert.equal(thumbAt(cues, 1.999).x, 0);
  assert.equal(thumbAt(cues, 2).x, 160);   // boundary belongs to next cue
  assert.equal(thumbAt(cues, 5).x, 320);
});

ok('thumbAt: past-end scrub falls back to the last cue', () => {
  const cues = parseThumbVtt(VTT, BASE);
  assert.equal(thumbAt(cues, 999).x, 320);
});

ok('thumbAt: empty cue list → undefined', () => {
  assert.equal(thumbAt([], 3), undefined);
});

console.log(`\ntest-thumbvtt: all ${n} assertions green`);
