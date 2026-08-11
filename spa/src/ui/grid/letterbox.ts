// ============================================================================
//  2D LETTERBOX COORDINATE MAP  (Agent-B / StreamView)
//  ---------------------------------------------------------------------------
//  The 2D StreamView renders the guest framebuffer into a plain <video> with
//  `object-fit: contain` — the frame is scaled to fit and letterboxed (pillar-
//  or bar-boxed) inside the element box. To drive the guest we must invert that
//  fit: map a viewport client point (clientX/clientY) back to ABSOLUTE GUEST
//  PIXELS in the stream's own resolution, and reject points that land on the
//  black letterbox bars (outside the actual image).
//
//  The displayed content rect is a simple object-fit:contain box. A DOM <video>
//  shows the frame upright, so guest-Y maps straight down from the top.
// ============================================================================

export interface GuestPoint {
  x: number;
  y: number;
}

export interface Resolution {
  w: number;
  h: number;
}

/** The image content rect (CSS px, relative to the element box) under object-fit:contain. */
export interface ContentRect {
  offsetX: number;
  offsetY: number;
  width: number;
  height: number;
}

const clamp01 = (n: number): number => (n < 0 ? 0 : n > 1 ? 1 : n);

/**
 * Given the element's box size and the source (guest) resolution, return the
 * rect the image actually occupies inside that box under `object-fit: contain`.
 *
 * When `fill` is true (era-correct non-square-pixel stations, see presentAspect.ts)
 * the element box IS the target display rect and the framebuffer is stretched to
 * fill it (`object-fit: fill`), so the image occupies the WHOLE box — the pointer
 * map below then spreads u/v across the full box back to guest pixels, keeping
 * clicks resolution-accurate despite the stretch.
 */
export function contentRectFor(
  boxW: number,
  boxH: number,
  res: Resolution,
  fill = false,
): ContentRect {
  if (boxW <= 0 || boxH <= 0 || res.w <= 0 || res.h <= 0) {
    return { offsetX: 0, offsetY: 0, width: Math.max(0, boxW), height: Math.max(0, boxH) };
  }
  if (fill) {
    return { offsetX: 0, offsetY: 0, width: boxW, height: boxH };
  }
  const srcAspect = res.w / res.h;
  const boxAspect = boxW / boxH;
  if (srcAspect > boxAspect) {
    // Source wider than the box -> fill width, bars top & bottom.
    const width = boxW;
    const height = width / srcAspect;
    return { offsetX: 0, offsetY: (boxH - height) / 2, width, height };
  }
  // Source taller/narrower -> fill height, bars left & right.
  const height = boxH;
  const width = height * srcAspect;
  return { offsetX: (boxW - width) / 2, offsetY: 0, width, height };
}

/**
 * Map a viewport client point onto the guest framebuffer.
 *
 * @param clientX / clientY  pointer position in viewport CSS px (e.g. e.clientX)
 * @param rect               the <video> element's getBoundingClientRect()
 * @param res                guest resolution in px (handle.getResolution())
 * @param clampToImage       when true (default) points on the letterbox bars are
 *                           clamped onto the nearest image edge; when false they
 *                           return null so callers can ignore off-image input.
 * @param fill               when true the element box IS the display rect (the
 *                           framebuffer is stretched to fill it, object-fit:fill),
 *                           so the whole box maps to guest pixels (no letterbox).
 * @returns absolute guest pixel {x,y}, or null if off-image and clampToImage=false.
 */
export function clientToGuest(
  clientX: number,
  clientY: number,
  rect: { left: number; top: number; width: number; height: number },
  res: Resolution,
  clampToImage = true,
  fill = false,
): GuestPoint | null {
  const content = contentRectFor(rect.width, rect.height, res, fill);
  if (content.width <= 0 || content.height <= 0) return null;

  const localX = clientX - rect.left - content.offsetX;
  const localY = clientY - rect.top - content.offsetY;

  let u = localX / content.width;
  let v = localY / content.height;

  const onImage = u >= 0 && u <= 1 && v >= 0 && v <= 1;
  if (!onImage && !clampToImage) return null;

  u = clamp01(u);
  v = clamp01(v);

  // Absolute guest px. NO V-flip: a DOM <video> paints the frame upright.
  return {
    x: Math.round(u * (res.w - 1)),
    y: Math.round(v * (res.h - 1)),
  };
}
