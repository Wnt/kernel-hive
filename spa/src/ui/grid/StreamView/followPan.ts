// ============================================================================
//  followPan — keep the trackpad crosshair on screen while the view is zoomed.
//  ---------------------------------------------------------------------------
//  Pinch-zoom shows a SUB-RECT of the picture, but the trackpad cursor moves
//  across the whole guest framebuffer. Nothing tied the two together: glide far
//  enough at 3× and the crosshair walks off the visible edge, and from there the
//  visitor is pointing at something they cannot see — with no way back except
//  panning by hand, which is a different gesture with a different finger count.
//
//  So the view follows the cursor: when the crosshair comes within `margin` of an
//  edge, the local transform pans by exactly enough to put it back on the margin.
//  It CANNOT pan past the picture, because it clamps with the same bound the
//  pinch layer uses — the two must agree or they would fight each other, one
//  pushing the view out and the other snapping it back.
//
//  Pure (CSS px in, CSS px out) so the edge maths is testable without a DOM; the
//  sprite's own rAF loop supplies the numbers, being the only thing that already
//  knows where the crosshair lands on glass.
// ============================================================================

/** Keep the crosshair at least this far inside the stage, so it arrives with a
 *  little of what it is approaching already visible rather than flush to it. */
const EDGE_MARGIN = 28;

interface FollowPanInput {
  /** Crosshair position in the stage box, CSS px, view transform applied. */
  px: number;
  py: number;
  /** Stage box size, CSS px. */
  w: number;
  h: number;
  /** Current local view transform (scale + pan). */
  s: number;
  x: number;
  y: number;
  margin?: number;
}

/** The pan the view should move to, or null if the crosshair is comfortably
 *  inside — or if the picture cannot move any further that way. */
export function followPan(i: FollowPanInput): { x: number; y: number } | null {
  if (i.s <= 1.001) return null; // unzoomed: the whole picture is on screen
  const m = i.margin ?? EDGE_MARGIN;
  let x = i.x;
  let y = i.y;
  if (i.px < m) x += m - i.px;
  else if (i.px > i.w - m) x -= i.px - (i.w - m);
  if (i.py < m) y += m - i.py;
  else if (i.py > i.h - m) y -= i.py - (i.h - m);
  // The SAME clamp usePinchZoom applies, so a follow and a pinch can never
  // disagree about how far the picture is allowed to travel.
  const mx = Math.max(0, ((i.s - 1) * i.w) / 2);
  const my = Math.max(0, ((i.s - 1) * i.h) / 2);
  x = Math.min(Math.max(x, -mx), mx);
  y = Math.min(Math.max(y, -my), my);
  return x === i.x && y === i.y ? null : { x, y };
}
