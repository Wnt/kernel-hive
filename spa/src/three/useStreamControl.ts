//  useStreamControl — the streamhost SEND/control half.
//  Wraps a StreamClient and exposes the StreamControlHandle consumed by
//  StreamView and the shared on-screen keyboard.
//  Streamhost semantics:
//    - input: X11-keysym / KeyboardEvent calls are translated to XT set1
//      scancodes (guestQuirks) and sent over the StreamClient (datagram moves,
//      reliable buttons/keys/wheel). Mouse-move rides datagrams (GFN tiering);
//      the server coalesces, so there is no send-queue decimation to do.
//    - control plane: streamhost is single-viewer implicit-host — requestControl/
//      releaseControl are no-ops, isHost() is always true, clipboard is local-only
//      (a documented parity gap until the Stage-1 control messages land).
//    - latency lever: there is NO jitter buffer (per-frame uni-streams) — the
//      whole point — so setJitterBufferTargetMs/setJitterAuto keep the HUD slider
//      bound but only record a value; getStats reports it back.
//    - mouse: the client is guest-agnostic — it always sends correctly-scaled
//      ABSOLUTE guest px; the daemon converts to relative for PS/2 stations and
//      applies any per-station calibration offset. (No client-side cursor fixups.)
//    - G1 fold-in kept: a win9x boot-modal auto-dismiss on first connect.

import type {
  StreamBannerState,
  StreamClient,
  StreamExitReason,
  StreamMetrics,
} from './streamClient';
import { isComposedChar, isMacPlatform } from './composeKey';
import {
  codeToScancode,
  keysymToScancode,
  asciiToScancode,
  quirksFor,
  SHIFT_L_SCANCODE,
  type GuestQuirks,
} from './guestQuirks';

// XK keysym table + keysymFromKeyboardEvent: split out to
// streamClient/keysym.ts (ts-src 600-line hard cap).
import { XK, keysymFromKeyboardEvent } from './streamClient/keysym';
export { XK };

export interface StreamResolution {
  w: number;
  h: number;
}

export interface StreamControlState {
  channelOpen: boolean;
  bannerState?: StreamBannerState | null;
  exitReason?: StreamExitReason | null;
  stalled?: boolean;
  decoderError?: string | null;
  host: boolean;
  locked: boolean;
  memberId: string | null;
  resolution: StreamResolution;
  jitterBufferTargetMs: number;
  jitterAuto: boolean;
  audioEnabled: boolean;
}

export interface StreamStats {
  rttMs: number | null;
  fps: number | null;
  jitterBufferMs: number | null;
  videoJitterMs: number | null;
  jitterTargetMs: number | null;
  jitterAuto: boolean;
  audioEnabled: boolean;
  sendBufferedAmount: number | null;
  movesCoalesced: number;
  frameWidth: number | null;
  frameHeight: number | null;
  streamhost?: StreamMetrics | null;
}

type TouchPhase = 'start' | 'move' | 'end';

/** Imperative input/control API for StreamView and its keyboard/input helpers. */
export interface StreamControlHandle {
  sendMouseMove(guestX: number, guestY: number): void;
  sendMouseMoveRel?(dx: number, dy: number): void;
  /** Diagnostic move-datagram wire counters (input/pointerTelemetry). Optional
   *  so non-streamhost handles need not implement it. */
  moveWireSnapshot?(): { sent: number; rejected: number; desiredSizeMin: number | null };
  sendMouseButton(button: number, down: boolean, guestX?: number, guestY?: number): void;
  sendWheel(dx: number, dy: number): void;
  sendKey(keysym: number, down: boolean): void;
  sendKeyEvent(e: { key: string; location?: number; code?: string; getModifierState?: (k: string) => boolean }, down: boolean): number | null;
  typeText(text: string): void;
  releaseAllKeys(): void;
  sendTouch(phase: TouchPhase, guestX: number, guestY: number): void;
  requestControl(): void;
  releaseControl(): void;
  setClipboard(text: string): void;
  getClipboard(): Promise<string>;
  setJitterBufferTargetMs(ms: number): void;
  setJitterAuto(enabled: boolean): void;
  getStats(): Promise<StreamStats>;
  setAudioEnabled(on: boolean): void;
  isAudioEnabled(): boolean;
  uvToGuest(u: number, v: number, flipV?: boolean): { x: number; y: number };
  getState(): StreamControlState;
  isConnected(): boolean;
  isHost(): boolean;
  getResolution(): StreamResolution;
  onStateChange(cb: (s: StreamControlState) => void): () => void;
  dispose(): void;
}

export interface StreamControllerConfig {
  /** live resolution getter (kept current by the hook from decoded frame size). */
  getResolution: () => StreamResolution;
  /** OS id — selects the boot-dismiss guest-quirks profile. */
  osId?: string;
  /** initial (thin) jitter target in ms, used only when autoJitter is false. */
  jitterBufferTargetMs?: number;
  /** self-tuning flag mirror (no real buffer to tune; default true). */
  autoJitter?: boolean;
}

const JITTER_FLOOR_MS = 15;
const BOOT_DISMISS_DELAY_MS = 1200; // let the desktop paint before we tap keys
// ABR report cadence (Section 2.3): the client scores + reports every 100 ms; the
// EWMA windows (m=16/8/4) turn that into ~1.6s/0.8s/0.4s smoothing. Each tick also
// fires a type-9 RTT ping so the next report has a fresh sample.
const STATS_REPORT_MS = 100;

export function createStreamController(
  client: StreamClient,
  config: StreamControllerConfig,
): {
  handle: StreamControlHandle;
  /** call once when the transport reaches 'live' (drives boot-modal dismiss). */
  notifyConnected: () => void;
  /** push a fresh channelOpen snapshot (the hook calls this on connect/close). */
  setConnected: (open: boolean) => void;
} {
  const { getResolution } = config;
  const quirks: GuestQuirks = quirksFor(config.osId);
  const autoJitter = config.autoJitter !== false;

  const state: StreamControlState = {
    channelOpen: client.isConnected(),
    bannerState: client.getBannerState(), // 'good' by default (no banner shown)
    exitReason: client.getExitReason(),   // null until a drop is classified (Item 3)
    stalled: client.getFrameStalled(),    // false until the frame watchdog latches (Item 4)
    decoderError: client.getLastDecodeError(), // feeds the 'decoder failing' chip
    host: true,           // streamhost is single-viewer implicit host
    locked: false,
    memberId: null,
    resolution: getResolution(),
    jitterBufferTargetMs: autoJitter ? JITTER_FLOOR_MS : (config.jitterBufferTargetMs ?? 50),
    jitterAuto: autoJitter,
    audioEnabled: client.isAudioEnabled(),
  };

  const listeners = new Set<(s: StreamControlState) => void>();
  const emit = () => {
    state.resolution = getResolution();
    const snap = { ...state, resolution: { ...state.resolution } };
    for (const cb of listeners) { try { cb(snap); } catch { /* not ours */ } }
  };

  // Scancodes we believe are down (for release-all on blur / dispose).
  const downScancodes = new Set<number>();
  // e.code keys we emitted as a self-contained tap (see sendCharEvent) — their
  // paired keyup must be swallowed so the guest sees exactly one make/break.
  const tappedCodes = new Set<string>();
  // AltGr-composing modifier keys (Right-Alt / Windows' synthetic Left-Ctrl) we
  // swallowed on keydown — their keyup must be swallowed too.
  const suppressedMods = new Set<string>();
  let lastClipboard = '';
  let disposed = false;
  let bootDismissed = false;
  const movesCoalesced = 0; // always 0 for streamhost (datagram moves, no backlog)

  const res = () => getResolution();

  // ---- input ----
  // The client is GUEST-AGNOSTIC: it always emits correctly-scaled ABSOLUTE guest
  // pixels (already mapped by grid letterbox.clientToGuest). There is NO
  // client-side PS/2 "cursor correction"
  // any more — the DAEMON owns the abs→device mapping per station.env SH_POINTER:
  //   • abs stations  → Mouse.SetAbsPosition(x,y)
  //   • rel stations  → last-position delta → rel_motion(dx,dy)  (win9x/os2/…)
  // and any per-station calibration offset (e.g. tinycore's tablet hotspot) is a
  // server-side affine in input.rs, so it benefits abs AND rel stations uniformly.
  const sendMouseMove = (x: number, y: number) => {
    if (disposed) return;
    client.sendMoveAbs(x, y);
  };

  // RELATIVE motion for pointer-locked rel-pointer stations (qnx/freedos/msdoswin1):
  // ship the raw movementX/Y delta as a type=4 DIRECT RelMotion datagram. The
  // daemon (input.rs case 4) forwards it straight to Mouse.RelMotion — NO homing
  // bridge — so QEMU's PS/2 mouse advances 1:1 with no clamped mega-delta, and the
  // guest renders its own cursor. Absolute stations never call this (see StreamView).
  const sendMouseMoveRel = (dx: number, dy: number) => {
    if (disposed) return;
    client.sendMoveRel(dx, dy);
  };

  const sendMouseButton = (button: number, down: boolean, x?: number, y?: number) => {
    if (disposed) return;
    // The position rides IN the button record (one atomic, ordered, reliable
    // message) rather than as a separate datagram the network could reorder
    // behind it or drop — that race pressed at the previous point and then slid
    // the cursor under a held button, which the guest reads as a drag.
    //
    // The move datagram is still sent when a point is given, because it is what
    // actually STREAMS motion: warpd stations apply cursor position through their
    // agent channel and never look at a button's coordinates, and the daemon's
    // button-guard clock keys off it. Sending both is not redundant work on the
    // guest — the sinks that use the carried point coalesce the duplicate.
    if (x != null && y != null) client.sendMoveAbs(x, y);
    client.sendButton(button, down, x, y);
  };

  const sendWheel = (dx: number, dy: number) => {
    if (!disposed) client.sendWheel(dx, dy);
  };

  const rawScancode = (code: number, down: boolean) => {
    // `code` is a set1 scancode (0xE0xx for extended keys) — sent verbatim.
    if (down) downScancodes.add(code);
    else downScancodes.delete(code);
    client.sendKeyScancode(code, down);
  };

  const sendKey = (keysym: number, down: boolean) => {
    if (disposed || !keysym || keysym < 8) return;
    const sc = keysymToScancode(keysym);
    if (sc == null) return;
    rawScancode(sc, down);
  };

  // XT set1 scancodes for the composing modifiers, released when stripping a
  // composed character (Windows reports AltGr as Ctrl_L + Alt_R; Linux as Alt_R;
  // macOS composes with either Option, which is Alt_L or Alt_R).
  const CTRL_L = 0x1d, CTRL_R = 0xe01d, ALT_R = 0xe038, ALT_L = 0x38;
  const SHIFT_R_SCANCODE = 0x36;
  const guestShiftDown = () => downScancodes.has(SHIFT_L_SCANCODE) || downScancodes.has(SHIFT_R_SCANCODE);

  // FI/EU keyboard fix — PRINTABLE keys resolve from KeyboardEvent.key (the
  // layout+modifier-RESOLVED character) → US set1 scancode + synthetic Shift, so a
  // Finnish (or any non-US) layout produces the intended glyph on a US-layout guest.
  // Returns true if the event was fully handled here.
  const sendCharEvent = (
    e: { key: string; code?: string },
    down: boolean,
    altGr: boolean,
  ): boolean => {
    const s = asciiToScancode(e.key);
    if (!s) return false; // non-ASCII (ä/ö/å, dead-key composites): fall back to .code
    const code = e.code ?? e.key;

    // keyup of a key that was forwarded as a real make/break (matching-shift path).
    if (!down) { rawScancode(s.code, false); return true; }

    // AltGr layer (FI | \ @ $ { } …): the browser also delivers the raw Ctrl+Alt
    // that composes AltGr; release any leaked ones so the US guest sees a clean
    // Shift+key, never Ctrl+Alt+key.
    if (altGr) {
      for (const sc of [CTRL_L, CTRL_R, ALT_R, ALT_L]) {
        if (downScancodes.has(sc)) { downScancodes.delete(sc); client.sendKeyScancode(sc, false); }
      }
    }

    const needShift = s.shift;
    if (needShift === guestShiftDown() && !altGr) {
      // Shift already correct, nothing to strip → forward a real make/break so
      // key-HOLD still works (letters/digits/gaming/space and matching symbols).
      rawScancode(s.code, true);
      return true;
    }

    // Shift must be toggled and/or AltGr stripped → self-contained tap now, and
    // swallow the paired keyup (symbol keys are never held for gaming).
    const shifts = needShift
      ? [SHIFT_L_SCANCODE]                                              // press a synthetic Shift
      : [SHIFT_L_SCANCODE, SHIFT_R_SCANCODE].filter((sc) => downScancodes.has(sc)); // release held Shift(s)
    for (const sc of shifts) client.sendKeyScancode(sc, needShift);
    client.sendKeyScancode(s.code, true);
    client.sendKeyScancode(s.code, false);
    for (const sc of shifts) client.sendKeyScancode(sc, !needShift);
    tappedCodes.add(code);
    return true;
  };

  const sendKeyEvent = (
    e: { key: string; location?: number; code?: string; getModifierState?: (k: string) => boolean },
    down: boolean,
  ) => {
    const ks = keysymFromKeyboardEvent(e);
    if (disposed) return ks;

    const code = e.code ?? e.key;
    // Swallow the keyup half of a tap emitted on keydown by sendCharEvent.
    if (!down && tappedCodes.has(code)) { tappedCodes.delete(code); return ks; }

    const mod = (name: string) =>
      typeof e.getModifierState === 'function' && e.getModifierState(name);
    const altGr = mod('AltGraph');
    // AltGr's composing modifiers must NEVER reach a US guest: a bare Right-Alt tap
    // opens app menus (Win9x) and Ctrl+Alt corrupts the resolved char. Swallow them
    // while the AltGr layer is active; clearAltGrLeak (in sendCharEvent) is the net
    // for Windows' synthetic Ctrl whose keydown predates the AltGraph flag.
    if ((code === 'AltRight' || code === 'ControlLeft') && (altGr || suppressedMods.has(code))) {
      if (down) suppressedMods.add(code); else suppressedMods.delete(code);
      return ks;
    }
    const single = Array.from(e.key).length === 1;
    // macOS Option is a COMPOSE modifier, not a shortcut modifier, on every
    // non-US layout: a Finnish Mac puts $ @ \ | { } [ ] ~ behind it ($ is
    // Option+4). macOS never sets AltGraph, so these arrived here as a real
    // Alt chord and went out positionally — the guest saw Alt+4, not '$'.
    //
    // Deliberately limited to ASCII results. Option+<letter> on a Mac resolves to
    // a non-ASCII glyph (å, ∂, ƒ) that asciiToScancode rejects anyway, so
    // Alt+letter menu shortcuts keep the positional path untouched.
    const composed = isComposedChar(e.key, {
      altHeld: !!mod('Alt'),
      altGr: !!altGr,
      isMac: isMacPlatform(),
    });

    // Real modifier chords (Ctrl+C, Alt+F, Meta+…) stay POSITIONAL so shortcuts and
    // muscle-memory are untouched. Composing is NOT a real chord — it produces a
    // char — so exclude it (on Windows AltGr also sets the Control/Alt flags).
    const realCtrl = mod('Control') && !composed;
    const realAlt = mod('Alt') && !composed;
    const meta = mod('Meta');

    // PRINTABLE char path: a single resolved character, not a real Ctrl/Alt/Meta
    // shortcut, not a numpad key (keep numpad distinct for guests that care).
    if (single && !realCtrl && !realAlt && !meta && (e.location ?? 0) !== 3) {
      if (sendCharEvent(e, down, composed)) return ks;
    }

    // POSITIONAL path: physical KeyboardEvent.code → set1 (Enter/Tab/Esc/arrows/
    // F-keys/modifiers/numpad, letter-shortcuts, and any char we can't ASCII-map).
    const sc = codeToScancode(e.code);
    if (sc != null) rawScancode(sc, down);
    else if (ks != null) sendKey(ks, down); // fallback for odd keys w/o a code
    return ks;
  };

  const typeText = (text: string) => {
    if (disposed) return;
    for (const ch of text) {
      const s = asciiToScancode(ch);
      if (!s) continue;
      if (s.shift) client.sendKeyScancode(SHIFT_L_SCANCODE, true);
      client.sendKeyScancode(s.code, true);
      client.sendKeyScancode(s.code, false);
      if (s.shift) client.sendKeyScancode(SHIFT_L_SCANCODE, false);
    }
  };

  const releaseAllKeys = () => {
    for (const sc of downScancodes) client.sendKeyScancode(sc, false);
    downScancodes.clear();
  };

  const sendTouch = (phase: TouchPhase, x: number, y: number) => {
    switch (phase) {
      case 'start': sendMouseButton(0, true, x, y); break;
      case 'move': sendMouseMove(x, y); break;
      case 'end': sendMouseButton(0, false, x, y); break;
    }
  };

  // ---- win9x boot-modal auto-dismiss (once, on first connect) ----
  // Note: "first connect" means the first live frame of EVERY controller mount —
  // this fires ~1.2s after connecting on every visit, not just on cold boots.
  const notifyConnected = () => {
    if (!quirks.bootDismiss || bootDismissed || disposed) return;
    bootDismissed = true;
    window.setTimeout(() => {
      if (disposed) return;
      // Esc dismisses the "restore settings?" prompt; Enter accepts any default OK.
      client.sendKeyScancode(0x01, true); client.sendKeyScancode(0x01, false); // Esc
      window.setTimeout(() => {
        if (disposed) return;
        client.sendKeyScancode(0x1c, true); client.sendKeyScancode(0x1c, false); // Enter
      }, 250);
    }, BOOT_DISMISS_DELAY_MS);
  };

  const setConnected = (open: boolean) => {
    if (state.channelOpen === open) return;
    state.channelOpen = open;
    if (!open) downScancodes.clear();
    emit();
  };

  // ---- control plane (single-viewer implicit host; mostly no-ops) ----
  const requestControl = () => { /* implicit host — nothing to request */ };
  const releaseControl = () => { /* implicit host — nothing to release */ };
  const setClipboard = (text: string) => {
    lastClipboard = text;
    try { void navigator.clipboard?.writeText?.(text); } catch { /* denied */ }
  };
  const getClipboard = async (): Promise<string> => {
    try {
      if (navigator.clipboard?.readText) {
        const t = await navigator.clipboard.readText();
        if (t) return t;
      }
    } catch { /* denied */ }
    return lastClipboard;
  };

  // ---- latency lever (no real jitter buffer — record only) ----
  const setJitterBufferTargetMs = (ms: number) => {
    state.jitterAuto = false;
    state.jitterBufferTargetMs = ms;
    emit();
  };
  const setJitterAuto = (enabled: boolean) => {
    if (state.jitterAuto === enabled) return;
    state.jitterAuto = enabled;
    if (enabled) state.jitterBufferTargetMs = JITTER_FLOOR_MS;
    emit();
  };

  // ---- ABR report loop (Section 2): MEASURE + REPORT every 100 ms ----------
  //  client.tickStats() rolls the interval accumulators into rates, runs the
  //  client-local `el` scorer, emits the T_STATS feedback datagram, and fires a
  //  fresh RTT ping. We then reflect the (locally-computed) banner state into the
  //  control state so StreamView's GFN-style banner reacts without a round-trip.
  const statsTimer = window.setInterval(() => {
    if (disposed) return;
    try { client.tickStats(); } catch { /* transport gone */ }
    // Reflect the client-local banner, structured exit reason (Item 3), and the
    // idle-frame-stall flag (Item 4) into control state in one shot — emit once if
    // any of the three changed so StreamView reacts without a server round-trip.
    const banner = client.getBannerState();
    const reason = client.getExitReason();
    const stalled = client.getFrameStalled();
    const decErr = client.getLastDecodeError();
    if (banner !== state.bannerState || reason !== state.exitReason
        || stalled !== state.stalled || decErr !== state.decoderError) {
      state.bannerState = banner;
      state.exitReason = reason;
      state.stalled = stalled;
      state.decoderError = decErr; // 'decoder-failed' chip copy (banner above)
      emit();
    }
  }, STATS_REPORT_MS);

  const getStats = async (): Promise<StreamStats> => {
    const s = client.getStats();
    const m = client.getMetrics();
    return {
      rttMs: s.rttMs,
      fps: s.fps || null,
      jitterBufferMs: 0,               // no jitter buffer by design
      videoJitterMs: null,             // N/A on WebTransport
      jitterTargetMs: state.jitterBufferTargetMs,
      jitterAuto: state.jitterAuto,
      audioEnabled: state.audioEnabled,
      sendBufferedAmount: s.sendBufferedAmount,
      movesCoalesced,
      frameWidth: s.guestW || null,
      frameHeight: s.guestH || null,
      streamhost: m,                   // codec/ABR overlay snapshot (Section 4)
    };
  };

  // ---- audio ----
  const setAudioEnabled = (on: boolean) => {
    if (on === state.audioEnabled) { if (on) client.setAudioEnabled(true); return; }
    state.audioEnabled = on;
    client.setAudioEnabled(on);
    emit();
  };

  // ---- coordinate helper: guest pixels from a UV hit ----
  const clamp01 = (n: number) => (n < 0 ? 0 : n > 1 ? 1 : n);
  const uvToGuest = (u: number, v: number, flipV = true) => {
    const { w, h } = res();
    const x = Math.round(clamp01(u) * (Math.max(1, w) - 1));
    const yv = flipV ? 1 - v : v;
    const y = Math.round(clamp01(yv) * (Math.max(1, h) - 1));
    return { x, y };
  };

  const handle: StreamControlHandle = {
    sendMouseMove,
    sendMouseMoveRel,
    moveWireSnapshot: () => client.moveWireSnapshot(),
    sendMouseButton,
    sendWheel,
    sendKey,
    sendKeyEvent,
    typeText,
    releaseAllKeys,
    sendTouch,
    requestControl,
    releaseControl,
    setClipboard,
    getClipboard,
    setJitterBufferTargetMs,
    setJitterAuto,
    getStats,
    setAudioEnabled,
    isAudioEnabled: () => state.audioEnabled,
    uvToGuest,
    getState: () => ({ ...state, resolution: { ...res() } }),
    isConnected: () => state.channelOpen,
    isHost: () => state.host,
    getResolution: () => ({ ...res() }),
    onStateChange: (cb) => { listeners.add(cb); return () => listeners.delete(cb); },
    dispose: () => {
      if (disposed) return;
      disposed = true;
      try { releaseAllKeys(); } catch { /* transport gone */ }
      clearInterval(statsTimer);
      listeners.clear();
    },
  };

  return { handle, notifyConnected, setConnected };
}
