// Class-based CSS for the shared on-screen keyboard. A CSS STRING (not inline
// style objects) because the landscape condensation needs media queries, which
// cannot match inline styles. The component injects <style>{OSK_CSS}</style>
// itself; duplicate style tags when two OSK paths ever co-mount are harmless.
//
// Class-hook contract (fixed): .osk-sheet .osk-inline .osk-row .osk-row-scroll
// .osk-util .osk-key (.latched .armed .pressed .wide) .osk-more .osk-abc
// .osk-abc-input .osk-tabs .osk-tabgroup .osk-tab(.active) .osk-qrow
// .osk-shift(.once .caps) .osk-sec. The sheet's height is a constant derived
// from the QWERTY row count (see .osk-sheet) and does NOT vary by layer, so
// there is no per-layer hook to key off.
//
// touch-action:manipulation is ELEMENT-scoped to owned elements only — this is
// explicitly NOT a page-zoom/viewport change (that is the zoom workstream's).

import { STAGE_MENU_BAND } from './oskConstants';

export const OSK_CSS = `
/* ---- mobile bottom sheet: a FIXED screen-space region, never affected by the
   video-area zoom transform (which is scoped to .sv-video). Internal scroll is
   the defensive valve for accessibility force-zoom / short phones.

   ONE HEIGHT, ALWAYS — and it is the QWERTY layer's. The body used to size
   itself to whatever layer was showing, so every ABC ⇄ ?123 ⇄ per-OS switch
   resized the sheet under the user's thumb and shoved the picture (and every
   key) up or down: ?123 is one row shorter than ABC, and a per-OS body can be
   anything from one row to six. The height below is DERIVED from what the
   tallest layer needs — the tab strip plus the five QWERTY rows — so shorter
   layers simply leave the slack empty and taller per-OS bodies scroll inside
   it. Keep --osk-rows equal to the QWERTY body's row count (2 glyph rows +
   the shift/glyph/⌫ row + space + the action row); qwertyLayout.test.ts
   asserts that against ABC_ROWS so a new row cannot silently desync it. */
.osk-sheet {
  --osk-key-h: 44px;   /* .osk-key min-height */
  --osk-gap: 6px;      /* the column gap below */
  --osk-tabs-h: 34px;  /* .osk-tab min-height */
  --osk-pad: 8px;      /* the block padding below */
  --osk-rows: 5;       /* QWERTY body rows — the tallest layer */
  flex: 0 1 auto;
  height: calc(
    var(--osk-tabs-h)
    + var(--osk-rows) * (var(--osk-key-h) + var(--osk-gap))
    + var(--osk-pad) + max(var(--osk-pad), env(safe-area-inset-bottom))
  );
  max-height: 55%;
  overflow-y: auto; overscroll-behavior: contain;
  display: flex; flex-direction: column; gap: var(--osk-gap);
  padding: var(--osk-pad) max(var(--osk-pad), env(safe-area-inset-right)) max(var(--osk-pad), env(safe-area-inset-bottom)) max(var(--osk-pad), env(safe-area-inset-left));
  background: rgba(251,249,243,0.97); border-top: 1px solid var(--line);
  touch-action: manipulation;
}
/* ---- desktop inline footer ---- */
.osk-inline {
  display: flex; flex-direction: column; gap: 8px; padding: 10px;
  background: rgba(251,249,243,0.96); border-top: 1px solid var(--line);
}
.osk-row { display: flex; align-items: stretch; min-width: 0; }
/* Wide rows (F1..F12, 9-key NAV) scroll INSIDE their own container (repo rule);
   keys never shrink below touch-target size. */
.osk-row-scroll {
  display: flex; flex: 1 1 auto; gap: 6px; min-width: 0;
  overflow-x: auto; scrollbar-width: none; -webkit-overflow-scrolling: touch;
}
.osk-row-scroll::-webkit-scrollbar { display: none; }
/* Pinned utility cluster ([abc][▾]) OUTSIDE the scroll container on the last
   base row — always reachable regardless of row overflow, costs no extra row. */
.osk-util {
  display: flex; flex: 0 0 auto; gap: 6px; align-items: stretch;
  margin-left: 8px; padding-left: 8px; border-left: 1px solid var(--line);
}
/* min-height reads the sheet's token so the height formula and the keys it
   measures can never disagree; the fallback is for the desktop inline footer,
   which sets no tokens. */
.osk-key {
  flex: 0 0 auto; min-height: var(--osk-key-h, 44px); min-width: 44px; padding: 4px 12px;
  border-radius: 8px; border: 1px solid var(--line);
  background: #fffdf8; color: var(--ink); font-size: 13px;
  box-shadow: 0 1px 1px rgba(58,48,32,0.10);
  cursor: pointer; white-space: nowrap; touch-action: manipulation;
  user-select: none; -webkit-user-select: none;
}
.osk-key.latched { background: var(--accent-wash); border-color: var(--accent-line); color: var(--accent-ink); }
.osk-key.armed { background: rgba(178,58,44,0.14); border-color: rgba(178,58,44,0.55); color: var(--danger); }
/* Transient press flash — orthogonal to .latched/.armed (KB-3). */
.osk-key.pressed { background: var(--tint-2); border-color: var(--line-strong); box-shadow: none; }
.osk-key.wide { padding: 4px 26px; }
/* Long-press secondary glyph hint (KB-3): a faint corner superscript. */
.osk-sec {
  position: absolute; top: 2px; right: 5px; font-size: 9px; line-height: 1;
  opacity: 0.55; pointer-events: none;
}
/* ---- layer tab strip ([ABC][?123][OS] · [🌐][▾]) — persistent OSK chrome ---- */
.osk-tabs { display: flex; justify-content: space-between; gap: 6px; flex: 0 0 auto; }
.osk-tabgroup { display: flex; gap: 6px; }
.osk-tab {
  flex: 0 0 auto; min-height: var(--osk-tabs-h, 34px); padding: 4px 14px;
  border-radius: 8px; border: 1px solid var(--line);
  background: var(--tint-1); color: var(--ink-soft); font-size: 13px; font-weight: 600;
  cursor: pointer; white-space: nowrap; touch-action: manipulation;
  user-select: none; -webkit-user-select: none;
}
.osk-tab.active { background: var(--accent-wash); border-color: var(--accent-line); color: var(--accent-ink); }
/* ---- QWERTY equal-width rows: 10 columns divide the width evenly (NOT the
   horizontal-scroll .osk-row-scroll). Keys keep touch-target height; a min-width
   clamp + overflow-scroll is the documented fallback on very narrow (<360px)
   phones. Position:relative anchors the .osk-sec superscript. ---- */
.osk-qrow {
  display: flex; gap: 5px; align-items: stretch; min-width: 0;
  overflow-x: auto; scrollbar-width: none;
}
.osk-qrow::-webkit-scrollbar { display: none; }
.osk-qrow .osk-key {
  position: relative; flex: 1 1 0; min-width: 26px; padding: 4px 2px;
}
.osk-qrow .osk-key.wide { flex: 3 1 0; }
/* 3-state Shift: once = armed-for-next-glyph, caps = sticky. */
.osk-shift.once { background: var(--accent-wash); border-color: var(--accent-line); color: var(--accent-ink); }
.osk-shift.caps { background: var(--accent); border-color: var(--accent); color: var(--paper-raised); }
/* ---- docked free-text input (sheet variant): DIRECT child of .sv-root,
   docked at the very top (beside the stage-menu hamburger) so Android's IME
   overlay never covers it;
   z-59 keeps it under the stage menu (z-60/61) by decision. ---- */
.osk-abc {
  position: absolute; right: 8px; z-index: 59;
  left: calc(max(10px, env(safe-area-inset-left)) + ${STAGE_MENU_BAND}px);
  top: max(10px, env(safe-area-inset-top));
  display: flex; gap: 6px;
}
.osk-abc-input {
  flex: 1 1 auto; min-width: 0; font-size: 16px; padding: 10px 12px;
  border-radius: 8px; border: 1px solid var(--line-strong);
  background: rgba(255,253,248,0.97); color: var(--ink); outline: none;
  box-shadow: 0 6px 20px rgba(20,16,10,0.18);
}
.osk-inline .osk-abc-input { width: 100%; background: var(--paper-sunken); box-shadow: none; }
/* ---- landscape condensation: base rows only, tighter targets. The height
   formula is unchanged — only its inputs shrink, so the sheet still measures
   exactly one QWERTY and still never moves between layers. Scoped to
   .osk-sheet so a desktop (landscape monitor) inline OSK is untouched. ---- */
@media (orientation: landscape) {
  .osk-sheet {
    --osk-key-h: 40px;
    --osk-pad: 6px;
    /* Landscape leaves less to spare: allow the sheet its full QWERTY before
       the clamp forces it to scroll internally. */
    max-height: 70%;
  }
  .osk-sheet .osk-more { display: none; }
}
`;
