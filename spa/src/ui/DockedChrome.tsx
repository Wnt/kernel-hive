import { type CSSProperties, type ReactNode, type RefObject } from 'react';
import { createPortal } from 'react-dom';
import { dockItem, useChromeDock } from './chromeDock';

// ---------------------------------------------------------------------------
//  DockedChrome — the three wrappers that put a StreamView's chrome where
//  chromeDock.ts says it goes. Split from the contract itself only because a
//  module may not export both components and constants and stay hot-reloadable.
// ---------------------------------------------------------------------------

// Chrome must never leak a press into the guest pointer forwarder. Every docked
// control swallows the same three events, so the rule lives here once instead
// of being repeated (and eventually forgotten) at each corner.
const swallow = (e: { stopPropagation: () => void }) => e.stopPropagation();


/**
 * A stage-corner control. Docked, it is an item in the control row under the
 * canvas; undocked, it keeps `corner` — the absolute positioning it has always
 * had. Either way the wrapper is the same element, so a ref taken on it (the
 * stage menu's outside-press detector) stays valid across a switch.
 */
export function DockedControl({
  order,
  corner,
  elRef,
  children,
}: {
  /** Reading order in the docked control row. */
  order: number;
  /** Where this control floats when it is NOT docked. */
  corner: CSSProperties;
  elRef?: RefObject<HTMLDivElement | null>;
  children: ReactNode;
}) {
  const dock = useChromeDock();
  const into = dock?.controls ?? null;
  const node = (
    <div
      ref={elRef}
      style={into ? dockItem(order) : corner}
      onPointerDown={swallow}
      onPointerUp={swallow}
      onPointerMove={swallow}
    >
      {children}
    </div>
  );
  return into ? createPortal(node, into) : node;
}

/**
 * A floating status notice (the connection banner, the device/stall chips).
 * Docked it joins the control row; undocked it renders exactly where it did.
 * The notice keeps its own style — merge DOCK_FLOW into it when docked.
 */
export function DockedNotice({ order, children }: { order: number; children: ReactNode }) {
  const dock = useChromeDock();
  const into = dock?.controls ?? null;
  return into ? createPortal(<div style={dockItem(order)}>{children}</div>, into) : <>{children}</>;
}

/** The on-screen keyboard's home: its own region below the control row, so a
 *  full QWERTY never has to come out of the picture's height. */
export function DockedKeys({ children }: { children: ReactNode }) {
  const dock = useChromeDock();
  return dock?.keys ? createPortal(children, dock.keys) : <>{children}</>;
}
