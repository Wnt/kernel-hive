import { useEffect, useRef } from 'react';

/** Publishes the app bar's rendered height as `--appbar-h` on <html>.
 *
 * The bar is position:absolute over the grid, so the grid's top padding has to
 * clear it — and a fixed padding is a guess about how many rows the bar wraps
 * into. On a phone the title, the identity badge and the four nav tabs wrap
 * into three rows, and the guessed 96px left the search field hidden under
 * the bar (operator report, 2026-09-08). Measuring the bar with a
 * ResizeObserver makes the padding follow every wrap, font size and badge
 * length; the CSS reads `var(--appbar-h)` with a fallback for the first paint. */
export function useAppbarHeight() {
  const ref = useRef<HTMLElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const root = document.documentElement;
    const publish = () => root.style.setProperty('--appbar-h', `${Math.ceil(el.getBoundingClientRect().height)}px`);
    publish();
    const ro = new ResizeObserver(publish);
    ro.observe(el);
    return () => {
      ro.disconnect();
      root.style.removeProperty('--appbar-h');
    };
  }, []);
  return ref;
}
