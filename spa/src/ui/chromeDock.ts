import { createContext, useContext, useEffect, useState, type CSSProperties } from 'react';
import { currentFullscreenElement } from './fullscreen';

// ---------------------------------------------------------------------------
//  chromeDock — WHERE a StreamView's chrome renders.
//  ---------------------------------------------------------------------------
//  A StreamView that fills a screen can float its controls in the picture's own
//  corners: the picture is the whole view, so a corner of it is the only place
//  a control could go. The landing page's MINI CANVAS is the opposite case. It
//  is one small object on a page with room all around it, and a 44px pill laid
//  on a 400x300 rendering of a 1024x768 guest screen covers a tenth of the
//  exhibit — which is the thing the page exists to show. So the landing page
//  hands StreamView two nodes BELOW the canvas and each piece of chrome portals
//  itself into one of them. The canvas then carries the guest's picture and
//  nothing else.
//
//  This is also what keeps the on-screen keyboard out of the picture. The
//  keyboard is already a sibling below `.sv-stage`, which is correct when the
//  root is the viewport — but inside a fixed 4:3 box it took its height out of
//  the guest instead, squeezing a whole desktop into a letterbox slit.
//
//  TRUE FULLSCREEN IS THE EXCEPTION, and it is not a detail: the fullscreen
//  element is `.sv-root`, and the top layer shows THAT subtree and nothing
//  else. Chrome portalled to a node outside it would simply vanish, taking the
//  way out of fullscreen and the keyboard with it. So the dock is ignored while
//  fullscreen is on, and every control goes back to the corner it came from —
//  which in fullscreen is also where it belongs.
// ---------------------------------------------------------------------------

export interface ChromeDock {
  /** The control row under the canvas: the stage menu, the touch badges, and
   *  the status notices that can appear over a healthy picture. */
  controls: HTMLElement | null;
  /** Where the on-screen keyboard opens, below the control row. */
  keys: HTMLElement | null;
}

/** No dock is the default, and it is what the station view and the walk-in
 *  view both use: chrome floats in the stage exactly as it always has. */
export const ChromeDockContext = createContext<ChromeDock | null>(null);

function useFullscreenOn(): boolean {
  const [on, setOn] = useState(() => currentFullscreenElement() !== null);
  useEffect(() => {
    const read = () => setOn(currentFullscreenElement() !== null);
    const types = ['fullscreenchange', 'webkitfullscreenchange'];
    for (const t of types) document.addEventListener(t, read);
    return () => { for (const t of types) document.removeEventListener(t, read); };
  }, []);
  return on;
}

/** The dock in force right now: null in a full-screen view, and null while
 *  browser fullscreen is on however the view is mounted. */
export function useChromeDock(): ChromeDock | null {
  const dock = useContext(ChromeDockContext);
  const fullscreen = useFullscreenOn();
  return fullscreen ? null : dock;
}

/** Merged OVER a floating notice's own style when it is docked, so a pill that
 *  positions itself against the stage stops floating and becomes a plain item
 *  in the control row. Every offset the notice might set is reset by name —
 *  a leftover `top: 18` is a notice hanging 18px below the row. */
export const DOCK_FLOW: CSSProperties = {
  position: 'static', top: 'auto', right: 'auto', bottom: 'auto', left: 'auto',
  transform: 'none', zIndex: 'auto',
};

/** Flow layout for a control that has left its stage corner. `order` fixes the
 *  row's reading order: portals land in whatever order they happen to mount,
 *  and a badge that appears only once the stream is live would otherwise jump
 *  the queue. `position: relative` keeps a dropdown anchored to its button. */
export const dockItem = (order: number): CSSProperties => ({
  position: 'relative', display: 'flex', alignItems: 'center', gap: 6, order,
});
