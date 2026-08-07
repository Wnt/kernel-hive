// Cross-browser Fullscreen API shim — extracted verbatim from StreamView.tsx.
//
// The old code called `el.requestFullscreen?.()` and swallowed the promise with
// `.catch(() => {})`. Two silent failure modes hid behind that:
//   1. WebKit (older Safari / iPad) exposes ONLY the `webkit`-prefixed methods,
//      so `el.requestFullscreen` is undefined → the optional-chain is a no-op
//      and NOTHING happens — no error, no fullscreen. The app then just shows
//      its own absolute-inset-0 layout (the "CSS cinema" look) with the browser
//      chrome still on screen.
//   2. A genuine rejection (permissions-policy / iframe without allow=fullscreen
//      / not user-activated) was hidden by the empty catch, so it was impossible
//      to diagnose in the field.
// These helpers pick the unprefixed OR webkit method, and callers now LOG every
// rejection instead of hiding it.
type FsElement = HTMLElement & {
  webkitRequestFullscreen?: (options?: FullscreenOptions) => Promise<void> | void;
};
type FsDocument = Document & {
  webkitFullscreenElement?: Element | null;
  webkitExitFullscreen?: () => Promise<void> | void;
};

/** The element currently in fullscreen (unprefixed or webkit), or null. */
export function currentFullscreenElement(): Element | null {
  const d = document as FsDocument;
  return document.fullscreenElement ?? d.webkitFullscreenElement ?? null;
}

/** Enter fullscreen on `el`, rejecting (never silently no-op) when unsupported. */
export function enterFullscreen(el: HTMLElement): Promise<void> {
  const e = el as FsElement;
  const req = el.requestFullscreen ?? e.webkitRequestFullscreen;
  if (!req) return Promise.reject(new Error('Fullscreen API is unavailable in this browser'));
  // navigationUI:'hide' asks the UA to drop the URL/nav affordance where honored.
  return Promise.resolve(req.call(el, { navigationUI: 'hide' } as FullscreenOptions));
}

/** Exit fullscreen (unprefixed or webkit). */
export function leaveFullscreen(): Promise<void> {
  const d = document as FsDocument;
  const ex = document.exitFullscreen ?? d.webkitExitFullscreen;
  if (!ex) return Promise.resolve();
  return Promise.resolve(ex.call(document));
}
