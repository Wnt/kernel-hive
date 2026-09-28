import { describe, expect, it, vi } from 'vitest';
import { MouseChord } from './mouseChord';

function setup() {
  const send = vi.fn();
  const pressed = new Set<number>();
  const chord = new MouseChord(send, pressed);
  const edges = () => send.mock.calls.map(([b, d]) => `${b}${d ? 'v' : '^'}`);
  return { chord, pressed, edges };
}

describe('MouseChord', () => {
  it('a bit flushed behind its back (blur, hidden tab) is not pressed again by a stale mask', () => {
    const { chord, pressed, edges } = setup();
    chord.down({ pointerId: 1, button: 0, buttons: 1 });
    chord.move({ pointerId: 1, button: 2, buttons: 3 });
    pressed.clear();                                      // releaseHeldButtons ran
    chord.move({ pointerId: 1, button: -1, buttons: 3 }); // hand still on both
    expect(edges()).toEqual(['0v', '2v']);
    // Let go of right, press it again: that press is real and is sent.
    chord.move({ pointerId: 1, button: 2, buttons: 1 });
    chord.move({ pointerId: 1, button: 2, buttons: 3 });
    expect(edges()).toEqual(['0v', '2v', '2v']);
    chord.up({ pointerId: 1, button: 0, buttons: 2, type: 'pointerup' });
    chord.up({ pointerId: 1, button: 2, buttons: 0, type: 'pointerup' });
    expect(edges()).toEqual(['0v', '2v', '2v', '2^']);
  });

  it('a pointerdown whose buttons omit its own button still presses it', () => {
    const { chord, edges } = setup();
    chord.down({ pointerId: 1, button: 0, buttons: 0 });
    chord.up({ pointerId: 1, button: 0, buttons: 0, type: 'pointerup' });
    expect(edges()).toEqual(['0v', '0^']);
  });

  it('back/forward bits are never sent (wire 3/4 is the wheel)', () => {
    const { chord, edges } = setup();
    chord.down({ pointerId: 1, button: 3, buttons: 8 });
    chord.up({ pointerId: 1, button: 3, buttons: 0, type: 'pointerup' });
    expect(edges()).toEqual([]);
  });
});
