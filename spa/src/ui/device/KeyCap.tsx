// ============================================================================
//  KeyCap — one drawn device key: its outline, its legends, its pressed state
//  ---------------------------------------------------------------------------
//  Legend placement follows the device: a character key prints its base
//  legend at the left (letters as capitals), its Shift legend in the upper
//  right, and its Chr legend in the Chr colour; a named key prints its name,
//  an arrow key its arrow with the Chr function beside it.
// ============================================================================

import type { PointerEvent as ReactPointerEvent } from 'react';
import type { DeviceKey } from './deviceTypes';
import { DEVICE_KEY_INPUT_CLASS } from './deviceTypes';
import { GlyphMark } from './glyphs';

export const DEVICE_INK = 'var(--dev-ink)';
const DEVICE_CHR = 'var(--dev-chr)';

function Legends({ k }: { k: DeviceKey }) {
  const { x, y, w, h } = k.box;
  const ink = k.chrColour ? DEVICE_CHR : DEVICE_INK;
  const out = [];
  const mid = y + h * 0.63;
  if (k.label) {
    // Long names (the application row) centre in their key; short ones sit
    // at the left like the device's Esc / Caps / Ctrl.
    const small = k.label.length > 4 || h < 50;
    out.push(
      <text key="l" x={small ? x + w / 2 : x + 14} y={small ? y + h * 0.66 : mid}
        textAnchor={small ? 'middle' : 'start'} fontSize={small ? 23 : 29} fill={ink}>{k.label}</text>,
    );
  }
  if (k.glyph && k.cap !== 'none') {
    const gx = k.chrGlyph ? x + w * 0.3 : x + w / 2 - (k.glyph === 'enter' ? 0 : w * 0.18);
    const gy = k.glyph === 'enter' ? y + h * 0.5 : mid - 9;
    out.push(<GlyphMark key="g" name={k.glyph} x={gx} y={gy} size={k.glyph === 'enter' ? 33 : k.glyph === 'tab' ? 24 : 18} color={DEVICE_INK} />);
  }
  if (k.base) {
    const shown = k.shownBase ?? k.base;
    const letterLike = k.shownBase != null;
    const shiftShown = k.shift && k.shift !== shown;
    out.push(
      <text key="b" x={x + 14} y={letterLike ? mid : y + h - 15} fontSize={letterLike ? 30 : 29} fill={DEVICE_INK}>{shown}</text>,
    );
    if (shiftShown) {
      out.push(<text key="s" x={x + w - 13} y={y + 30} fontSize={25} textAnchor="end" fill={DEVICE_INK}>{k.shift}</text>);
    }
    if (k.chr) {
      out.push(shiftShown
        ? <text key="c" x={x + w * 0.44} y={y + h - 15} fontSize={25} fill={DEVICE_CHR}>{k.chr}</text>
        : <text key="c" x={x + w - 14} y={mid} fontSize={27} textAnchor="end" fill={DEVICE_CHR}>{k.chrShift ?? k.chr}</text>);
    }
  }
  if (k.chrGlyph) {
    const onChar = k.base != null;
    const gx = onChar ? x + w - 24 : k.glyph ? x + w * 0.7 : x + 30;
    const gy = onChar ? y + h - 22 : mid - 9;
    out.push(<GlyphMark key="cg" name={k.chrGlyph} x={gx} y={gy} size={onChar ? 12 : 15} color={DEVICE_CHR} />);
  }
  return <>{out}</>;
}

export function KeyCap({
  k, down, latched, shortcut, onDown, onUp, onPress, onRelease,
}: {
  k: DeviceKey;
  down: boolean;
  latched: boolean;
  shortcut: string;
  onDown: (e: ReactPointerEvent<SVGGElement>) => void;
  onUp: (e: ReactPointerEvent<SVGGElement>) => void;
  onPress: () => void;
  onRelease: () => void;
}) {
  const { x, y, w, h } = k.box;
  const joy = k.cap === 'none';
  const fill = down ? 'var(--dev-down)' : latched ? 'var(--dev-latched)' : joy ? 'transparent' : 'var(--dev-key)';
  return (
    <g
      data-key={k.id}
      className="dev-key"
      style={{ cursor: 'pointer', touchAction: 'none' }}
      onPointerDown={onDown}
      onPointerUp={onUp}
      onPointerCancel={onUp}
      onLostPointerCapture={onUp}
      onContextMenu={(e) => e.preventDefault()}
    >
      <title>{shortcut ? `${k.hint} — keyboard: ${shortcut}` : k.hint}</title>
      {joy ? (
        <rect x={x} y={y} width={w} height={h} rx={Math.min(w, h) / 2} fill={fill} opacity={down ? 0.9 : 1} />
      ) : k.outline ? (
        <path d={k.outline} transform={`translate(${x} ${y})`} fill={fill} stroke={DEVICE_INK} strokeWidth={2.6} />
      ) : (
        <rect x={x} y={y} width={w} height={h} rx={3} fill={fill} stroke={DEVICE_INK}
          strokeWidth={2.6} />
      )}
      <Legends k={k} />
      {/* A native focusable control for Tab order + Enter/Space activation.
          useStreamInput's global forwarder recognises this class and keeps
          forwarding every OTHER physical key (Esc, arrows, F-keys, letters)
          to the guest while it has focus — only this control's own Enter/
          Space are excluded there, so activating it never double-sends.
          Pointer edges still bubble to the drawn <g> above. */}
      <foreignObject x={x} y={y} width={w} height={h}>
        <input
          type="button"
          className={DEVICE_KEY_INPUT_CLASS}
          aria-label={k.label ?? k.hint}
          aria-pressed={latched || undefined}
          value=""
          onKeyDown={(e) => {
            if (e.key !== 'Enter' && e.key !== ' ') return;
            e.preventDefault();
            e.stopPropagation();
            if (!e.repeat) onPress();
          }}
          onKeyUp={(e) => {
            if (e.key !== 'Enter' && e.key !== ' ') return;
            e.preventDefault();
            e.stopPropagation();
            onRelease();
          }}
          onBlur={onRelease}
        />
      </foreignObject>
    </g>
  );
}
