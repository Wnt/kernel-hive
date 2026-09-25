// M-UI4: device-drawing stations whose real device has no pointer
// (deviceTypes.ts `pointer: 'none'`, e.g. nokia9300) must never
// forward a click/drag/wheel on the stream as a guest pointer event — the
// drawn keys and the physical keyboard remain the only input. This drives the
// REAL "POINTER + WHEEL -> guest" effect end to end (a real DOM event
// dispatched on the stream element) and asserts the guest-facing control
// calls it would otherwise make are made when pointerless is unset, and never
// made when pointerless is true — the flag actually suppresses forwarding,
// not just a name that says so.
import { createElement } from 'react';
import { act, create } from 'react-test-renderer';
import { describe, expect, it, vi } from 'vitest';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import { useStreamInput } from './useStreamInput';

// The hook's OTHER effects (keyboard lock, the global keydown/keyup forwarder,
// the held-key flush) attach listeners on `window`/`document` unconditionally
// or behind `streamable` — a bare EventTarget stands in for both; streamable
// is left false below so only the always-on held-key-flush effect touches it,
// which needs nothing more than addEventListener/removeEventListener.
function fakeGlobal(extra: Record<string, unknown> = {}) {
  return Object.assign(new EventTarget(), extra) as unknown as (Window & typeof globalThis);
}

/** A stand-in for the streamhost <video>/<canvas> element AND the stage (they
 *  are the same object here, so `surface === el` and every dispatched event's
 *  `target` already equals `el` — the effect's offSurface() guard passes). */
function fakeStreamElement() {
  const el = Object.assign(new EventTarget(), {
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 200, height: 100, right: 200, bottom: 100 }),
    setPointerCapture: vi.fn(),
    releasePointerCapture: vi.fn(),
  });
  return el as unknown as HTMLVideoElement;
}

function fakeControl() {
  return {
    getResolution: () => ({ w: 200, h: 100 }),
    sendMouseButton: vi.fn(),
    sendMouseMove: vi.fn(),
    sendWheel: vi.fn(),
    moveWireSnapshot: () => ({ sent: 0, rejected: 0, desiredSizeMin: null }),
  } as unknown as StreamControlHandle;
}

function pointerEvent(type: string, init: Record<string, unknown>) {
  const e = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(e, 'timeStamp', { value: 1000, configurable: true });
  return Object.assign(e, {
    clientX: 100, clientY: 50, pointerId: 1, button: 0, pointerType: 'mouse', buttons: 1,
    ...init,
  });
}

function wheelEvent() {
  const e = new Event('wheel', { bubbles: true, cancelable: true });
  return Object.assign(e, { clientX: 100, clientY: 50, deltaX: 0, deltaY: 10 });
}

function mount(pointerless: boolean | undefined) {
  (globalThis as unknown as { window: unknown }).window = fakeGlobal();
  (globalThis as unknown as { document: unknown }).document = fakeGlobal({ hidden: false });
  const el = fakeStreamElement();
  const control = fakeControl();
  function Probe() {
    useStreamInput({
      streamable: false, inputSuspended: false,
      releaseHeldButtons: () => {}, control, live: true,
      touchExhibit: false, mouseCapture: false, acquireLock: () => {},
      directCanvas: false, revealChrome: () => {}, setDebug: () => {},
      touch: { move: () => {}, begin: () => {}, end: () => {}, cancel: () => {}, takeArm: () => false } as any,
      pointerRel: false, presentFill: false, pointerless,
      controlRef: { current: control }, fsRef: { current: false }, lockedRef: { current: false },
      vcursorRef: { current: null }, lastGuestRef: { current: null },
      pressedButtonsRef: { current: new Set() }, penHoverRef: { current: 0 },
      videoRef: { current: el }, canvasRef: { current: null },
      trackpadRef: { current: false }, stageRef: { current: null },
    });
    return null;
  }
  act(() => { create(createElement(Probe)); });
  return { el, control };
}

describe('useStreamInput pointer + wheel forwarding, gated by pointerless', () => {
  it('forwards a click and a wheel tick to the guest when pointerless is unset', () => {
    const { el, control } = mount(undefined);
    act(() => { el.dispatchEvent(pointerEvent('pointerdown', {})); });
    expect(control.sendMouseButton).toHaveBeenCalledTimes(1);
    act(() => { el.dispatchEvent(wheelEvent()); });
    expect(control.sendWheel).toHaveBeenCalledTimes(1);
  });

  it('never forwards a click, drag or wheel to the guest when pointerless is true', () => {
    const { el, control } = mount(true);
    act(() => { el.dispatchEvent(pointerEvent('pointerdown', {})); });
    act(() => { el.dispatchEvent(pointerEvent('pointermove', { buttons: 1 })); });
    act(() => { el.dispatchEvent(pointerEvent('pointerup', {})); });
    act(() => { el.dispatchEvent(wheelEvent()); });
    expect(control.sendMouseButton).not.toHaveBeenCalled();
    expect(control.sendMouseMove).not.toHaveBeenCalled();
    expect(control.sendWheel).not.toHaveBeenCalled();
    // No pointer-capture cursor affordance is claimed either: the element
    // never even has capture requested on it.
    expect((el as unknown as { setPointerCapture: ReturnType<typeof vi.fn> }).setPointerCapture)
      .not.toHaveBeenCalled();
  });
});
