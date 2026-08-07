// WebVTT thumbnail-track parser (boot-video scrub preview). No dependency.
// The track is generated box-side (BOOT-VIDEO-REPLAY-SPEC §6.3) as cues whose
// payload is a media-fragment `sprite.jpg#xywh=x,y,w,h` — one sprite crop per
// time window. We parse it once on load and, on hover, map cursor-time → cue →
// a CSS-cropped floating preview (§6.4). Kept in its own module (no React) so it
// is a pure function unit-testable by a plain node assert script.

export type Thumb = {
  t0: number; t1: number; src: string;
  x: number; y: number; w: number; h: number;
};

// "HH:MM:SS.mmm" → seconds. Tolerant of extra leading fields but expects the
// canonical 3-field cue timestamp the generator emits.
function cueSeconds(s: string): number {
  const [h, m, se] = s.split(':');
  return (+h) * 3600 + (+m) * 60 + (+se);
}

// Parse a WebVTT thumbnail track into ordered cues. `base` resolves the sprite
// URL relative to the .vtt (same-origin /boot/<id>/thumbs.vtt → sprite.jpg).
// Malformed / non-thumbnail blocks (the "WEBVTT" header, NOTE blocks) are
// skipped, so a partial file still yields whatever valid cues it holds.
export function parseThumbVtt(vtt: string, base: string): Thumb[] {
  const out: Thumb[] = [];
  for (const block of vtt.replace(/\r/g, '').split('\n\n')) {
    const m = block.match(
      /(\d\d:\d\d:\d\d\.\d\d\d)\s*-->\s*(\d\d:\d\d:\d\d\.\d\d\d)\s*\n(.+?)#xywh=(\d+),(\d+),(\d+),(\d+)/s,
    );
    if (!m) continue;
    let src: string;
    try { src = new URL(m[3].trim(), base).href; } catch { src = m[3].trim(); }
    out.push({
      t0: cueSeconds(m[1]), t1: cueSeconds(m[2]), src,
      x: +m[4], y: +m[5], w: +m[6], h: +m[7],
    });
  }
  return out;
}

// The cue covering time `t` (falls back to the last cue past the end so a scrub
// to the very end still previews the final frame). Returns undefined for [].
export function thumbAt(cues: Thumb[], t: number): Thumb | undefined {
  if (cues.length === 0) return undefined;
  return cues.find((c) => t >= c.t0 && t < c.t1) ?? cues[cues.length - 1];
}
