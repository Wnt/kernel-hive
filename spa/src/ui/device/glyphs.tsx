// ============================================================================
//  glyphs — the small line symbols printed on device keys
//  ---------------------------------------------------------------------------
//  Each glyph is drawn in a unit box (-1..1 on both axes) and placed with a
//  translate+scale, so one set of paths serves every key size. Strokes do not
//  scale (vector-effect), which keeps the drawing a clean line drawing at any
//  viewport width, the same weight as the key outlines.
// ============================================================================

import type { Glyph } from './deviceTypes';

const PATHS: Record<Exclude<Glyph, 'help'>, string> = {
  right: 'M-0.85 0H0.85M0.4 -0.42L0.85 0L0.4 0.42',
  left: 'M0.85 0H-0.85M-0.4 -0.42L-0.85 0L-0.4 0.42',
  up: 'M0 0.85V-0.85M-0.42 -0.4L0 -0.85L0.42 -0.4',
  down: 'M0 -0.85V0.85M-0.42 0.4L0 0.85L0.42 0.4',
  backspace: 'M1 0H-0.95M-0.5 -0.4L-0.95 0L-0.5 0.4',
  tab: 'M-0.95 -0.72V-0.08M-0.95 -0.4H0.95M-0.6 -0.66L-0.95 -0.4L-0.6 -0.14'
    + 'M0.95 0.08V0.72M-0.95 0.4H0.95M0.6 0.14L0.95 0.4L0.6 0.66',
  enter: 'M0.55 -1V0.65H-0.75M-0.4 0.33L-0.75 0.65L-0.4 0.97',
  shift: 'M0 -0.9L0.82 0H0.36V0.82H-0.36V0H-0.82Z',
  zoomIn: 'M0.95 -0.25A0.6 0.6 0 1 1 -0.25 -0.25A0.6 0.6 0 1 1 0.95 -0.25M-0.08 0.2L-0.85 0.95'
    + 'M0.35 -0.55V0.05M0.05 -0.25H0.65',
  zoomOut: 'M0.95 -0.25A0.6 0.6 0 1 1 -0.25 -0.25A0.6 0.6 0 1 1 0.95 -0.25M-0.08 0.2L-0.85 0.95'
    + 'M0.05 -0.25H0.65',
  bluetooth: 'M-0.45 -0.45L0.45 0.45L0 0.9V-0.9L0.45 -0.45L-0.45 0.45',
  infrared: 'M-0.95 -0.45H-0.45V0.45H-0.95ZM-0.45 -0.2H-0.2V0.2H-0.45'
    + 'M0.05 -0.3V0.3M0.4 -0.3V0.3M0.75 -0.3V0.3',
  brightness: 'M0.36 0A0.36 0.36 0 1 1 -0.36 0A0.36 0.36 0 1 1 0.36 0'
    + 'M0 -0.62V-0.95M0 0.62V0.95M-0.62 0H-0.95M0.62 0H0.95'
    + 'M-0.44 -0.44L-0.67 -0.67M0.44 0.44L0.67 0.67M-0.44 0.44L-0.67 0.67M0.44 -0.44L0.67 -0.67',
  sync: 'M0.72 -0.1A0.72 0.72 0 1 0 0.25 0.68M0.72 -0.1L0.95 -0.48M0.72 -0.1L0.36 -0.3'
    + 'M0.3 0.05A0.3 0.3 0 1 0 -0.1 0.3',
};

export function GlyphMark({
  name, x, y, size, color, width = 1.1,
}: {
  name: Glyph;
  x: number;
  y: number;
  /** Half-extent in viewBox units. */
  size: number;
  color: string;
  width?: number;
}) {
  const t = `translate(${x} ${y}) scale(${size})`;
  if (name === 'help') {
    return (
      <g transform={t} stroke={color} fill="none" strokeWidth={width}>
        <path d="M-0.8 -0.75H0.8V0.45H-0.1L-0.5 0.85V0.45H-0.8Z" vectorEffect="non-scaling-stroke" strokeLinejoin="round" />
        <text x={0} y={0.28} fontSize={1} textAnchor="middle" fill={color} stroke="none" fontWeight={700}>?</text>
      </g>
    );
  }
  return (
    <g transform={t}>
      <path d={PATHS[name]} fill="none" stroke={color} strokeWidth={width}
        strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
    </g>
  );
}
