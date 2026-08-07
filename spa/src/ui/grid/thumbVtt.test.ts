// vitest port of scripts/test-thumbvtt.mjs (kept as the framework-free
// `npm run test:thumbvtt` sibling check). Covers the boot-video scrub-preview
// WebVTT parser: canonical cues, header/NOTE skipping, CRLF tolerance, sprite
// media-fragment extraction, relative URL resolution, and thumbAt() lookup.
import { describe, expect, it } from 'vitest';
import { parseThumbVtt, thumbAt } from './thumbVtt';

const BASE = 'https://host/boot/win95/thumbs.vtt';
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

describe('parseThumbVtt', () => {
  it('parses three cues with exact times/crops, header skipped', () => {
    const cues = parseThumbVtt(VTT, BASE);
    expect(cues.map((c) => [c.t0, c.t1])).toEqual([[0, 2], [2, 4], [4, 6.5]]);
    expect(cues.map((c) => [c.x, c.y, c.w, c.h])).toEqual([
      [0, 0, 160, 90], [160, 0, 160, 90], [320, 0, 160, 90],
    ]);
  });

  it('resolves the sprite URL relative to the .vtt base', () => {
    const cues = parseThumbVtt(VTT, BASE);
    expect(cues[0].src).toBe('https://host/boot/win95/sprite.jpg');
  });

  it('tolerates CRLF line endings', () => {
    const cues = parseThumbVtt(VTT.replace(/\n/g, '\r\n'), BASE);
    expect(cues).toHaveLength(3);
    expect([cues[1].t0, cues[1].x]).toEqual([2, 160]);
  });

  it('skips NOTE / non-thumbnail / garbage blocks', () => {
    const withNote = [
      'WEBVTT', '', 'NOTE this is a comment block', '',
      '00:00:00.000 --> 00:00:02.000', 'sprite.jpg#xywh=0,0,160,120', '',
      'garbage that is not a cue', '',
    ].join('\n');
    const cues = parseThumbVtt(withNote, BASE);
    expect(cues).toHaveLength(1);
    expect([cues[0].w, cues[0].h]).toEqual([160, 120]);
  });

  it('returns [] for empty / fully malformed input', () => {
    expect(parseThumbVtt('', BASE)).toEqual([]);
    expect(parseThumbVtt('WEBVTT\n\nnot a cue at all', BASE)).toEqual([]);
  });
});

describe('thumbAt', () => {
  it('picks the half-open [t0,t1) window', () => {
    const cues = parseThumbVtt(VTT, BASE);
    expect(thumbAt(cues, 0)?.x).toBe(0);
    expect(thumbAt(cues, 1.999)?.x).toBe(0);
    expect(thumbAt(cues, 2)?.x).toBe(160);
    expect(thumbAt(cues, 5)?.x).toBe(320);
  });

  it('falls back to the last cue past the end', () => {
    const cues = parseThumbVtt(VTT, BASE);
    expect(thumbAt(cues, 999)?.x).toBe(320);
  });

  it('returns undefined for an empty cue list', () => {
    expect(thumbAt([], 3)).toBeUndefined();
  });
});
