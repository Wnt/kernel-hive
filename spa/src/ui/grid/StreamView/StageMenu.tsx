import { useEffect, useRef, useState } from 'react';
import { S } from './styles';
import { DockedControl } from '../../DockedChrome';
import { useChromeDock } from '../../chromeDock';
import type { DemoState } from './useDemoProgram';

// ---------------------------------------------------------------------------
//  StageMenu — the exhibit's ONLY chrome: the back escape alone in the stage's
//  top-left corner, and the info + hamburger buttons in the top-right. There is
//  no top bar; the picture runs edge to edge and nothing sits between the
//  visitor and the guest until they ask for it.
//
//  THE TWO THINGS A VISITOR REACHES FOR MOST — what am I looking at, and how do
//  I get out — sit outside the hamburger rather than inside it, one tap instead
//  of two. Everything else (restore, fullscreen) stays behind the ☰ on every
//  device. On mobile the keyboard toggle instead lives as its own floating
//  button (KeyboardToggleBadge, bottom-right, mirroring the right-click badge
//  on the opposite corner) — a keyboard-having desktop keeps it in the menu.
//
//  It lives INSIDE .sv-stage when the picture fills the view. That is safe
//  because guest input is bound to the <video>/<canvas> element itself, and the
//  pinch/gesture layer ignores anything whose target is not the picture
//  (useStreamInput) — a press on these buttons can never reach the guest. The
//  stopPropagation in DockedControl is belt-and-braces for that contract.
//
//  ON THE LANDING PAGE'S MINI CANVAS THIS COMPONENT RENDERS NOTHING. There is
//  nowhere for "back" to go on a page that is not a station, and every ☰ item
//  (restore, demo, fullscreen, reload) is full-station chrome the mini display
//  never offers — the mobile keyboard toggle is the one exception, and it is
//  KeyboardToggleBadge's own row placement, not a menu item, so it is unaffected.
//  `useChromeDock()` is exactly "is there a dock", i.e. "is this the landing
//  page" (chromeDock.ts): every other mounting of StreamView (the full station
//  view, walk-in play) has no dock and keeps both buttons, floating in their
//  stage corners exactly as always.
//
//  Desktop and touch share one menu. It carries no touch-only rows: the touch
//  model now follows the device on its own (input/pointerModeAuto), the gesture
//  legend shows itself once, and a stats overlay is a ⌘/Ctrl+N thing.
// ---------------------------------------------------------------------------

export function StageMenu({
  dotColor, statusLabel, streamable, transport, fs, mobile,
  oskOpen, onToggleOsk,
  restoreState, restoreToGolden,
  demoLabel, demoState, demoTypeIn,
  toggleFullscreen, exit, posterAvailable, onOpenPoster,
}: {
  dotColor: string;
  statusLabel: string;
  streamable: boolean;
  transport: string;
  fs: boolean;
  mobile: boolean;
  oskOpen: boolean;
  onToggleOsk: () => void;
  restoreState: 'idle' | 'busy' | 'ok' | 'err';
  restoreToGolden: () => void;
  /** Type-in listing row — present only for stations whose registry entry declares
   *  a demoProgram (undefined label = no row at all). */
  demoLabel?: string;
  demoState: DemoState;
  demoTypeIn: () => void;
  toggleFullscreen: () => void;
  exit: () => void;
  posterAvailable: boolean;
  onOpenPoster?: () => void;
}) {
  const [open, setOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);
  // See the header comment: non-null only on the landing page's mini display,
  // where this whole component renders nothing.
  const docked = useChromeDock() != null;

  // Outside press closes. Escape deliberately does NOT: it belongs to the guest
  // (holding it is also the fullscreen-exit gesture), and stealing it here would
  // make the menu the one thing that eats a key the exhibit needs.
  useEffect(() => {
    if (!open) return;
    const onDocDown = (e: PointerEvent) => {
      if (wrapRef.current && !wrapRef.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('pointerdown', onDocDown);
    return () => document.removeEventListener('pointerdown', onDocDown);
  }, [open]);

  const run = (fn: () => void) => () => { fn(); setOpen(false); };
  const item = (enabled: boolean) => (enabled ? S.menuItem : { ...S.menuItem, ...S.menuItemOff });

  if (docked) return null;

  return (
    <>
      <DockedControl order={1} corner={S.backWrap}>
        <button style={S.menuBtn} onClick={run(exit)} title="Back to the gallery" aria-label="Back to the gallery">
          ←
        </button>
      </DockedControl>

      <DockedControl order={2} corner={S.menuWrap} elRef={wrapRef}>
      {posterAvailable && onOpenPoster && (
        <button
          style={S.menuBtn}
          onClick={run(onOpenPoster)}
          title="Read the full exhibit information"
          aria-label="Exhibit info"
        >
          ⓘ
        </button>
      )}

      <button
        style={{ ...S.menuBtn, ...(open ? S.btnOn : null) }}
        onClick={() => setOpen((v) => !v)}
        title={open ? 'Close the controls' : 'Controls'}
        aria-label="Controls"
        aria-expanded={open}
      >
        ☰
      </button>

      {open && (
        <div style={S.menuPanel} role="menu">
          <div style={S.menuHead}>
            <span style={{ ...S.dot, background: dotColor, color: dotColor, flex: '0 0 auto' }} />
            <span style={S.menuHeadText}>{statusLabel}</span>
          </div>

          {!mobile && streamable && (
            <button
              style={oskOpen ? { ...S.menuItem, ...S.btnOn } : S.menuItem}
              onClick={run(onToggleOsk)}
              title="On-screen keyboard — the per-OS keys, including Ctrl+Alt+Del"
            >
              {oskOpen ? '⌨ Keyboard · on' : '⌨ Keyboard'}
            </button>
          )}

          {demoLabel && (
            <button
              style={demoState === 'err' ? { ...S.menuItem, ...S.btnErr } : item(demoState !== 'typing')}
              onClick={run(demoTypeIn)}
              disabled={demoState === 'typing'}
              title="Type an era-authentic listing into the guest — you press ENTER to run it"
              aria-label={demoLabel}
            >
              {demoState === 'typing'
                ? '⌨ Typing…'
                : demoState === 'err'
                  ? '⚠ Typing failed'
                  : `⌨ ${demoLabel}`}
            </button>
          )}

          {transport === 'streamhost' && (
            <button
              style={restoreState === 'err' ? { ...S.menuItem, ...S.btnErr } : item(restoreState !== 'busy')}
              onClick={run(restoreToGolden)}
              disabled={restoreState === 'busy'}
              title="Reset this exhibit to its clean golden fixture (host-side, non-destructive)"
            >
              {restoreState === 'busy'
                ? '↺ Restoring…'
                : restoreState === 'ok'
                  ? '✓ Restored'
                  : restoreState === 'err'
                    ? '⚠ Restore failed'
                    : '↺ Restore to golden snapshot'}
            </button>
          )}

          {/* Entry only. In fullscreen the exits are the ones the browser
              already owns — Esc (held, while the system keyboard lock is on)
              or F11 — and the hint toast names them, so the menu does not
              carry a row for the state you are already in. */}
          {!fs && (
            <button style={S.menuItem} onClick={run(toggleFullscreen)} title="Go fullscreen">
              ⤢ Fullscreen
            </button>
          )}

          {/* Reload the page and reconnect the stream from scratch. A
              standalone/installed PWA has no browser reload button, so a wedged
              client needs one here. Distinct from Restore above: that resets the
              GUEST host-side, this resets the CLIENT. */}
          <button
            style={S.menuItem}
            onClick={run(() => window.location.reload())}
            title="Reload the page and reconnect the stream"
          >
            ⟳ Reload
          </button>
        </div>
      )}
      </DockedControl>
    </>
  );
}
