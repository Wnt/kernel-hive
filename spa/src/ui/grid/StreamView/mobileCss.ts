// Mobile OS-view layout CSS (two fixed regions: maximized stage / collapsible
// keyboard sheet — the top bar is gone, its controls live in the stage menu).
// Scoped by the data-mobile attribute that StreamView stamps on .sv-root from
// useMobileLayout. NOTE: no viewport-meta / page-level touch-action rules here —
// page pinch-zoom ownership belongs to the video-zoom workstream.

export const MOBILE_CSS = `
/* Kill pull-to-refresh / edge back-swipe over the whole OS view (T-2); the
   S.stage inline rule backstops the picture area. NOT touch-action:none here — the
   OSK sheet scroll relies on touch pan; the PICTURE (S.stage + S.video) already
   sets touch-action:none, which is what suppresses the browser double-tap-zoom
   where taps that should double-CLICK actually land. */
.sv-root[data-mobile="1"] { overscroll-behavior: none; }
`;
