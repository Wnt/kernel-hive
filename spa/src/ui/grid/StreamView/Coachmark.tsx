import type { CSSProperties } from 'react';

// ---------------------------------------------------------------------------
//  Coachmark — the touch legend. Auto-shows once on the first live station a phone
//  user opens, and is re-openable any time via the ⋯ menu's "Touch help". This is
//  a CONTROLLED component: the owner (useTouchControl) holds the open state + the
//  persisted seen-flag (coachmark.ts). Touch has no cursor and no tooltips, so the
//  gesture vocabulary is invisible until taught — this names each one.
// ---------------------------------------------------------------------------

// Keep in sync with the DIRECT touch model (input/touchGestures) + useStreamInput.
const DIRECT: [string, string][] = [
  ['Tap', 'click'],
  ['Drag', 'move / draw'],
  ['Double-tap', 'double-click'],
  ['⊕ Right-click, then tap', 'right-click'],
  ['S-Pen barrel', 'right-click'],
  ['Two-finger drag', 'scroll'],
  ['Pinch', 'zoom'],
  ['⌨', 'on-screen keyboard'],
];

// …and with the TRACKPAD model (input/trackpad + usePinchZoom), which is the
// default for a finger. A different vocabulary entirely — teaching the wrong one
// is worse than teaching none, since touch has no cursor and no tooltips to
// correct it.
const TRACKPAD: [string, string][] = [
  ['Drag anywhere', 'glide the crosshair'],
  ['Tap', 'click at the crosshair'],
  ['Tap, then hold + drag', 'drag / move a window'],
  ['⊕ Right-click, then tap', 'right-click'],
  ['Two fingers', 'zoom & pan the view'],
  ['S-Pen', 'switches to direct pointing'],
  ['⌨', 'on-screen keyboard'],
];

const OVERLAY: CSSProperties = {
  position: 'absolute', inset: 0, zIndex: 72,
  display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 20,
  background: 'radial-gradient(circle at 50% 45%, rgba(243,240,231,0.82), rgba(226,221,208,0.92))',
  pointerEvents: 'auto',
};
const CARD: CSSProperties = {
  display: 'flex', flexDirection: 'column', gap: 12, maxWidth: 340, width: '100%',
  padding: '18px 20px', borderRadius: 14,
  background: 'var(--paper-raised)', border: '1px solid var(--line)',
  boxShadow: 'var(--shadow-2)', color: 'var(--ink)',
};
const TITLE: CSSProperties = {
  fontSize: 16, fontWeight: 700, letterSpacing: 0.3,
};
const ROW: CSSProperties = {
  display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 16,
  fontSize: 14, lineHeight: 1.5,
};
const GESTURE: CSSProperties = { fontWeight: 600, whiteSpace: 'nowrap' };
const MEANS: CSSProperties = { color: 'var(--ink-muted)', textAlign: 'right' };
const GOT: CSSProperties = {
  marginTop: 4, minHeight: 44, padding: '8px 14px', borderRadius: 10,
  border: '1px solid var(--accent)', background: 'var(--accent)',
  color: 'var(--paper-raised)', fontSize: 15, fontWeight: 600, cursor: 'pointer',
};

export function Coachmark({
  open, onClose, trackpad = false,
}: { open: boolean; onClose: () => void; trackpad?: boolean }) {
  if (!open) return null;

  return (
    <div style={OVERLAY} onPointerDown={(e) => e.stopPropagation()} onClick={onClose}>
      <div style={CARD} onClick={(e) => e.stopPropagation()}>
        <div style={TITLE}>{trackpad ? 'Touch controls · trackpad' : 'Touch controls · direct'}</div>
        {(trackpad ? TRACKPAD : DIRECT).map(([gesture, means]) => (
          <div key={gesture} style={ROW}>
            <span style={GESTURE}>{gesture}</span>
            <span style={MEANS}>{means}</span>
          </div>
        ))}
        <button type="button" style={GOT} onClick={onClose}>Got it</button>
      </div>
    </div>
  );
}
