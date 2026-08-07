// The sentinel + value-diff core of the mobile sheet's free-text input (the
// noVNC/Guacamole approach): the input is reset to a lone zero-width-space
// sentinel after every settled event, so the next mutation diffs cleanly into
// "N backspaces + typed text" — Backspace works on a visually-empty field and
// composed IME commits arrive as plain text. Pure function, DOM-free tests.

import { PROXY_SENTINEL } from './oskConstants';

export function diffProxyValue(value: string): { backspaces: number; text: string } {
  const stripped = value.split(PROXY_SENTINEL).join('');
  if (value.startsWith(PROXY_SENTINEL)) {
    // Sentinel intact → everything after it was typed/committed.
    return { backspaces: 0, text: stripped };
  }
  // Sentinel deleted = exactly one Backspace (we reset after every settle, so
  // more than one is impossible); any remaining chars were typed after it.
  return { backspaces: 1, text: stripped };
}
