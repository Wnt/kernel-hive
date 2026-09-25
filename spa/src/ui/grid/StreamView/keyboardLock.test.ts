import { describe, expect, it } from 'vitest';
import { isTypingField, isDeviceKeyActivation, isDeviceKeyTabNav } from './keyboardLock';
import { DEVICE_KEY_INPUT_CLASS } from '../../device/deviceTypes';

// The M4 form-field boundary: a REAL typing field (the OSK's "type here →
// guest" input, a URL/text toolbar box, contenteditable) must keep owning
// every key while focused, but a device-drawing key's own accessible
// activation control (KeyCap.tsx's `<input class="dev-key-input">`) must
// NOT be treated the same way — that was exactly M4's swallow, reproduced on
// the device page when it was excluded like a real field. These three
// predicates are the forwarding rule useStreamInput's global keydown/keyup
// listeners apply; testing them directly covers the matrix without having to
// mount the whole streaming effect.

// Vitest runs this suite under the 'node' environment (no DOM), matching the
// rest of the repo's unit tests, so a real document.createElement isn't
// available — a minimal fake with the exact shape the predicates read
// (tagName, classList.contains, isContentEditable) is enough.
function el(tag: string, opts: { className?: string; contentEditable?: boolean } = {}): HTMLElement {
  const classes = (opts.className ?? '').split(/\s+/).filter(Boolean);
  return {
    tagName: tag.toUpperCase(),
    isContentEditable: !!opts.contentEditable,
    classList: { contains: (c: string) => classes.includes(c) },
  } as unknown as HTMLElement;
}

describe('isTypingField', () => {
  it('is null-safe', () => {
    expect(isTypingField(null)).toBe(false);
  });

  it('treats a plain body/div target as not a typing field', () => {
    expect(isTypingField(el('div'))).toBe(false);
  });

  it.each(['INPUT', 'TEXTAREA'])('treats a real %s as a typing field', (tag) => {
    expect(isTypingField(el(tag.toLowerCase()))).toBe(true);
  });

  it('treats a contentEditable element as a typing field', () => {
    expect(isTypingField(el('div', { contentEditable: true }))).toBe(true);
  });

  it('treats the OSK "type here → guest" input as a typing field (M4 regression: must still own Esc)', () => {
    expect(isTypingField(el('input', { className: 'osk-abc-input' }))).toBe(true);
  });

  it('does NOT treat a drawn device key\'s own input as a typing field, even though it is an <input>', () => {
    expect(isTypingField(el('input', { className: DEVICE_KEY_INPUT_CLASS }))).toBe(false);
  });

  it('does not treat a device-key input as typing even with other classes present', () => {
    expect(isTypingField(el('input', { className: `foo ${DEVICE_KEY_INPUT_CLASS} bar` }))).toBe(false);
  });
});

describe('isDeviceKeyActivation', () => {
  const devKey = () => el('input', { className: DEVICE_KEY_INPUT_CLASS });

  it('is null-safe', () => {
    expect(isDeviceKeyActivation(null, 'Enter')).toBe(false);
  });

  it.each(['Enter', ' '])('is true for %j on a drawn key control (already sent by onPress — must not double-send)', (key) => {
    expect(isDeviceKeyActivation(devKey(), key)).toBe(true);
  });

  it.each(['Escape', 'Tab', 'ArrowUp', 'F1', 'a', 'A'])('is false for %j even on a drawn key control — it must still forward', (key) => {
    expect(isDeviceKeyActivation(devKey(), key)).toBe(false);
  });

  it('is false for Enter/Space on a non-device-key element (the OSK owns its own Enter via isTypingField instead)', () => {
    expect(isDeviceKeyActivation(el('input'), 'Enter')).toBe(false);
    expect(isDeviceKeyActivation(el('div'), ' ')).toBe(false);
  });
});

describe('isDeviceKeyTabNav', () => {
  const devKey = () => el('input', { className: DEVICE_KEY_INPUT_CLASS });

  it('is null-safe', () => {
    expect(isDeviceKeyTabNav(null, 'Tab')).toBe(false);
  });

  it('is true only for Tab on a drawn key control (so its default focus-move survives forwarding)', () => {
    expect(isDeviceKeyTabNav(devKey(), 'Tab')).toBe(true);
  });

  it('is false for a non-Tab key on a drawn key control', () => {
    expect(isDeviceKeyTabNav(devKey(), 'Enter')).toBe(false);
    expect(isDeviceKeyTabNav(devKey(), 'Escape')).toBe(false);
  });

  it('is false for Tab on a plain element (unchanged default preventDefault behaviour elsewhere)', () => {
    expect(isDeviceKeyTabNav(el('div'), 'Tab')).toBe(false);
  });
});

describe('the M4 matrix: which keys forward while a drawn key control has focus', () => {
  const devKey = () => el('input', { className: DEVICE_KEY_INPUT_CLASS });
  // Mirrors useStreamInput's onKeyDown decision for the non-Escape branch:
  // typing field -> never; device-key activation (Enter/Space) -> never
  // (already sent by the widget); everything else -> forwarded.
  const forwards = (target: HTMLElement, key: string) =>
    !isTypingField(target) && !isDeviceKeyActivation(target, key);

  it.each([
    ['Enter', false],
    [' ', false],
    ['Tab', true],
    ['ArrowUp', true],
    ['ArrowDown', true],
    ['ArrowLeft', true],
    ['ArrowRight', true],
    ['F1', true],
    ['F12', true],
    ['a', true],
    ['A', true],
  ])('%j on a focused drawn key forwards=%s', (key, expected) => {
    expect(forwards(devKey(), key)).toBe(expected);
  });

  it('Escape forwards while a drawn key has focus (the M4 case this branch fixes)', () => {
    // Escape is decided by the dedicated branch (`!isTypingField(e.target)`),
    // not the generic `forwards` helper above — assert that branch's
    // predicate directly, since Escape is handled before the activation check.
    expect(isTypingField(devKey())).toBe(false);
  });

  it('every key stays swallowed while a REAL typing field (OSK) has focus, matching the pre-existing M4 behaviour there', () => {
    const typingField = el('input', { className: 'osk-abc-input' });
    for (const key of ['Escape', 'Tab', 'ArrowUp', 'F1', 'a', 'Enter', ' ']) {
      if (key === 'Escape' || key === 'Enter' || key === ' ') {
        expect(isTypingField(typingField)).toBe(true); // Escape branch: !isTypingField gate
      } else {
        expect(forwards(typingField, key)).toBe(false);
      }
    }
  });
});
