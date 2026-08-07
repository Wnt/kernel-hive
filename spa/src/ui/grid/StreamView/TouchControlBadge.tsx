import type { CSSProperties } from 'react';
import type { ArmMode } from '../../../input/touchGestures';
import type { TouchBadgeState } from './useTouchGestures';

// ---------------------------------------------------------------------------
//  TouchControlBadge (T-1) — the always-visible "what will my next tap do?"
//  affordance. Touch input has no cursor and no hover, so a hidden armed mode is
//  a trap: this button in the stage's bottom-left both TOGGLES a one-shot
//  right-click arm and REFLECTS its live state. Long-press → right-click and
//  double-tap → double-click still work with nothing armed; the toggle is for
//  users who can't hold a long-press or want an explicit, deliberate action.
//
//  It arms the STYLUS too, and there it is not a convenience but the only route
//  to a right-button DRAG: the S-Pen barrel exposes no pointer-button bit on this
//  device and Android eats its press outright during a drag, so the barrel can
//  deliver a right CLICK and nothing longer. Arming makes the next pen contact a
//  real right press-drag-release — which is what a spring-loaded Motif menu (the
//  IRIX root menu) needs to be dragged onto an item.
// ---------------------------------------------------------------------------

const WRAP: CSSProperties = {
  position: 'absolute',
  left: 'max(10px, env(safe-area-inset-left))',
  bottom: 'max(10px, env(safe-area-inset-bottom))',
  zIndex: 58,
  display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 6,
  pointerEvents: 'auto',
};
const BTN: CSSProperties = {
  display: 'inline-flex', alignItems: 'center', gap: 6,
  minHeight: 44, padding: '6px 12px', borderRadius: 999,
  border: '1px solid var(--line)', background: 'rgba(251,249,243,0.9)',
  backdropFilter: 'blur(8px)', color: 'var(--ink)', fontSize: 13, fontWeight: 600,
  cursor: 'pointer', whiteSpace: 'nowrap', boxShadow: '0 6px 20px rgba(20,16,10,0.22)',
};
const ON: CSSProperties = {
  background: 'var(--accent)', borderColor: 'var(--accent)', color: 'var(--paper-raised)',
};

// Keep the badge from ever leaking a tap into the guest pointer forwarder.
const swallow = (e: { stopPropagation: () => void }) => e.stopPropagation();

export function TouchControlBadge({
  state,
  onArm,
}: {
  state: TouchBadgeState;
  onArm: (mode: ArmMode) => void;
}) {
  const { armMode } = state;
  const toggle = (mode: ArmMode) => () => onArm(armMode === mode ? 'none' : mode);

  return (
    <div style={WRAP} onPointerDown={swallow}>
      <button
        type="button"
        style={armMode === 'right-click' ? { ...BTN, ...ON } : BTN}
        aria-pressed={armMode === 'right-click'}
        onPointerDown={swallow}
        onClick={toggle('right-click')}
        title="Arm a one-shot right-click for your next tap or pen stroke — hold and drag it to use a spring-loaded menu"
      >
        {armMode === 'right-click' ? '⊕ Right-click · armed' : '⊕ Right-click'}
      </button>
    </div>
  );
}
