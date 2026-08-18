/* eslint-disable react-hooks/exhaustive-deps -- effects are lifted VERBATIM from
   StreamView with byte-identical dependency arrays; the refs/setters arrive as
   stable params, which defeats the rule's static ref/setState stability inference
   (the original in-component code passed the rule clean). rules-of-hooks (the
   correctness rule) stays enforced. */
import { useEffect, type Dispatch, type RefObject, type SetStateAction } from 'react';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import { clientToGuest } from '../letterbox';
import { lockAllSystemKeys, unlockSystemKeys, needsPreventDefault, isDebugToggle } from './keyboardLock';
import { isTouchDevice } from './env';
import { pinched, resolveMoveSamples, supportsRawUpdate } from '../../../input/moveSamples';
import { createTapQuantiser } from '../../../input/tapQuantiser';
import { allowPenHover } from '../../../input/penHover';
import { penPress, penRelease } from '../../../input/penContact';
import { contextMenuAction, convertContactToRight, synthRightClick } from '../../../input/penRightClick';
import { HoverAccumulator, StrokeAccumulator, type WireSnapshot } from '../../../input/pointerTelemetry';
import { logClientEvent } from '../../../three/clientDebug';
import { hapticTap } from '../../keyboard/haptics';
import type { TouchGestureController } from './useTouchGestures';
import type { Vec2 } from './types';

// The keyboard + pointer + wheel + pinch-zoom event machinery — the contiguous
// run of effects (#50–55) lifted verbatim out of StreamView. Ordering, deps and
// listener wiring are byte-for-byte identical to the god-component.
/** A pointer that left the surface for at least this long gets a re-home hint
 *  on re-entry (relative-pointer bridge); shorter excursions are edge brushes. */
const REENTER_HINT_MS = 1000;

export function useStreamInput({
  streamable, inputSuspended, releaseHeldButtons, control, live, touchExhibit, mouseCapture, acquireLock,
  directCanvas, revealChrome, setDebug, touch, pointerRel, presentFill,
  controlRef, fsRef, lockedRef, vcursorRef, lastGuestRef, pressedButtonsRef, penHoverRef,
  videoRef, canvasRef, trackpadRef, stageRef,
}: {
  streamable: boolean;
  inputSuspended: boolean;
  releaseHeldButtons: (target?: StreamControlHandle | null) => void;
  control: StreamControlHandle | null;
  live: boolean;
  /** The EXHIBIT is a touchscreen device (android/postmarketOS/Sailfish) — NOT
   *  a claim about the visitor's hardware (that is env.isTouchDevice()). A
   *  stylus on a desktop exhibit has pointerType 'pen' and touchExhibit=false,
   *  so it takes the MOUSE path below, never the touch recognizer. */
  touchExhibit: boolean;
  mouseCapture: boolean;
  acquireLock: () => void;
  directCanvas: boolean;
  revealChrome: () => void;
  setDebug: Dispatch<SetStateAction<boolean>>;
  // T-1: the single-finger touch recognizer sink (long-press / double-tap /
  // drag-lock). Replaces the raw control.sendTouch mapping in the touch path.
  touch: TouchGestureController;
  // T-3: rel-pointer station flag + the live trackpad-mode mirror. In direct mode the
  // touch path applies the T-4 fat-finger offset + drives the loupe; in trackpad
  // mode neither (the controller owns the relative / virtual-cursor mapping).
  pointerRel: boolean;
  // ERA-CORRECT 4:3 PRESENTATION (presentAspect.ts): the picture is displayed in
  // a display-aspect box and STRETCHED to fill it (object-fit:fill). The pointer
  // element's rect IS that box, so the letterbox map runs in fill mode (u/v span
  // the whole box back to guest pixels — resolution-based, stretch-independent).
  presentFill: boolean;
  controlRef: RefObject<StreamControlHandle | null>;
  fsRef: RefObject<boolean>;
  lockedRef: RefObject<boolean>;
  vcursorRef: RefObject<Vec2 | null>;
  lastGuestRef: RefObject<Vec2 | null>;
  pressedButtonsRef: RefObject<Set<number>>;
  // T-5 pen-hover throttle clock.
  penHoverRef: RefObject<number>;
  videoRef: RefObject<HTMLVideoElement | null>;
  canvasRef: RefObject<HTMLCanvasElement | null>;
  // The live trackpad-model mirror + the STAGE the picture sits in. In trackpad
  // mode the whole stage is pointing surface — a trackpad reads deltas, so the
  // letterbox bars around the picture work exactly as well as the picture, and on
  // a portrait phone showing a 4:3 exhibit those bars are most of the screen.
  // DIRECT pointing cannot use them (a bar has no guest pixel under it), so it
  // stays confined to the picture element, as it was when the listeners lived
  // there.
  trackpadRef: RefObject<boolean>;
  stageRef: RefObject<HTMLDivElement | null>;
}) {
  // ---- GFN keyboard.lock: full System Keyboard Lock so Ctrl/Cmd+Arrow, Esc, F11
  //  and every other OS/browser shortcut reach the guest instead of macOS/Chrome.
  //  Best-effort baseline lock (inert until fullscreen); re-asserted on FS-enter by
  //  relockKeyboard() and released on FS-exit. See lockAllSystemKeys() above.
  useEffect(() => {
    if (!streamable || !window.isSecureContext) return;
    lockAllSystemKeys();
    return () => {
      unlockSystemKeys();
      // Dropping keyboard-lock can swallow a trailing keyup (esp. Esc) — flush held
      // scancodes so nothing stays down through the teardown.
      try { controlRef.current?.releaseAllKeys(); } catch { /* noop */ }
    };
  }, [streamable]);

  // ---- DEBUG OVERLAY TOGGLE (Cmd/Ctrl+N) — global, all transports -----------
  //  Capture phase + stopImmediatePropagation so it beats other global
  //  keydown forwarder (reached later in the capture walk).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!isDebugToggle(e)) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      setDebug((v) => !v);
      // Reveal the floating chrome briefly so the user can reach Exit/Fullscreen.
      if (document.fullscreenElement) revealChrome();
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, []);

  // ---- GLOBAL KEYBOARD -> guest (capture phase) -----------------------------
  //  Fullscreen adds GFN-style hold-to-exit Esc and stronger preventDefault.
  useEffect(() => {
    if (!streamable || inputSuspended) {
      if (inputSuspended) {
        try { controlRef.current?.releaseAllKeys(); } catch { /* noop */ }
        releaseHeldButtons();
      }
      return;
    }
    const isFormField = (t: EventTarget | null) => {
      const el = t as HTMLElement | null;
      return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (isDebugToggle(e)) return;                                   // owned by the debug toggle
      const h = controlRef.current;
      if (e.key === 'Escape') {
        // GFN HOLD-TO-EXIT model. Stop the event here so App.tsx's own grid-Esc
        // listener can't also close the stream on a single tap.
        e.preventDefault();
        e.stopImmediatePropagation();
        // A SHORT Esc is forwarded to the guest (menus/dialogs get it). When
        // keyboard.lock(['Escape']) is active in fullscreen the browser holds
        // pointer lock and delivers the short tap here; a press-and-HOLD (~1s) is
        // consumed by the UA to exit fullscreen (which drops the lock) — the
        // natural "leave cinema mode" gesture. Short Escape presses never leave
        // the OS view; the on-screen Exit button returns to the grid.
        if (!isFormField(e.target)) h?.sendKeyEvent(e, true); // Esc DOWN → guest
        return;
      }
      if (isFormField(e.target)) return; // OSK / toolbar inputs own their keys
      if (!h) return;
      h.sendKeyEvent(e, true);
      if (needsPreventDefault(e, fsRef.current)) e.preventDefault();
    };
    const onKeyUp = (e: KeyboardEvent) => {
      const h = controlRef.current;
      if (!h) return;
      // ALWAYS forward key-UP — never gate on isDebugToggle/isFormField here. A
      // key-up for a key the guest never saw down is a harmless no-op (the handle
      // tracks downScancodes), but a MISSING up leaves the key stuck down in the
      // guest (repeating ^[ / a stuck 'n' after Cmd+N). Symmetry beats precision.
      h.sendKeyEvent(e, false);
      if (needsPreventDefault(e, fsRef.current)) e.preventDefault();
    };
    const onBlur = () => {
      try { controlRef.current?.releaseAllKeys(); } catch { /* noop */ }
      releaseHeldButtons();
    };
    window.addEventListener('keydown', onKeyDown, true);
    window.addEventListener('keyup', onKeyUp, true);
    window.addEventListener('blur', onBlur);
    return () => {
      window.removeEventListener('keydown', onKeyDown, true);
      window.removeEventListener('keyup', onKeyUp, true);
      window.removeEventListener('blur', onBlur);
    };
  }, [streamable, inputSuspended, releaseHeldButtons]);

  // ---- HELD-KEY FLUSH on tab-hide / bfcache nav (additive; no forwarder touch) --
  //  'blur' (handled in the keyboard effect) does NOT fire on OS screen-lock,
  //  mobile app-switch, or a bfcache/pagehide navigation — leaving a modifier
  //  (Cmd/Ctrl/Alt) or any key stuck DOWN in the guest. These extra lifecycle
  //  listeners reuse the SAME releaseAllKeys the blur path calls: on the document
  //  going hidden we flush held scancodes; on pagehide we also release control.
  //  Purely new listeners — the keydown/keyup forwarder is untouched.
  //  Coming BACK (tab visible again, window focus) sends the relative-pointer
  //  bridge a re-home HINT: the browser pointer may re-enter far from where it
  //  left (the Cmd-Tab case) and the guest may have moved its own cursor
  //  meanwhile. One datagram; absolute stations and old daemons ignore it.
  useEffect(() => {
    const hint = () => { try { controlRef.current?.sendRehomeHint?.(); } catch { /* noop */ } };
    const onVisibility = () => {
      if (document.hidden) {
        try { controlRef.current?.releaseAllKeys(); } catch { /* noop */ }
        releaseHeldButtons();
      } else {
        hint();
      }
    };
    const onPageHide = () => {
      try { controlRef.current?.releaseAllKeys(); } catch { /* noop */ }
      releaseHeldButtons();
      try { controlRef.current?.releaseControl(); } catch { /* channel may be gone */ }
    };
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('pagehide', onPageHide);
    window.addEventListener('focus', hint);
    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('pagehide', onPageHide);
      window.removeEventListener('focus', hint);
    };
  }, [releaseHeldButtons]);

  // ---- POINTER + WHEEL -> guest, letterbox-aware pixel mapping --------------
  //  The interaction element is the streamhost <canvas> or <video>.
  useEffect(() => {
    const el: HTMLElement | null = directCanvas ? canvasRef.current : videoRef.current;
    if (!el || !control || !live) return;
    // Listen on the STAGE so the letterbox bars are live trackpad surface; the
    // guard below keeps direct pointing on the picture alone. Overlays inside the
    // stage (the badge, the stage menu) stop their own pointerdown, so this never
    // sees a tap meant for a control.
    const surface: HTMLElement = stageRef.current ?? el;
    // What counts as pointing surface: the picture always, plus the BARE stage
    // (its letterbox bars) in trackpad mode. An overlay INSIDE the stage never
    // does — its own handlers own it — so a tap on the boot-video scrubber or a
    // status banner cannot also drive the guest pointer. Capture is taken on the
    // picture, so once a contact starts every later event retargets to `el` and
    // passes; a bare pen hover has no capture and is judged each time.
    const offSurface = (e: Event) =>
      e.target !== el && !(trackpadRef.current && e.target === surface);

    let touching = false;

    // Per-pointerId button we sent DOWN in the mouse/pen else-branch, so the
    // matching pointerUP releases the SAME button. An S-Pen BARREL press maps to
    // right (2); releasing 0 instead would strand the held right-button in the
    // guest. The teardown-flush Set (pressedButtonsRef) also gets the mapped button.
    const penDownBtn = new Map<number, number>();
    // Right-click de-dup clocks: a real MOUSE right-click fires BOTH a
    // pointerdown(button 2) AND a native contextmenu/auxclick. Track when the
    // pointer path — and a contextmenu synth — last emitted a guest right-button so
    // the contextmenu/auxclick fallbacks below never double-fire it.
    let lastPointerRightMs = -Infinity;
    let lastCtxSynthMs = -Infinity;
    // When the live contact went down, on a HANDLER-READ clock. This is the
    // clock input/penRightClick uses to tell an S-Pen barrel press from
    // Android's long-press, and it must NOT be an event timeStamp: Chromium
    // gives a synthesized long-press contextmenu the timeStamp of the
    // pointerdown it came from, so that difference is 0 however long the hold.
    let contactAtMs = -Infinity;

    // DIAGNOSTIC pointer telemetry (input/pointerTelemetry): one drag-tel per
    // stroke + one hover-tel per ~1s of bare-pen hover. Always-on but low volume;
    // the upload is naturally gated by the operator token in clientDebug.
    const stroke = new StrokeAccumulator();
    const hover = new HoverAccumulator();
    // Stylus tap quantiser (input/tapQuantiser). The finger path has its own
    // inside the recognizer; a pen never reaches that, so it gets one here.
    // It measures in CSS px, so every call carries the client point alongside
    // the mapped guest one.
    const penTap = createTapQuantiser();
    const wireSnap = (): WireSnapshot =>
      control.moveWireSnapshot?.() ?? { sent: 0, rejected: 0, desiredSizeMin: null };

    const map = (clientX: number, clientY: number, clamp = true) =>
      clientToGuest(clientX, clientY, el.getBoundingClientRect(), control.getResolution(), clamp, presentFill);

    // Under pointer lock clientX/Y are frozen — the virtual cursor (fed by the
    // movementX/Y integrator) is the source of truth for button/wheel positions.
    const lockedPoint = () => vcursorRef.current
      ? { x: Math.round(vcursorRef.current.x), y: Math.round(vcursorRef.current.y) }
      : lastGuestRef.current;

    const forwardMove = (native: PointerEvent) => {
      if (lockedRef.current) return; // locked motion handled by the lock effect
      // Sample resolution comes from the shared input/moveSamples helper:
      // coalesced fan-out normally; native-event-only while pinch-zoomed
      // (coalesced coords are not layout-viewport re-projected in Chromium).
      const samples = resolveMoveSamples(native);
      const asTouch = native.pointerType === 'touch' || touchExhibit;
      let fwd = 0; // samples forwarded to the guest this native event (telemetry)
      // Last forwarded sample's guest-px + raw client-px coords (shape telemetry).
      let lgx: number | undefined, lgy: number | undefined, lcx: number | undefined, lcy: number | undefined;
      for (const s of samples) {
        const g = map(s.clientX, s.clientY, true);
        if (!g) continue;
        lastGuestRef.current = g;
        if (asTouch) {
          if (!touching) continue;
          // Tap/drag lands exactly under the finger (guest px).
          touch.move(native.pointerId, g.x, g.y, native.timeStamp, s.clientX, s.clientY);
          fwd++;
        } else {
          // NO ORPHAN ADOPTION HERE, deliberately. Chrome-Android eats the
          // pointerdown of a barrel gesture outright, so motion arrives carrying
          // a button with no contact on record. Synthesizing the missing press
          // from that was tried twice and regressed twice (a727fb2, ee3364f):
          // adopted as LEFT it manufactured a contact that swallowed the barrel's
          // own contextmenu, killing the right-click TAP; adopted as RIGHT it
          // stuck the button down in the guest, because the release depended on a
          // buttons=0 move that never comes when the pen simply leaves proximity
          // (measured: mask stayed 0x04 across every later click).
          //
          // A press we invent needs a release we cannot guarantee, and a stuck
          // button is far worse than an unresponsive gesture. So the barrel does
          // what the platform actually supports — a right-click TAP, via the
          // contextmenu below — and a right-button DRAG comes from the badge's
          // arm, which rides a real pointerdown/pointerup pair.
          // T-5: drop / throttle bare S-Pen hover so it can't flood the guest (a
          // rel station would drift its cursor on every hover move).
          if (!allowPenHover({
            pointerType: native.pointerType, buttons: native.buttons,
            rel: pointerRel, nowMs: native.timeStamp, lastMs: penHoverRef.current,
          })) continue;
          if (native.pointerType === 'pen' && native.buttons === 0) penHoverRef.current = native.timeStamp;
          // Pen IN CONTACT: swallow wobble inside the slop so a tap stays a
          // point instead of becoming a 2 px drag. HOVER (buttons 0) is never
          // filtered — that is how the cursor tracks a pen held above the glass.
          if (native.pointerType === 'pen' && native.buttons !== 0
            && !penTap.forward({ x: g.x, y: g.y, cx: s.clientX, cy: s.clientY }, native.timeStamp)) continue;
          control.sendMouseMove(g.x, g.y);
          fwd++;
        }
        lgx = g.x; lgy = g.y; lcx = s.clientX; lcy = s.clientY;
      }
      // Telemetry: one sample per native event (source handler + resolved sample
      // count + forwarded + last forwarded guest/raw coords for the shape boxes).
      // Bare pen hover (no button) also feeds the hover window.
      const nType = native.type === 'pointerrawupdate' ? 'pointerrawupdate' : 'pointermove';
      stroke.sample(nType, samples.length, fwd, lgx, lgy, lcx, lcy, native.buttons);
      if (native.pointerType === 'pen' && native.buttons === 0) {
        hover.newWindow(native.timeStamp);
        hover.hover(fwd > 0);
        const hd = hover.flush(native.timeStamp);
        if (hd) logClientEvent('hover-tel', hd);
      }
    };

    const onDown = (e: PointerEvent) => {
      if (offSurface(e)) return;
      // Fullscreen streamhost capture: a click while UNLOCKED re-acquires the
      // pointer lock (this click is the required user gesture) and is consumed —
      // it does not also click the guest. NOT on touch devices: pointer lock
      // never engages on Android Chrome, so consuming the tap here would eat
      // EVERY fullscreen tap on a phone — coarse-pointer devices fall through
      // to the normal mapped click path instead.
      if (mouseCapture && fsRef.current && !lockedRef.current && !isTouchDevice()) {
        acquireLock();
        e.preventDefault();
        return;
      }
      const g = lockedRef.current ? lockedPoint() : map(e.clientX, e.clientY);
      if (!g) return;
      lastGuestRef.current = g;
      // Open a telemetry stroke (both the touch and the mouse/pen branch below).
      stroke.begin(e.pointerType, { x: g.x, y: g.y, t: e.timeStamp }, wireSnap());
      if (!lockedRef.current) { try { el.setPointerCapture(e.pointerId); } catch { /* noop */ } }
      if (e.pointerType === 'touch' || touchExhibit) {
        touching = true;
        // S-Pen barrel button → right-click (button 2); a plain tip/finger is left.
        const right = e.button === 2 || (e.pointerType === 'pen' && (e.buttons & 2) !== 0);
        touch.begin(e.pointerId, g.x, g.y, e.timeStamp, e.clientX, e.clientY, right);
      } else {
        // S-Pen BARREL button → guest RIGHT-click. The barrel surfaces as the
        // secondary-button bit (buttons&2): it may arrive as e.button===2 on the
        // down itself, or as an already-held buttons&2 state when the tip contacts
        // (barrel pressed first, then tip). Both map to button 2; a plain tip/mouse
        // press is unchanged (e.button, normally 0 = left → drag-draw still works).
        // The badge's one-shot arm applies to a STYLUS too. It is the only way to
        // get a right press-DRAG on this device: the S-Pen barrel has no pointer
        // button bit at all (telemetry, 2026-07-26) and Android eats its press
        // outright during a drag (2026-08-05), so the barrel can produce a right
        // click but never a held right button to drag a spring-loaded menu with.
        const armed = e.pointerType === 'pen' && touch.takeArm();
        const btn = armed || e.button === 2
          || (e.pointerType === 'pen' && (e.buttons & 2) !== 0) ? 2 : e.button;
        if (btn === 2) lastPointerRightMs = e.timeStamp; // suppress the ctxmenu/aux double
        penDownBtn.set(e.pointerId, btn);
        pressedButtonsRef.current.add(btn);
        contactAtMs = performance.now();
        // A STYLUS lands here, not on the touch recognizer (input/penContact,
        // which also emits the `pen-tap` telemetry line).
        if (e.pointerType === 'pen') {
          hapticTap(); // a stylus click is felt in the hand holding the phone
          penPress(control, penTap, btn, { x: g.x, y: g.y, cx: e.clientX, cy: e.clientY }, e.timeStamp);
        } else control.sendMouseButton(btn, true, g.x, g.y);
      }
      e.preventDefault();
    };
    const onUp = (e: PointerEvent) => {
      // NO offSurface guard on the RELEASE: a contact that began on the picture
      // and lifted past its edge must still release, or the button stays down in
      // the guest. The branches below are all keyed on state this pointer opened,
      // so a stray release for a pointer we never took is already a no-op.
      const g = lockedRef.current ? lockedPoint() : (map(e.clientX, e.clientY) ?? lastGuestRef.current);
      if (!lockedRef.current) { try { el.releasePointerCapture(e.pointerId); } catch { /* noop */ } }
      if (e.pointerType === 'touch' || touchExhibit) {
        // A real / synth pointercancel means the touch was stolen (pinch/scroll
        // takeover) — DISCARD it (no stray tap), don't commit it like a release.
        if (touching) {
          if (e.type === 'pointercancel') touch.cancel();
          else {
            // ALWAYS end the touch — even if the release maps outside the picture —
            // so a committed drag's button-up is never dropped (no stuck button).
            const p = g ?? lastGuestRef.current ?? { x: 0, y: 0 };
            touch.end(e.pointerId, p.x, p.y, e.timeStamp, e.clientX, e.clientY);
          }
        }
        touching = false;
      } else {
        // Release the EXACT button pressed for THIS pointer (a barrel press pressed
        // 2, so releasing 0 would strand the held right-button). Fall back to
        // e.button for a stray up with no recorded down (?? handles a tracked 0).
        const btn = penDownBtn.get(e.pointerId) ?? e.button;
        penDownBtn.delete(e.pointerId);
        const wasPressed = pressedButtonsRef.current.delete(btn);
        if (wasPressed) {
          if (e.pointerType === 'pen') {
            // A release that maps outside the picture still has to release: fall
            // back to the last known guest point, but keep the REAL client point
            // so the quantiser measures the wobble it actually saw.
            const at = { x: g?.x ?? 0, y: g?.y ?? 0, cx: e.clientX, cy: e.clientY };
            penRelease(control, penTap, btn, at, e.timeStamp);
          } else control.sendMouseButton(btn, false, g?.x, g?.y);
        }
      }
      // Close + emit the telemetry stroke (up OR cancel). finish() is a no-op
      // when no stroke was open (a stray up), so this is safe unconditionally.
      const end = g ?? lastGuestRef.current ?? { x: 0, y: 0 };
      const d = stroke.finish({ x: end.x, y: end.y, t: e.timeStamp }, wireSnap());
      if (d) logClientEvent('drag-tel', d);
      e.preventDefault();
    };
    // PINCH-ZOOM GATE: while the page is pinch-zoomed, rawupdate-delivered
    // coords mis-map (see input/moveSamples) — fall back to plain pointermove,
    // whose native coords are layout-viewport correct (proven by the down/up
    // path). At scale 1 the code path is identical to before.
    const onMove = (e: PointerEvent) => {
      if (offSurface(e)) return;
      if (!supportsRawUpdate || pinched()) forwardMove(e);
    };
    const onRaw = (e: Event) => { if (!offSurface(e) && !pinched()) forwardMove(e as PointerEvent); };
    const onWheel = (e: WheelEvent) => {
      if (offSurface(e)) return;
      control.sendWheel(e.deltaX, e.deltaY);
      e.preventDefault();
    };
    // A native contextmenu is EITHER the S-Pen barrel or Android's long-press —
    // input/penRightClick decides which from its timing and owns both outcomes.
    const rightClick = (e: MouseEvent, sinceCtxSynthMs?: number) => {
      const g = lockedRef.current ? lockedPoint() : (map(e.clientX, e.clientY) ?? lastGuestRef.current);
      if (!g) return;
      const held = penDownBtn.size > 0;
      const act = contextMenuAction({
        heldContact: held,
        sinceContactMs: performance.now() - contactAtMs,
        sincePointerRightMs: e.timeStamp - lastPointerRightMs,
        sinceCtxSynthMs,
      });
      if (act === 'ignore') return;
      lastGuestRef.current = g;
      lastCtxSynthMs = e.timeStamp;
      if (act === 'synth') {
        hapticTap(); // a barrel tap with the pen off the glass: still a click
        synthRightClick(control, pressedButtonsRef.current, g.x, g.y);
        return;
      }
      // Barrel press mid-contact: this contact becomes a RIGHT-button hold, so
      // the pen's own lift releases it and a spring-loaded menu can be dragged.
      convertContactToRight(control, pressedButtonsRef.current, g.x, g.y);
      for (const id of penDownBtn.keys()) penDownBtn.set(id, 2);
    };
    const onCtx = (e: MouseEvent) => {
      e.preventDefault();                    // always kill the browser's own menu
      if (offSurface(e)) return;
      rightClick(e);
    };
    // Fallback for a device that emits auxclick (secondary button) but no
    // contextmenu; de-duped against a contextmenu that just fired.
    const onAux = (e: MouseEvent) => {
      if (e.button !== 2 || offSurface(e)) return;
      e.preventDefault();
      rightClick(e, e.timeStamp - lastCtxSynthMs);
    };

    // Pointer re-entering the surface after a real absence: same re-home hint
    // (a mouse that left the exhibit and came back may find the guest cursor
    // elsewhere). Brushing the edge of the surface is not an absence — a
    // re-home costs the guest a pin + settle + walk, so only a leave of
    // REENTER_HINT_MS or more (or the first entry) sends it.
    let leftAt = 0;
    const onLeave = (e: PointerEvent) => { if (e.pointerType !== 'touch') leftAt = e.timeStamp; };
    const onEnter = (e: PointerEvent) => {
      if (e.pointerType === 'touch') return;
      if (leftAt !== 0 && e.timeStamp - leftAt < REENTER_HINT_MS) return;
      try { control.sendRehomeHint?.(); } catch { /* noop */ }
    };
    surface.addEventListener('pointerleave', onLeave);
    surface.addEventListener('pointerenter', onEnter);
    surface.addEventListener('pointerdown', onDown);
    surface.addEventListener('pointermove', onMove);
    surface.addEventListener('pointerup', onUp);
    surface.addEventListener('pointercancel', onUp);
    if (supportsRawUpdate) surface.addEventListener('pointerrawupdate', onRaw as EventListener);
    surface.addEventListener('wheel', onWheel, { passive: false });
    surface.addEventListener('contextmenu', onCtx, true);
    surface.addEventListener('auxclick', onAux, true);
    return () => {
      surface.removeEventListener('pointerleave', onLeave);
      surface.removeEventListener('pointerenter', onEnter);
      surface.removeEventListener('pointerdown', onDown);
      surface.removeEventListener('pointermove', onMove);
      surface.removeEventListener('pointerup', onUp);
      surface.removeEventListener('pointercancel', onUp);
      if (supportsRawUpdate) surface.removeEventListener('pointerrawupdate', onRaw as EventListener);
      surface.removeEventListener('wheel', onWheel);
      surface.removeEventListener('contextmenu', onCtx, true);
      surface.removeEventListener('auxclick', onAux, true);
      releaseHeldButtons(control);
    };
  }, [control, live, touchExhibit, mouseCapture, acquireLock, directCanvas, releaseHeldButtons]);

}
