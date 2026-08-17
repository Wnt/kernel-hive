// ============================================================================
//  OnScreenKeyboard — THE single shared on-screen keyboard
//  ---------------------------------------------------------------------------
//  Shared keyboard for StreamView. Two variants:
//    - 'inline': today's footer look — always-visible autofocused free-text
//      input (keydown-proxy semantics, positional ä/ö via e.code kept) + the
//      per-OS key grid. Used by desktop StreamView.
//    - 'sheet': the mobile bottom region (max 1/3 viewport, see oskStyles).
//      Grid-only by default; free-text is explicit opt-in via [abc], which
//      docks a sentinel-diff proxy input BELOW THE TOP BAR (rendered as a
//      DIRECT child of .sv-root through the fragment — the sheet must not
//      wrap it, or the IME-dodging absolute positioning would break).
//
//  Key buttons fire on pointerdown with preventDefault — they steal no focus
//  and never summon the IME. Send semantics live in keySender (latch one-shot,
//  danger two-tap arm, tap-repeat); free-text mutation-diff in freeTextDiff.
// ============================================================================

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { XK, type StreamControlHandle } from '../../three/useStreamControl';
import type { KeyDef, KeyRow } from './keyTypes';
import { keyboardProfileFor } from './keyboardProfiles.data';
import { ABC_ROWS, SYM_ROWS, QFUNC, ACTION_ROW, type QRow, type QKey } from './qwertyLayout';
import { LayerTabs, type OskLayer } from './LayerTabs';
import { createKeySender, type KeySender } from './keySender';
import { diffProxyValue } from './freeTextDiff';
import { hapticTap } from './haptics';
import { DANGER_ARM_MS, LONGPRESS_MS, PROXY_SENTINEL } from './oskConstants';
import { OSK_CSS } from './oskStyles';

/** 3-state visual Shift: off → base glyphs, once → shifted (auto-reverts after
 *  the next glyph), caps → shifted (sticky). Indexes qwertyLayout base/shifted. */
type ShiftState = 'off' | 'once' | 'caps';

// Keys the sheet's proxy input handles on KEYDOWN: they never mutate the field,
// so the value-diff path cannot see them. Everything else — Backspace, all
// printables, 229/Unidentified — is deliberately NOT handled and NOT prevented;
// the mutation path owns it (no double-send by construction).
const ABC_TAPS: Record<string, number> = {
  ArrowLeft: XK.Left, ArrowRight: XK.Right, ArrowUp: XK.Up, ArrowDown: XK.Down,
  Tab: XK.Tab, Enter: XK.Return,
};

export function OnScreenKeyboard({
  handle,
  osId,
  variant,
  onRequestClose,
}: {
  handle: StreamControlHandle | null;
  osId: string;
  variant: 'sheet' | 'inline';
  onRequestClose?: () => void;
}) {
  const profile = useMemo(() => keyboardProfileFor(osId), [osId]);
  const handleRef = useRef(handle);
  handleRef.current = handle;

  const [, setBump] = useState(0); // re-render signal for sender-held latch state
  const [armedId, setArmedId] = useState<string | null>(null);
  const [abcOpen, setAbcOpen] = useState(false);
  // Body layer: the sheet opens straight on QWERTY (mobile wants letters now);
  // the desktop inline footer stays on the per-OS layer (real keyboard present).
  const [layer, setLayer] = useState<OskLayer>(variant === 'sheet' ? 'abc' : 'os');
  const [shift, setShift] = useState<ShiftState>('off');
  const [pressedId, setPressedId] = useState<string | null>(null);
  const armedTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lpRef = useRef<{ id: string; fired: boolean; timer: ReturnType<typeof setTimeout> } | null>(null);
  const abcRef = useRef<HTMLInputElement>(null);
  const inlineRef = useRef<HTMLInputElement>(null);

  const makeSender = useCallback(
    () => createKeySender(() => handleRef.current, {
      onHaptic: (kind) => hapticTap(kind === 'tap' ? 10 : 15),
    }),
    [],
  );
  const senderRef = useRef<KeySender | null>(null);
  if (!senderRef.current) senderRef.current = makeSender();

  // Unmount/collapse safety: release ONLY the keys this OSK holds (latches /
  // macro steps) — never releaseAllKeys. StrictMode-safe: the cleanup nulls the
  // ref so the second effect pass recreates a live sender.
  useEffect(() => {
    if (!senderRef.current) senderRef.current = makeSender();
    const sender = senderRef.current;
    return () => {
      sender.dispose();
      if (senderRef.current === sender) senderRef.current = null;
    };
  }, [makeSender]);

  // Handle CHANGE signal (the getter alone carries none): a reconnect swaps the
  // handle, so drop any latches engaged against the old channel.
  useEffect(() => {
    senderRef.current?.clearLatches();
    setBump((t) => t + 1);
  }, [handle]);

  useEffect(() => () => {
    if (armedTimer.current) clearTimeout(armedTimer.current);
    if (lpRef.current) clearTimeout(lpRef.current.timer);
  }, []);

  // One-shot Shift reverts after the next glyph/typing key; caps + off are sticky.
  const consumeShiftOnce = () => setShift((s) => (s === 'once' ? 'off' : s));
  const cycleShift = () => setShift((s) => (s === 'off' ? 'once' : s === 'once' ? 'caps' : 'off'));
  const shiftActive = shift !== 'off';

  const pressDef = (def: KeyDef) => {
    const sender = senderRef.current;
    if (!sender) return;
    if (def.repeat) {
      sender.startRepeat(def);
      // Mirror the engine's cross-key disarm: a repeat press clears armed state.
      if (armedTimer.current) { clearTimeout(armedTimer.current); armedTimer.current = null; }
      setArmedId(null);
    } else {
      const r = sender.press(def);
      if (armedTimer.current) { clearTimeout(armedTimer.current); armedTimer.current = null; }
      if (r === 'armed') {
        setArmedId(def.id);
        armedTimer.current = setTimeout(() => setArmedId(null), DANGER_ARM_MS);
      } else {
        setArmedId(null);
      }
    }
    setBump((t) => t + 1);
  };

  const endPress = () => {
    senderRef.current?.stopRepeat();
    setBump((t) => t + 1);
  };

  // ---- sheet free-text: sentinel + value-diff (see freeTextDiff.ts) ----------
  const resetProxy = () => {
    const el = abcRef.current;
    if (!el) return;
    el.value = PROXY_SENTINEL;
    try { el.setSelectionRange(el.value.length, el.value.length); } catch { /* unfocused */ }
  };

  const flushProxy = () => {
    const el = abcRef.current;
    if (!el) return;
    const { backspaces, text } = diffProxyValue(el.value);
    const h = handleRef.current;
    let sent = false;
    if (h) {
      for (let i = 0; i < backspaces; i++) {
        h.sendKey(XK.BackSpace, true);
        h.sendKey(XK.BackSpace, false);
        sent = true;
      }
      for (const c of text) {
        if (c === '\n' || c === '\r') { h.sendKey(XK.Return, true); h.sendKey(XK.Return, false); }
        else h.typeText(c); // ASCII-only (documented limitation; ä/ö are dropped)
        sent = true;
      }
    }
    if (sent) {
      senderRef.current?.noteExternalKeystroke();
      setBump((t) => t + 1); // latches may have released — re-derive lit state
    }
    resetProxy(); // idempotent: a bare sentinel then diffs to nothing
  };

  const onAbcInput = (e: React.FormEvent<HTMLInputElement>) => {
    if ((e.nativeEvent as InputEvent).isComposing) return; // wait for the commit
    flushProxy();
  };

  const onAbcKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Escape') return; // the global key handler owns Escape
    const ks = ABC_TAPS[e.key];
    if (ks == null) return; // mutation path owns it
    e.preventDefault();
    const h = handleRef.current;
    if (!h) return;
    h.sendKey(ks, true);
    h.sendKey(ks, false);
    senderRef.current?.noteExternalKeystroke();
    setBump((t) => t + 1); // latches may have released — re-derive lit state
  };

  useEffect(() => {
    if (!abcOpen) return;
    const el = abcRef.current;
    if (!el) return;
    el.value = PROXY_SENTINEL;
    el.focus(); // raises the IME
  }, [abcOpen]);

  // ---- inline free-text: today's keydown-proxy semantics, verbatim ----------
  useEffect(() => {
    if (variant === 'inline') inlineRef.current?.focus();
  }, [variant]);

  const onInlineKey = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Escape') return; // leave Escape to the global key handler
    const h = handleRef.current;
    if (!h) return;
    const ev = {
      key: e.key, location: e.location, code: e.code,
      getModifierState: (k: string) =>
        e.getModifierState(k as Parameters<typeof e.getModifierState>[0]),
    };
    h.sendKeyEvent(ev, true);
    h.sendKeyEvent(ev, false);
    e.preventDefault();
  };

  // ---- render ---------------------------------------------------------------
  const latched = senderRef.current?.latchedIds() ?? new Set<string>();

  // Long-press (KB-3): held past LONGPRESS_MS fires the key's secondary 'char'
  // and suppresses the normal tap. Wired ONLY for glyph keys (opts.longPress),
  // never a hold-repeat key — a key is EITHER long-press-secondary OR repeat.
  const endLongPress = () => {
    const lp = lpRef.current;
    lpRef.current = null;
    if (lp) clearTimeout(lp.timer);
    setPressedId(null);
    return lp;
  };

  const keyBtn = (
    def: KeyDef,
    opts?: { secondary?: KeyDef; afterSend?: () => void; longPress?: boolean },
  ) => {
    const deferred = opts?.longPress === true; // glyph keys fire on release
    const down = (e: React.PointerEvent) => {
      e.preventDefault(); // steal no focus / never summon the IME
      setPressedId(def.id);
      if (!deferred) { pressDef(def); opts?.afterSend?.(); return; }
      const secondary = opts?.secondary;
      // Only a key WITH a secondary suppresses the tap on a long hold; a plain
      // glyph held long still types normally on release.
      const timer = setTimeout(() => {
        if (!secondary) return;
        senderRef.current?.press(secondary);
        if (lpRef.current) lpRef.current.fired = true;
        opts?.afterSend?.();
        setBump((t) => t + 1);
      }, LONGPRESS_MS);
      lpRef.current = { id: def.id, fired: false, timer };
    };
    const up = () => {
      if (!deferred) { endPress(); setPressedId(null); return; }
      const lp = endLongPress();
      if (lp && !lp.fired) { pressDef(def); opts?.afterSend?.(); } // short tap
    };
    const cancel = () => {
      if (deferred) endLongPress();
      else { endPress(); setPressedId(null); }
    };
    return (
      <button
        key={def.id}
        type="button"
        className={[
          'osk-key',
          latched.has(def.id) ? 'latched' : '',
          armedId === def.id ? 'armed' : '',
          pressedId === def.id ? 'pressed' : '',
          def.wide ? 'wide' : '',
        ].filter(Boolean).join(' ')}
        title={def.hint}
        onPointerDown={down}
        onPointerUp={up}
        onPointerCancel={cancel}
        onPointerLeave={cancel}
        onLostPointerCapture={cancel}
        onContextMenu={(e) => e.preventDefault()}
      >
        {def.label}
        {opts?.secondary ? <span className="osk-sec">{opts.secondary.label}</span> : null}
      </button>
    );
  };

  // Per-OS layer (and desktop inline) rows — today's look, verbatim.
  const row = (r: KeyRow, i: number, more: boolean) => (
    <div key={(more ? 'm' : 'r') + i} className={more ? 'osk-row osk-more' : 'osk-row'}>
      <div className="osk-row-scroll">{r.map((d) => keyBtn(d))}</div>
    </div>
  );

  // ---- QWERTY layers (sheet only) -------------------------------------------
  const glyphBtn = (qk: QKey) =>
    keyBtn(shiftActive ? qk.shifted : qk.base, {
      secondary: qk.secondary,
      afterSend: consumeShiftOnce,
      longPress: true,
    });

  const shiftBtn = () => (
    <button
      key="q-shift"
      type="button"
      className={['osk-key', 'osk-shift', shift === 'once' ? 'once' : '', shift === 'caps' ? 'caps' : '']
        .filter(Boolean).join(' ')}
      title="Shift — tap: next letter · tap again: caps lock"
      onPointerDown={(e) => { e.preventDefault(); cycleShift(); }}
      onContextMenu={(e) => e.preventDefault()}
    >
      ⇧
    </button>
  );

  const qrow = (key: string, children: React.ReactNode) => (
    <div key={key} className="osk-qrow">{children}</div>
  );

  // Equal-width flex rows: glyph rows (last flanked by Shift + Backspace), a
  // space/enter row, then the persistent Ctrl/Alt/arrow action row.
  const qwertyBody = (rows: QRow[]) => {
    const last = rows.length - 1;
    return [
      ...rows.slice(0, last).map((r, i) => qrow('q' + i, r.map(glyphBtn))),
      // Shift-once reverts after the next GLYPH only (brief KB-3) — Backspace /
      // Space / Enter deliberately leave a pending one-shot Shift engaged.
      qrow('qlast', [
        shiftBtn(),
        ...rows[last].map(glyphBtn),
        keyBtn(QFUNC.backspace),
      ]),
      qrow('qspace', [
        keyBtn(QFUNC.space),
        keyBtn(QFUNC.enter),
      ]),
      qrow('qaction', ACTION_ROW.map((d) => keyBtn(d))),
    ];
  };

  return (
    <>
      <style>{OSK_CSS}</style>
      {variant === 'sheet' && abcOpen && (
        <div className="osk-abc">
          <input
            ref={abcRef}
            className="osk-abc-input"
            defaultValue={PROXY_SENTINEL}
            placeholder="type here → guest (ASCII)"
            onKeyDown={onAbcKeyDown}
            onInput={onAbcInput}
            onCompositionEnd={flushProxy}
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            enterKeyHint="send"
          />
          <button type="button" className="osk-key" onClick={() => setAbcOpen(false)} title="Close free-text input">
            ✕
          </button>
        </div>
      )}
      {/* No per-layer height hook: the sheet is a constant QWERTY-tall region
          (oskStyles), so switching layers never moves it. */}
      <div className={variant === 'sheet' ? 'osk-sheet' : 'osk-inline'}>
        {variant === 'sheet' && (
          <LayerTabs
            layer={layer}
            onLayer={setLayer}
            abcOpen={abcOpen}
            onToggleAbc={() => setAbcOpen((v) => !v)}
            onClose={onRequestClose}
          />
        )}
        {variant === 'inline' && (
          <input
            ref={inlineRef}
            className="osk-abc-input"
            placeholder="type here → guest"
            onKeyDown={onInlineKey}
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
          />
        )}
        {variant === 'inline' || layer === 'os' ? (
          <>
            {profile.rows.map((r, i) => row(r, i, false))}
            {(profile.moreRows ?? []).map((r, i) => row(r, i, true))}
          </>
        ) : (
          qwertyBody(layer === 'abc' ? ABC_ROWS : SYM_ROWS)
        )}
      </div>
    </>
  );
}
