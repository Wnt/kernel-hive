import { useEffect, useRef, useState } from 'react';
import { S } from './styles';
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
//  It lives INSIDE .sv-stage on purpose. That is safe because guest input is
//  bound to the <video>/<canvas> element itself, and the pinch/gesture layer
//  ignores anything whose target is not the picture (useStreamInput) — a press
//  on these buttons can never reach the guest. The stopPropagation handlers
//  below are belt-and-braces for that contract, as on TouchControlBadge.
//
//  Desktop and touch share one menu. It carries no touch-only rows: the touch
//  model now follows the device on its own (input/pointerModeAuto), the gesture
//  legend shows itself once, and a stats overlay is a ⌘/Ctrl+N thing.
// ---------------------------------------------------------------------------

// Keep the guest from ever seeing a press meant for the menu.
const swallow = (e: { stopPropagation: () => void }) => e.stopPropagation();

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
  /** Type-in listing row — present only for tiles whose registry entry declares
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

  return (
    <>
      <div style={S.backWrap} onPointerDown={swallow} onPointerUp={swallow} onPointerMove={swallow}>
        <button style={S.menuBtn} onClick={run(exit)} title="Back to the gallery" aria-label="Back to the gallery">
          ←
        </button>
      </div>

      <div
        ref={wrapRef}
        style={S.menuWrap}
        onPointerDown={swallow}
        onPointerUp={swallow}
        onPointerMove={swallow}
      >
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
        </div>
      )}
      </div>
    </>
  );
}
