import { useEffect, useRef, type CSSProperties, type RefObject } from 'react';
import { contentRectFor } from '../letterbox';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import type { PresentAspect } from '../presentAspect';
import { followPan } from './followPan';
import type { GestureState, Vec2 } from './types';

// ---------------------------------------------------------------------------
//  OnScreenCursor (T-3) — the ABS-station trackpad sprite. Absolute stations have no
//  guest-drawn cursor, so a relative-style trackpad needs a LOCAL pointer to aim.
//  This paints a small crosshair at the trackpad engine's virtual cursor (guest px, read
//  imperatively from cursorRef in a rAF loop so StreamView never re-renders per
//  move). The guest point is projected into the letterboxed picture rect and then
//  through the SAME local pinch-zoom transform (gestureRef) so the sprite stays
//  glued to the pixel the click will land on, zoomed or not. Sends NOTHING to the
//  guest — but it does pan the LOCAL view (followPan.ts) when the crosshair
//  reaches an edge, because it is the only thing that knows where the crosshair
//  actually lands on glass, and a cursor off the visible edge is unusable.
// ---------------------------------------------------------------------------

const WRAP: CSSProperties = {
  position: 'absolute', inset: 0, zIndex: 57, pointerEvents: 'none', overflow: 'hidden',
};
// A CROSSHAIR, not a filled ring: this sprite marks the exact pixel a tap will
// click, and a 22 px disc covered that pixel along with everything around it —
// on a 1288×1024 exhibit scaled to a phone, the old dot hid ~70 guest px of
// whatever it was being aimed at. Sized like a desktop crosshair cursor, with
// the centre left open so the target stays visible while you glide onto it.
const DOT: CSSProperties = {
  position: 'absolute', top: 0, left: 0, width: 0, height: 0,
  pointerEvents: 'none', willChange: 'transform',
};
// One arm. Rides ON the guest picture, whose pixels can be any colour: terracotta
// inside a white halo stays findable over both a dark console and a light GUI —
// the same trick a desktop crosshair cursor uses (black line, white outline).
const ARM: CSSProperties = {
  position: 'absolute', background: 'rgba(156,79,53,0.95)',
  boxShadow: '0 0 0 1px rgba(255,255,255,0.85)',
};
// Desktop-crosshair proportions: 15 px across, 1 px lines, a 5 px hole at the
// centre. The half-pixel offsets put the 1 px line exactly on the point.
const H_ARM: CSSProperties = { ...ARM, top: -0.5, left: -7.5, width: 5, height: 1 };
const V_ARM: CSSProperties = { ...ARM, top: -7.5, left: -0.5, width: 1, height: 5 };
// Filled centre while a DRAG holds the button down. Touch gives no other
// feedback that the drag took: without this, a re-press that came too late to
// inherit the click looks identical to one that did — the finger moves either
// way, and only one of them drags anything.
const HELD_DOT: CSSProperties = {
  position: 'absolute', top: -2.5, left: -2.5, width: 5, height: 5, borderRadius: '50%',
  background: 'rgba(156,79,53,0.95)', boxShadow: '0 0 0 1px rgba(255,255,255,0.85)',
};

export function OnScreenCursor({
  cursorRef,
  heldRef,
  control,
  gestureRef,
  onPan,
  presentAspect = null,
}: {
  cursorRef: RefObject<Vec2 | null>;
  /** The trackpad is holding its button down — paint the crosshair filled. */
  heldRef: RefObject<boolean>;
  control: StreamControlHandle | null;
  gestureRef: RefObject<GestureState>;
  /** Commit a followPan into the React view transform. */
  onPan: (p: { x: number; y: number }) => void;
  // When set (era-correct 4:3 stations), the picture is a display-aspect box the
  // framebuffer is stretched to fill — position the sprite against THAT box, not
  // the object-fit:contain rect, so it stays glued to the pixel under it.
  presentAspect?: PresentAspect | null;
}) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const dotRef = useRef<HTMLDivElement>(null);
  const heldDotRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let raf = 0;
    // The cursor as of the previous frame. The view follows what the CURSOR
    // does; see the guard below for why that is not the same as "keep the
    // crosshair on screen at all times".
    let lastX = NaN;
    let lastY = NaN;
    const tick = () => {
      raf = requestAnimationFrame(tick);
      const dot = dotRef.current;
      const wrap = wrapRef.current;
      const c = cursorRef.current;
      if (!dot || !wrap) return;
      if (!c || !control) { dot.style.opacity = '0'; return; }
      const res = control.getResolution();
      const w0 = wrap.offsetWidth;
      const h0 = wrap.offsetHeight;
      // The wrap fills the stage, exactly like the picture. Its content rect IS the
      // picture rect: object-fit:contain uses the source resolution, while an
      // era-correct 4:3 station fills a display-aspect box (same fit maths, {4,3}
      // "resolution"). Guest px are then normalised by the REAL resolution below.
      const content = contentRectFor(w0, h0, presentAspect ?? res);
      let px = content.offsetX + (res.w > 1 ? c.x / (res.w - 1) : 0) * content.width;
      let py = content.offsetY + (res.h > 1 ? c.y / (res.h - 1) : 0) * content.height;
      // Follow the local pinch-zoom transform (origin center).
      const g = gestureRef.current;
      const cxp = w0 / 2;
      const cyp = h0 / 2;
      px = cxp + (px - cxp) * g.s + g.x;
      py = cyp + (py - cyp) * g.s + g.y;
      // FOLLOW: a crosshair at the edge drags the view along with it — but ONLY
      // when the cursor is what moved. Running this every frame made it a veto
      // on the visitor's own panning: a two-finger pan that pushed the crosshair
      // toward an edge was pulled straight back, so the view could never reach
      // the picture's left or right edge however far the finger travelled. The
      // cursor moving is the whole reason to chase it; the view moving is not.
      const cursorMoved = c.x !== lastX || c.y !== lastY;
      lastX = c.x;
      lastY = c.y;
      // …and never mid-gesture, where the pinch layer owns the transform.
      const pan = cursorMoved && g.mode === 'none'
        ? followPan({ px, py, w: w0, h: h0, s: g.s, x: g.x, y: g.y })
        : null;
      if (pan) {
        // Applied to this frame's position too, so the sprite never lags the
        // picture by a frame.
        px += pan.x - g.x;
        py += pan.y - g.y;
        g.x = pan.x;
        g.y = pan.y;
        onPan(pan);
      }
      dot.style.opacity = '1';
      dot.style.transform = `translate(${px}px, ${py}px)`;
      const held = heldDotRef.current;
      if (held) held.style.opacity = heldRef.current ? '1' : '0';
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [cursorRef, heldRef, control, gestureRef, onPan, presentAspect]);

  return (
    <div ref={wrapRef} style={WRAP}>
      <div ref={dotRef} style={{ ...DOT, opacity: 0 }}>
        <div style={H_ARM} />
        <div style={{ ...H_ARM, left: 2.5 }} />
        <div style={V_ARM} />
        <div style={{ ...V_ARM, top: 2.5 }} />
        <div ref={heldDotRef} style={{ ...HELD_DOT, opacity: 0 }} />
      </div>
    </div>
  );
}
