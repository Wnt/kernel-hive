// Chorded mouse buttons (job MB2, 2026-09-28). Pointer Events report the SECOND
// button of a chord — and every release but the last — as a `pointermove` with
// a changed `buttons` mask; `pointerdown`/`pointerup` fire only for the first
// press and the final release. The hook must turn each changed bit into one wire
// edge, in order, or a Minesweeper L+R chord never reaches the guest. This
// drives the REAL pointer effect with dispatched DOM events (same harness shape
// as useStreamInput.pointerless.test.ts) and asserts the exact edge sequence.
import { createElement } from 'react';
import { act, create } from 'react-test-renderer';
import { describe, expect, it, vi } from 'vitest';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import { useStreamInput } from './useStreamInput';

function fakeGlobal(extra: Record<string, unknown> = {}) {
  return Object.assign(new EventTarget(), extra) as unknown as (Window & typeof globalThis);
}

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

function ev(type: string, init: Record<string, unknown>) {
  const e = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(e, 'timeStamp', { value: 1000, configurable: true });
  return Object.assign(e, {
    clientX: 100, clientY: 50, pointerId: 1, button: -1, pointerType: 'mouse', buttons: 0,
    ...init,
  });
}

function mount({ touchExhibit = false } = {}) {
  (globalThis as unknown as { window: unknown }).window = fakeGlobal();
  (globalThis as unknown as { document: unknown }).document = fakeGlobal({ hidden: false });
  const el = fakeStreamElement();
  const control = fakeControl();
  const pressed = new Set<number>();
  const touch = { move: vi.fn(), begin: vi.fn(), end: vi.fn(), cancel: vi.fn(), takeArm: () => false };
  function Probe() {
    useStreamInput({
      streamable: false, inputSuspended: false,
      releaseHeldButtons: () => {
        for (const b of pressed) control.sendMouseButton(b, false);
        pressed.clear();
      },
      control, live: true,
      touchExhibit, mouseCapture: false, acquireLock: () => {},
      directCanvas: false, revealChrome: () => {}, setDebug: () => {},
      touch: touch as any,
      pointerRel: false, presentFill: false,
      controlRef: { current: control }, fsRef: { current: false }, lockedRef: { current: false },
      vcursorRef: { current: null }, lastGuestRef: { current: null },
      pressedButtonsRef: { current: pressed }, penHoverRef: { current: 0 },
      videoRef: { current: el }, canvasRef: { current: null },
      trackpadRef: { current: false }, stageRef: { current: null },
    });
    return null;
  }
  act(() => { create(createElement(Probe)); });
  const fire = (type: string, init: Record<string, unknown>) =>
    act(() => { el.dispatchEvent(ev(type, init)); });
  const edges = () => (control.sendMouseButton as ReturnType<typeof vi.fn>).mock.calls
    .map(([b, down]) => `${b}${down ? 'v' : '^'}`);
  return { el, control, fire, edges, pressed, touch };
}

describe('useStreamInput — chorded mouse buttons become per-bit edges', () => {
  it('L↓ R↓ R↑ L↑ → four edges, in order', () => {
    const { fire, edges, pressed } = mount();
    fire('pointerdown', { button: 0, buttons: 1 });
    fire('pointermove', { button: 2, buttons: 3 });      // chorded right press
    fire('pointermove', { button: 2, buttons: 1 });      // chorded right release
    fire('pointerup', { button: 0, buttons: 0 });
    expect(edges()).toEqual(['0v', '2v', '2^', '0^']);
    expect(pressed.size).toBe(0);
  });

  it('L↓ R↓ L↑ R↑ keeps the physical order (left released first)', () => {
    const { fire, edges } = mount();
    fire('pointerdown', { button: 0, buttons: 1 });
    fire('pointermove', { button: 2, buttons: 3 });
    fire('pointermove', { button: 0, buttons: 2 });      // chorded left release
    fire('pointerup', { button: 2, buttons: 0 });
    expect(edges()).toEqual(['0v', '2v', '0^', '2^']);
  });

  it('a right press during a held left arrives on pointerrawupdate or pointermove — one edge either way', () => {
    const { fire, edges } = mount();
    fire('pointerdown', { button: 0, buttons: 1 });
    fire('pointerrawupdate', { button: 2, buttons: 3 });
    fire('pointermove', { button: 2, buttons: 3 });
    expect(edges()).toEqual(['0v', '2v']);
  });

  it('carries the event point on each edge', () => {
    const { fire, control } = mount();
    fire('pointerdown', { button: 0, buttons: 1, clientX: 10, clientY: 10 });
    fire('pointermove', { button: 2, buttons: 3, clientX: 20, clientY: 30 });
    const calls = (control.sendMouseButton as ReturnType<typeof vi.fn>).mock.calls;
    expect(calls[1]).toEqual([2, true, 20, 30]);
  });

  it('middle is wire button 1; a multi-bit change goes out in bit order', () => {
    const { fire, edges } = mount();
    fire('pointerdown', { button: 1, buttons: 4 });
    fire('pointermove', { button: 0, buttons: 7 });      // L and R in one event
    fire('pointerup', { button: 1, buttons: 0 });        // everything released at once
    expect(edges()).toEqual(['1v', '0v', '2v', '0^', '2^', '1^']);
  });

  it('Windows order: contextmenu after R↑ injects nothing', () => {
    const { fire, edges } = mount();
    fire('pointerdown', { button: 0, buttons: 1 });
    fire('pointermove', { button: 2, buttons: 3 });
    fire('pointermove', { button: 0, buttons: 2 });
    fire('pointerup', { button: 2, buttons: 0 });
    fire('contextmenu', { button: 2, buttons: 0 });
    fire('auxclick', { button: 2, buttons: 0 });
    expect(edges()).toEqual(['0v', '2v', '0^', '2^']);
  });

  it('Linux order: contextmenu on the chorded R↓ does not convert the left press', () => {
    const { fire, edges } = mount();
    fire('pointerdown', { button: 0, buttons: 1 });
    fire('pointermove', { button: 2, buttons: 3 });
    fire('contextmenu', { button: 2, buttons: 3 });
    expect(edges()).toEqual(['0v', '2v']);
  });

  it('a plain right click is one down and one up, with no contextmenu double', () => {
    const { fire, edges } = mount();
    fire('pointerdown', { button: 2, buttons: 2 });
    fire('contextmenu', { button: 2, buttons: 2 });
    fire('pointerup', { button: 2, buttons: 0 });
    expect(edges()).toEqual(['2v', '2^']);
  });

  it('lost pointer capture releases both held bits; later events of that press send nothing', () => {
    const { fire, edges, pressed } = mount();
    fire('pointerdown', { button: 0, buttons: 1 });
    fire('pointermove', { button: 2, buttons: 3 });
    fire('lostpointercapture', {});
    expect(edges()).toEqual(['0v', '2v', '0^', '2^']);
    expect(pressed.size).toBe(0);
    fire('pointermove', { buttons: 3 });
    fire('pointerup', { button: 0, buttons: 0 });
    expect(edges()).toHaveLength(4);
  });

  it('pointercancel releases every held bit', () => {
    const { fire, edges } = mount();
    fire('pointerdown', { button: 0, buttons: 1 });
    fire('pointermove', { button: 2, buttons: 3 });
    fire('pointercancel', { button: -1, buttons: 0 });
    expect(edges()).toEqual(['0v', '2v', '0^', '2^']);
  });

  it('a drag that entered from outside never presses a button by sliding in', () => {
    const { fire, edges } = mount();
    fire('pointermove', { buttons: 1 });
    fire('pointermove', { button: 2, buttons: 3 });
    expect(edges()).toEqual([]);
  });

  it('pen barrel path is unchanged: a contextmenu inside the window converts the contact', () => {
    const { fire, edges } = mount();
    fire('pointerdown', { pointerType: 'pen', button: 0, buttons: 1 });
    fire('contextmenu', { pointerType: 'pen', button: 2, buttons: 1 });
    fire('pointerup', { pointerType: 'pen', button: 0, buttons: 0 });
    expect(edges()).toEqual(['0v', '0^', '2v', '2^']);
  });

  it('pen moves never emit edges from `buttons`', () => {
    const { fire, edges } = mount();
    fire('pointerdown', { pointerType: 'pen', button: 0, buttons: 1 });
    fire('pointermove', { pointerType: 'pen', button: 2, buttons: 3 });
    expect(edges()).toEqual(['0v']);
  });

  it('touch stays chord-free: a finger goes to the recognizer, never to edges', () => {
    const { fire, edges, touch } = mount({ touchExhibit: true });
    fire('pointerdown', { pointerType: 'touch', button: 0, buttons: 1 });
    fire('pointermove', { pointerType: 'touch', button: 2, buttons: 3 });
    fire('pointerup', { pointerType: 'touch', button: 0, buttons: 0 });
    expect(edges()).toEqual([]);
    expect(touch.begin).toHaveBeenCalledTimes(1);
    expect(touch.end).toHaveBeenCalledTimes(1);
  });
});
