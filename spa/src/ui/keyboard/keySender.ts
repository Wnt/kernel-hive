// ============================================================================
//  keySender — non-React send engine for the shared on-screen keyboard
//  ---------------------------------------------------------------------------
//  Pure logic (no DOM, injectable clock) so latch/macro/danger/repeat semantics
//  are unit-testable. Wire rules it enforces:
//    - non-printable keys go through handle.sendKey (NEVER sendKeyEvent — the
//      AltGr suppression there can swallow a synthetic AltRight);
//    - 'char' actions go through handle.typeText (correct synthetic Shift);
//    - repeat is client-side TAP-repeat (down+up per beat): a lost pointerup
//      can stop the interval but can never stick a guest key;
//    - dispose() releases ONLY the keys THIS sender holds down (latches +
//      in-flight macro steps) — it must never call releaseAllKeys(), which
//      would also flush keys a desktop user is physically holding through the
//      global forwarder (that net stays at the disconnect level).
// ============================================================================

import type { KeyDef } from './keyTypes';
import { DANGER_ARM_MS, REPEAT_DELAY_MS, REPEAT_INTERVAL_MS } from './oskConstants';

/** Structural subset of StreamControlHandle — all the engine needs. */
export interface KeySenderHandle {
  sendKey(keysym: number, down: boolean): void;
  typeText(text: string): void;
}

export type HapticKind = 'tap' | 'latch' | 'macro';

export interface KeySender {
  /** Main entry — fire on pointerdown. 'armed' = danger key awaiting confirm. */
  press(def: KeyDef): 'sent' | 'armed' | 'noop';
  /** Hold-to-repeat (only honors def.repeat === true); fires the first tap. */
  startRepeat(def: KeyDef): void;
  /** Wire to pointerup AND pointercancel AND lostpointercapture AND pointerleave. */
  stopRepeat(): void;
  /** The free-text path calls this after each delivered keystroke so one-shot
   *  latches release across the latch × free-text combination too. */
  noteExternalKeystroke(): void;
  /** Ids of currently-latched keys (the component's lit state). */
  latchedIds(): ReadonlySet<string>;
  /** Release all engaged latches (sends ups, reverse-engage order). */
  clearLatches(): void;
  /** stopRepeat + release ONLY ownDown keys. */
  dispose(): void;
}

export function createKeySender(
  getHandle: () => KeySenderHandle | null,
  opts?: { now?: () => number; onHaptic?: (kind: HapticKind) => void },
): KeySender {
  const now = opts?.now ?? (() => Date.now());
  const onHaptic = opts?.onHaptic;

  // Latches in ENGAGE order (released in reverse); ownDown = every keysym THIS
  // sender currently holds down (latches + transient macro steps).
  const engaged: KeyDef[] = [];
  const ownDown = new Set<number>();
  let armedId: string | null = null;
  let armedAt = 0;
  let repeatDelay: ReturnType<typeof setTimeout> | null = null;
  let repeatBeat: ReturnType<typeof setInterval> | null = null;
  let disposed = false;

  const send = (keysym: number, down: boolean) => {
    const h = getHandle();
    if (!h) return;
    h.sendKey(keysym, down);
    if (down) ownDown.add(keysym);
    else ownDown.delete(keysym);
  };

  const releaseLatches = () => {
    for (let i = engaged.length - 1; i >= 0; i--) send(engaged[i].keysym!, false);
    engaged.length = 0;
  };

  // One-shot: after any completed non-latch keystroke, engaged latches release.
  const afterKeystroke = () => { if (engaged.length) releaseLatches(); };

  const fireTap = (def: KeyDef, haptic: boolean) => {
    send(def.keysym!, true);
    send(def.keysym!, false);
    if (haptic) onHaptic?.('tap');
    afterKeystroke();
  };

  const fire = (def: KeyDef) => {
    switch (def.action) {
      case 'tap':
        fireTap(def, true);
        break;
      case 'char': {
        const h = getHandle();
        if (h && def.char) h.typeText(def.char);
        onHaptic?.('tap');
        afterKeystroke();
        break;
      }
      case 'latch': {
        const i = engaged.findIndex((d) => d.id === def.id);
        if (i >= 0) {
          send(def.keysym!, false);
          engaged.splice(i, 1);
        } else {
          send(def.keysym!, true);
          engaged.push(def);
          onHaptic?.('latch');
        }
        break;
      }
      case 'macro':
        for (const step of def.steps ?? []) send(step.keysym, step.down);
        onHaptic?.('macro');
        afterKeystroke();
        break;
    }
  };

  const press = (def: KeyDef): 'sent' | 'armed' | 'noop' => {
    if (disposed || !getHandle()) return 'noop';
    // Any press on a DIFFERENT key (or after the window) disarms a pending danger.
    if (armedId != null && (armedId !== def.id || now() - armedAt > DANGER_ARM_MS)) {
      const stale = armedId;
      armedId = null;
      if (stale === def.id) { armedId = def.id; armedAt = now(); return 'armed'; }
    }
    if (def.danger) {
      if (armedId !== def.id) { armedId = def.id; armedAt = now(); return 'armed'; }
      armedId = null; // confirmed inside the window — fall through and fire
    }
    fire(def);
    return 'sent';
  };

  const stopRepeat = () => {
    if (repeatDelay != null) { clearTimeout(repeatDelay); repeatDelay = null; }
    if (repeatBeat != null) { clearInterval(repeatBeat); repeatBeat = null; }
  };

  return {
    press,
    startRepeat(def: KeyDef) {
      if (disposed || def.action !== 'tap' || !def.repeat || !getHandle()) return;
      // A repeat key is a real keystroke: it must disarm a pending danger key
      // exactly like press() on a different key does (cross-key-disarm contract).
      armedId = null;
      stopRepeat();
      fireTap(def, true);
      repeatDelay = setTimeout(() => {
        repeatDelay = null;
        // Repeat beats skip the haptic — a 55ms pulse train is just buzz.
        repeatBeat = setInterval(() => fireTap(def, false), REPEAT_INTERVAL_MS);
      }, REPEAT_DELAY_MS);
    },
    stopRepeat,
    noteExternalKeystroke() { armedId = null; afterKeystroke(); },
    latchedIds() { return new Set(engaged.map((d) => d.id)); },
    clearLatches() { releaseLatches(); },
    dispose() {
      stopRepeat();
      for (const keysym of ownDown) {
        const h = getHandle();
        if (h) h.sendKey(keysym, false);
      }
      ownDown.clear();
      engaged.length = 0;
      disposed = true;
    },
  };
}
