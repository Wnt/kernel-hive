import { useEffect, useRef, useState } from 'react';

// How far (CSS px, after resistance) the finger must travel from the very top
// before releasing triggers a refresh, and the furthest the indicator travels.
const THRESHOLD_PX = 64;
const MAX_PULL_PX = 96;
// Beyond the top edge the content resists the finger, so a refresh is a
// deliberate long pull rather than a twitch at the top of normal scrolling.
const RESISTANCE = 0.5;

export interface PullToRefreshState {
  /** Indicator travel in CSS px, 0..MAX_PULL_PX. Drive the affordance's transform. */
  distance: number;
  /** Past the threshold — releasing now will refresh. */
  armed: boolean;
  /** A refresh has been committed and is in flight (the page is reloading). */
  refreshing: boolean;
}

/**
 * Touch pull-to-refresh for a scroll container. A standalone/installed PWA has no
 * browser chrome and therefore no native pull-to-refresh, so the grid supplies
 * its own: drag down from the very top of the list and release to refresh.
 *
 * Touch only — it binds no pointer/mouse/wheel listeners, so on a desktop it is
 * completely inert (the browser's own reload stays the answer there). It takes
 * over the gesture (preventDefault) ONLY once the finger is provably pulling DOWN
 * while the list sits at scrollTop 0; every other touch is left to native
 * scrolling untouched.
 *
 * `ready` gates the subscription: GridView renders a ref-less placeholder while
 * the collection loads, so the listeners must (re)attach once the real scroll
 * element is in the tree.
 */
export function usePullToRefresh(
  scrollRef: React.RefObject<HTMLElement | null>,
  onRefresh: () => void,
  ready: boolean,
): PullToRefreshState {
  const [distance, setDistance] = useState(0);
  const [armed, setArmed] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  // Latest onRefresh without re-subscribing the listeners on every render.
  const onRefreshRef = useRef(onRefresh);
  onRefreshRef.current = onRefresh;

  useEffect(() => {
    const el = scrollRef.current;
    if (!el || !ready) return;

    let startY: number | null = null; // touchstart Y captured while at the top, else null
    let active = false; // committed to a pull — native scroll is being suppressed
    let pulled = 0; // current resisted distance
    let done = false; // refresh fired; ignore everything until unmount

    const reset = () => {
      startY = null;
      active = false;
      pulled = 0;
      setDistance(0);
      setArmed(false);
    };

    const onStart = (e: TouchEvent) => {
      if (done || e.touches.length !== 1 || el.scrollTop > 0) {
        startY = null;
        return;
      }
      startY = e.touches[0].clientY;
      active = false;
      pulled = 0;
    };

    const onMove = (e: TouchEvent) => {
      if (done || startY === null) return;
      // Momentum carried us off the top after touchstart — abandon the pull.
      if (el.scrollTop > 0) {
        reset();
        return;
      }
      const dy = e.touches[0].clientY - startY;
      if (dy <= 0) {
        // Pulling up / not yet down: hand the gesture back to native scrolling.
        if (active) reset();
        return;
      }
      active = true;
      // Suppress the container's overscroll so only the indicator moves. The
      // listener is registered non-passive precisely so this is allowed.
      if (e.cancelable) e.preventDefault();
      pulled = Math.min(MAX_PULL_PX, dy * RESISTANCE);
      setDistance(pulled);
      setArmed(pulled >= THRESHOLD_PX);
    };

    const onEnd = () => {
      if (done || startY === null) {
        startY = null;
        return;
      }
      const commit = active && pulled >= THRESHOLD_PX;
      startY = null;
      active = false;
      if (commit) {
        done = true;
        setRefreshing(true);
        setArmed(false);
        setDistance(THRESHOLD_PX); // hold the spinner in place until the reload lands
        try {
          onRefreshRef.current();
        } catch {
          // A refresh that throws (e.g. a blocked reload) should not wedge the UI.
          done = false;
          setRefreshing(false);
          setDistance(0);
        }
      } else {
        reset();
      }
    };

    el.addEventListener('touchstart', onStart, { passive: true });
    el.addEventListener('touchmove', onMove, { passive: false });
    el.addEventListener('touchend', onEnd, { passive: true });
    el.addEventListener('touchcancel', onEnd, { passive: true });
    return () => {
      el.removeEventListener('touchstart', onStart);
      el.removeEventListener('touchmove', onMove);
      el.removeEventListener('touchend', onEnd);
      el.removeEventListener('touchcancel', onEnd);
    };
  }, [scrollRef, ready]);

  return { distance, armed, refreshing };
}
