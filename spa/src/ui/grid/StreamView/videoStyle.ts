import type { CSSProperties } from 'react';
import type { PresentAspect } from '../presentAspect';
import type { ZoomState } from './types';
import { S, presentFillStyle } from './styles';

// ---------------------------------------------------------------------------
//  videoStyleFor — the live picture element's inline style, as a pure function.
//
//  imageRendering by TRUE NATIVE RESOLUTION: pixelate only genuine low-res retro
//  framebuffers (≤800 wide); everything ≥1024 wide (Solaris 1920×1200) scales
//  smoothly. The native width is the guest's, NOT stats.frameWidth/Height (that
//  is the ABR-downscaled decode).
//
//  Plus the local pinch-zoom transform (identity → no transform at all, so input
//  mapping and desktop are untouched; transform-origin center, animated
//  snap-back) and the era-correct present-aspect fill, spread AFTER S.video so it
//  overrides w/h/object-fit.
// ---------------------------------------------------------------------------
export function videoStyleFor({
  nativeWidth, zoom, present,
}: {
  nativeWidth: number;
  zoom: ZoomState;
  present: PresentAspect | null;
}): CSSProperties {
  const pixelate = nativeWidth > 0 && nativeWidth <= 800;
  const zoomStyle: CSSProperties =
    zoom.s !== 1 || zoom.x !== 0 || zoom.y !== 0
      ? {
          transform: `translate3d(${zoom.x}px, ${zoom.y}px, 0) scale3d(${zoom.s}, ${zoom.s}, 1)`,
          transformOrigin: 'center center',
          transition: zoom.animated ? 'transform 180ms ease-out' : 'none',
          willChange: 'transform',
        }
      : {};
  const fit = present ? presentFillStyle(present) : null;
  return pixelate
    ? { ...S.video, ...fit, ...zoomStyle }
    : { ...S.video, imageRendering: 'auto', ...fit, ...zoomStyle };
}
