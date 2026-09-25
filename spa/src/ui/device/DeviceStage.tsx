// ============================================================================
//  DeviceStage — a station page presented as a drawing of the device
//  ---------------------------------------------------------------------------
//  Fills the exhibit stage with the drawing (as wide as the stage allows at
//  the drawing's aspect, in both orientations), puts the live picture —
//  `children`: StreamView's <video>/<canvas> and its connect overlays — in
//  the drawn display, and makes every drawn key a control through
//  deviceSender. The physical keyboard keeps working through StreamView's own
//  global forwarder; this component only LIGHTS the drawn key a physical key
//  corresponds to, so a visitor learns the mapping by typing.
// ============================================================================

import {
  useEffect, useMemo, useRef, useState, useSyncExternalStore,
  type CSSProperties, type PointerEvent as ReactPointerEvent, type ReactNode,
} from 'react';
import { createDeviceSender, type DeviceSenderHandle } from './deviceSender';
import type { DeviceDrawing } from './deviceTypes';
import { KeyCap } from './KeyCap';

const THEME: CSSProperties & Record<`--${string}`, string> = {
  '--dev-ink': 'var(--ink)',
  '--dev-muted': 'var(--ink-muted)',
  // The 9300 prints its Chr legends blue.
  '--dev-chr': '#2c62a6',
  '--dev-body': 'var(--paper-raised)',
  '--dev-key': '#fffdf8',
  '--dev-down': '#cfd6df',
  '--dev-latched': 'rgba(44, 98, 166, 0.18)',
};

const NOTE_PX = 30;

const codeLabel = (code: string): string =>
  code.replace(/^Key|^Digit/, '').replace(/^Arrow/, '').replace('ContextMenu', 'Menu');

export function DeviceStage({
  drawing, handle, children,
}: {
  drawing: DeviceDrawing;
  handle: DeviceSenderHandle | null;
  children: ReactNode;
}) {
  const handleRef = useRef(handle);
  handleRef.current = handle;
  const sender = useMemo(() => createDeviceSender(drawing, () => handleRef.current), [drawing]);
  const snap = useSyncExternalStore(sender.subscribe, sender.snapshot);
  const pointers = useRef(new Map<number, string>());
  const [echo, setEcho] = useState<ReadonlySet<string>>(new Set());

  // Nothing may stay down in the guest when the page goes away or loses focus.
  useEffect(() => {
    const flush = () => { pointers.current.clear(); sender.releaseAll(); };
    const onHide = () => { if (document.hidden) flush(); };
    window.addEventListener('blur', flush);
    document.addEventListener('visibilitychange', onHide);
    return () => {
      window.removeEventListener('blur', flush);
      document.removeEventListener('visibilitychange', onHide);
      flush();
    };
  }, [sender]);

  // Physical keyboard → light the drawn key (display only; never sends).
  useEffect(() => {
    const byCode = new Map<string, string>();
    for (const k of drawing.keys) for (const c of k.codes ?? []) byCode.set(c, k.id);
    const set = (e: KeyboardEvent, on: boolean) => {
      const id = byCode.get(e.code);
      if (!id) return;
      setEcho((prev) => {
        if (prev.has(id) === on) return prev;
        const next = new Set(prev);
        if (on) next.add(id); else next.delete(id);
        return next;
      });
    };
    const down = (e: KeyboardEvent) => set(e, true);
    const up = (e: KeyboardEvent) => set(e, false);
    const clear = () => setEcho(new Set());
    window.addEventListener('keydown', down);
    window.addEventListener('keyup', up);
    window.addEventListener('blur', clear);
    return () => {
      window.removeEventListener('keydown', down);
      window.removeEventListener('keyup', up);
      window.removeEventListener('blur', clear);
    };
  }, [drawing]);

  const onDown = (id: string) => (e: ReactPointerEvent<SVGGElement>) => {
    if (e.button !== 0 && e.pointerType === 'mouse') return;
    e.preventDefault();
    try { e.currentTarget.setPointerCapture(e.pointerId); } catch { /* not capturable */ }
    pointers.current.set(e.pointerId, id);
    sender.press(id);
  };
  const onUp = (e: ReactPointerEvent<SVGGElement>) => {
    const id = pointers.current.get(e.pointerId);
    if (id == null) return;
    pointers.current.delete(e.pointerId);
    sender.release(id);
  };

  const { w: W, h: H } = drawing.viewBox;
  const sc = drawing.screen;
  const pct = (v: number, of: number) => `${(v / of) * 100}%`;

  return (
    <div className="dev-stage" style={{ ...THEME, ...S.fill }}>
      <div
        role="group"
        aria-label={drawing.name}
        style={{
          ...S.device,
          width: `min(calc(100cqw - 16px), calc((100cqh - ${NOTE_PX + 8}px) * ${W} / ${H}))`,
          aspectRatio: `${W} / ${H}`,
        }}
      >
        <svg viewBox={`0 0 ${W} ${H}`} style={S.svg} fontFamily="var(--font-ui)">
          <drawing.Outline />
          {drawing.keys.map((k) => {
            const role = drawing.mods[k.id];
            return (
              <KeyCap
                key={k.id}
                k={k}
                down={snap.pressed.has(k.id) || echo.has(k.id)}
                latched={!!role && snap.latched.has(role)}
                shortcut={(k.codes ?? []).map(codeLabel).join(' / ')}
                onDown={onDown(k.id)}
                onUp={onUp}
              />
            );
          })}
        </svg>
        <div
          className="dev-screen"
          style={{ ...S.screen, left: pct(sc.x, W), top: pct(sc.y, H), width: pct(sc.w, W), height: pct(sc.h, H) }}
        >
          {children}
        </div>
      </div>
      <p style={S.note}>{drawing.shortcutNote}</p>
    </div>
  );
}

const S: Record<string, CSSProperties> = {
  fill: {
    position: 'absolute', inset: 0, containerType: 'size', display: 'flex', flexDirection: 'column',
    alignItems: 'center', justifyContent: 'center', gap: 6,
  },
  device: { position: 'relative', flex: '0 0 auto' },
  svg: { position: 'absolute', inset: 0, width: '100%', height: '100%', display: 'block', overflow: 'visible' },
  // The picture sits exactly on the drawn panel; overlays inside it (connect
  // spinner, power-on) are absolutely placed and stay within the panel.
  screen: { position: 'absolute', overflow: 'hidden', background: '#15171a' },
  note: {
    margin: 0, maxWidth: 'calc(100cqw - 32px)', minHeight: NOTE_PX - 6, fontSize: 12, lineHeight: 1.35,
    color: 'var(--ink-muted)', textAlign: 'center', fontFamily: 'var(--font-ui)',
  },
};
