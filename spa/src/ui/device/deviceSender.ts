// ============================================================================
//  deviceSender — presses on a drawn device key → paced key edges
//  ---------------------------------------------------------------------------
//  Pure logic (no DOM, injectable clock + timer) so the modifier and pacing
//  semantics are unit-testable. Rules it enforces:
//    - HOLD = HOLD: a press sends key-down, the release sends key-up. The guest
//      repeats a held key itself (the 9300's own 300 ms / 100 ms repeat), so
//      there is no client-side repeat here at all;
//    - a 'char' key sends the CHARACTER it shows for the current Shift/Chr
//      state (keymap contract rules 1 and 2), wrapped in the US Shift the wire
//      needs for it; with Ctrl, or Chr on a key whose Chr legend is a function
//      rather than a character, it sends the key's own keysym with the
//      modifier really held (rule 3: the device maps those chords by position);
//    - Shift / Ctrl / Chr are one-shot LATCHES when tapped, and real held
//      modifiers when held while another key is pressed (multi-touch). Chr held
//      alone for CHR_HOLD_MS goes down for real: on the 9300 that opens the
//      "Insert character" map (rule 4);
//    - PACING: at least `gapMs` (150 ms, contract rule 6) between any two key
//      edges on the wire — EKA2L1's key FIFO drops events that come faster;
//    - a key that is down on the wire is released exactly once, and a modifier
//      two held keys share goes up only when the last of them does.
// ============================================================================

import { charWire } from './deviceChars';
import type { DeviceDrawing, DeviceKey, ModRole } from './deviceTypes';

/** Structural subset of StreamControlHandle — all the engine needs. */
export interface DeviceSenderHandle {
  sendKey(keysym: number, down: boolean): void;
}

export const DEVICE_KEY_GAP_MS = 150;
const CHR_HOLD_MS = 500;
const SHIFT_L = 0xffe1;

interface DeviceSenderSnapshot {
  /** Keys under a finger or the mouse right now. */
  pressed: ReadonlySet<string>;
  /** Modifier roles latched for the next key. */
  latched: ReadonlySet<ModRole>;
}

export interface DeviceSender {
  press(id: string): void;
  release(id: string): void;
  snapshot(): DeviceSenderSnapshot;
  subscribe(cb: () => void): () => void;
  /** Drop queued edges and release every key this sender holds, now. */
  releaseAll(): void;
}

interface ModState {
  latched: boolean;
  heldBy: string | null;
  wasLatched: boolean;
  used: boolean;
  keysym: number;
  holdTimer: (() => void) | null;
  holdSent: boolean;
}

type Timer = (fn: () => void, ms: number) => () => void;

const defaultTimer: Timer = (fn, ms) => {
  const t = setTimeout(fn, ms);
  return () => clearTimeout(t);
};

/** The keysyms one press puts down, in order (released in reverse). */
export function resolvePress(
  key: DeviceKey,
  mods: Partial<Record<ModRole, number>>,
): number[] {
  const held = (roles: ModRole[]): number[] =>
    roles.flatMap((r) => (mods[r] != null ? [mods[r]] : []));
  if (key.kind === 'char' && mods.ctrl == null) {
    const shifted = mods.shift != null;
    const ch = mods.chr != null
      ? (shifted ? key.chrShift ?? key.chr : key.chr)
      : (shifted ? key.shift ?? key.base : key.base);
    const wire = ch ? charWire(ch) : null;
    if (wire) return wire.shift ? [SHIFT_L, wire.keysym] : [wire.keysym];
  }
  // Positional: the key's own keysym under the held modifiers. A printable
  // one goes out the way a US keyboard makes it (`numbersign` is Shift+3), so
  // the station's X server reports the right key to the device.
  const own = key.keysym >= 0x20 && key.keysym <= 0x7e ? charWire(String.fromCharCode(key.keysym)) : null;
  const tail = own ? (own.shift ? [SHIFT_L, own.keysym] : [own.keysym]) : [key.keysym];
  return [...new Set([...held(['ctrl', 'chr', 'shift']), ...tail])];
}

export function createDeviceSender(
  drawing: DeviceDrawing,
  getHandle: () => DeviceSenderHandle | null,
  opts?: { now?: () => number; timer?: Timer; gapMs?: number; chrHoldMs?: number },
): DeviceSender {
  const now = opts?.now ?? (() => performance.now());
  const timer = opts?.timer ?? defaultTimer;
  const gapMs = opts?.gapMs ?? DEVICE_KEY_GAP_MS;
  const chrHoldMs = opts?.chrHoldMs ?? CHR_HOLD_MS;
  const byId = new Map(drawing.keys.map((k) => [k.id, k]));

  const mods: Record<ModRole, ModState> = {
    shift: { latched: false, heldBy: null, wasLatched: false, used: false, keysym: 0, holdTimer: null, holdSent: false },
    ctrl: { latched: false, heldBy: null, wasLatched: false, used: false, keysym: 0, holdTimer: null, holdSent: false },
    chr: { latched: false, heldBy: null, wasLatched: false, used: false, keysym: 0, holdTimer: null, holdSent: false },
  };
  const pressed = new Map<string, number[]>(); // key id → keysyms it put down
  const refs = new Map<number, number>();       // keysym → presses holding it
  const queue: { keysym: number; down: boolean }[] = [];
  const onWire = new Set<number>();
  let lastSent = -Infinity;
  let pumpCancel: (() => void) | null = null;
  const listeners = new Set<() => void>();
  let snap: DeviceSenderSnapshot = { pressed: new Set(), latched: new Set() };

  const changed = () => {
    const latched = new Set<ModRole>();
    for (const r of Object.keys(mods) as ModRole[]) if (mods[r].latched) latched.add(r);
    const ids = new Set(pressed.keys());
    for (const r of Object.keys(mods) as ModRole[]) if (mods[r].heldBy) ids.add(mods[r].heldBy!);
    snap = { pressed: ids, latched };
    for (const cb of listeners) cb();
  };

  const pump = () => {
    pumpCancel = null;
    while (queue.length) {
      const t = now();
      const wait = lastSent + gapMs - t;
      if (wait > 0) { pumpCancel = timer(pump, wait); return; }
      const e = queue.shift()!;
      lastSent = t;
      if (e.down) onWire.add(e.keysym); else onWire.delete(e.keysym);
      getHandle()?.sendKey(e.keysym, e.down);
    }
  };
  const enqueue = (keysym: number, down: boolean) => {
    queue.push({ keysym, down });
    if (!pumpCancel) pump();
  };
  const hold = (keysym: number) => {
    const n = refs.get(keysym) ?? 0;
    refs.set(keysym, n + 1);
    if (n === 0) enqueue(keysym, true);
  };
  const unhold = (keysym: number) => {
    const n = refs.get(keysym) ?? 0;
    if (n <= 0) return;
    if (n === 1) { refs.delete(keysym); enqueue(keysym, false); } else refs.set(keysym, n - 1);
  };

  const pressMod = (key: DeviceKey, role: ModRole) => {
    const m = mods[role];
    if (m.heldBy) return;
    m.heldBy = key.id;
    m.wasLatched = m.latched;
    m.used = false;
    m.keysym = key.keysym;
    if (role === 'chr') {
      m.holdTimer = timer(() => {
        m.holdTimer = null;
        if (m.heldBy === key.id && !m.used) { m.holdSent = true; m.latched = false; hold(m.keysym); changed(); }
      }, chrHoldMs);
    }
  };

  const releaseMod = (key: DeviceKey, role: ModRole) => {
    const m = mods[role];
    if (m.heldBy !== key.id) return;
    m.heldBy = null;
    m.holdTimer?.();
    m.holdTimer = null;
    if (m.holdSent) { m.holdSent = false; unhold(m.keysym); m.latched = false; return; }
    m.latched = !m.used && !m.wasLatched;
  };

  return {
    press(id) {
      const key = byId.get(id);
      if (!key || pressed.has(id)) return;
      const role = drawing.mods[id];
      if (key.kind === 'mod' && role) { pressMod(key, role); changed(); return; }
      const active: Partial<Record<ModRole, number>> = {};
      for (const r of Object.keys(mods) as ModRole[]) {
        const m = mods[r];
        if (!m.latched && !m.heldBy) continue;
        active[r] = m.keysym;
        m.used = true;
        if (!m.heldBy) m.latched = false; // one-shot latch: spent by this key
      }
      // A Chr already down for real (held past CHR_HOLD_MS) stays down on its
      // own; the key must not stack a second press of it.
      const steps = resolvePress(key, active)
        .filter((ks) => !(mods.chr.holdSent && ks === mods.chr.keysym));
      pressed.set(id, steps);
      for (const ks of steps) hold(ks);
      changed();
    },
    release(id) {
      const key = byId.get(id);
      if (!key) return;
      const role = drawing.mods[id];
      if (key.kind === 'mod' && role) { releaseMod(key, role); changed(); return; }
      const steps = pressed.get(id);
      if (!steps) return;
      pressed.delete(id);
      for (let i = steps.length - 1; i >= 0; i--) unhold(steps[i]);
      changed();
    },
    snapshot: () => snap,
    subscribe(cb) {
      listeners.add(cb);
      return () => { listeners.delete(cb); };
    },
    releaseAll() {
      pumpCancel?.();
      pumpCancel = null;
      queue.length = 0;
      const h = getHandle();
      for (const ks of onWire) h?.sendKey(ks, false);
      onWire.clear();
      refs.clear();
      pressed.clear();
      for (const m of Object.values(mods)) {
        m.holdTimer?.();
        Object.assign(m, { latched: false, heldBy: null, used: false, holdTimer: null, holdSent: false });
      }
      changed();
    },
  };
}
