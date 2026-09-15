import type { CSSProperties } from 'react';
import { DockedControl } from '../../DockedChrome';

// ---------------------------------------------------------------------------
//  KeyboardToggleBadge — the on-screen-keyboard opener. It sits in the stage's
//  bottom-right corner whenever the keyboard is closed, mirroring
//  TouchControlBadge (bottom-left, the right-click arm) on the opposite side —
//  or, on a touch-capable landing page mini canvas, beside that same badge in
//  the control row under the picture, which is where the keyboard opens too.
//  Mounted only where a coarse pointer might need it (StreamView's touchChrome
//  gate, touchChromeGate.ts): on the full station view a keyboard-having
//  desktop visitor keeps the toggle inline in the stage menu's dropdown
//  instead; on the desktop mini display a real keyboard already types straight
//  into the guest, so neither this badge nor a menu item is needed there.
//  StreamView unmounts this once the keyboard opens — closing it is the
//  keyboard sheet's own job, so there is no "on" state to render here.
// ---------------------------------------------------------------------------

const CORNER: CSSProperties = {
  position: 'absolute',
  right: 'max(10px, env(safe-area-inset-right))',
  bottom: 'max(10px, env(safe-area-inset-bottom))',
  zIndex: 58,
  display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 6,
  pointerEvents: 'auto',
};
const BTN: CSSProperties = {
  display: 'inline-flex', alignItems: 'center', gap: 6,
  minHeight: 44, padding: '6px 12px', borderRadius: 999,
  border: '1px solid var(--line)', background: 'rgba(251,249,243,0.9)',
  backdropFilter: 'blur(8px)', color: 'var(--ink)', fontSize: 13, fontWeight: 600,
  cursor: 'pointer', whiteSpace: 'nowrap', boxShadow: '0 6px 20px rgba(20,16,10,0.22)',
};

export function KeyboardToggleBadge({ onOpen }: { onOpen: () => void }) {
  return (
    <DockedControl order={4} corner={CORNER}>
      <button
        type="button"
        style={BTN}
        onPointerDown={(e) => e.stopPropagation()}
        onClick={onOpen}
        title="On-screen keyboard — the per-OS keys, including Ctrl+Alt+Del"
      >
        ⌨ Keyboard
      </button>
    </DockedControl>
  );
}
