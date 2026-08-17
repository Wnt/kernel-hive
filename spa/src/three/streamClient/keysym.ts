// ============================================================================
//  streamClient/keysym — the X11 XK keysym vocabulary and the browser
//  KeyboardEvent -> keysym translation. Split out of useStreamControl.ts
//  (ts-src 600-line hard cap): self-contained, no dependency on the rest of
//  the controller. X11 keysyms remain the UI-facing keyboard vocabulary;
//  useStreamControl's sendKey/sendKeyEvent translate them to XT set-1
//  scancodes (guestQuirks) before sending them to the daemon.
// ============================================================================

// X11 keysyms remain the UI-facing keyboard vocabulary. The stream controller
// translates them to XT set-1 scancodes before sending them to the daemon.
export const XK = {
  BackSpace: 0xff08,
  Tab: 0xff09,
  Linefeed: 0xff0a,
  Clear: 0xff0b,
  Return: 0xff0d,
  Pause: 0xff13,
  Scroll_Lock: 0xff14,
  Sys_Req: 0xff15,
  Escape: 0xff1b,
  Delete: 0xffff,
  Home: 0xff50,
  Left: 0xff51,
  Up: 0xff52,
  Right: 0xff53,
  Down: 0xff54,
  Prior: 0xff55,
  Next: 0xff56,
  End: 0xff57,
  Begin: 0xff58,
  Insert: 0xff63,
  Menu: 0xff67,
  Num_Lock: 0xff7f,
  KP_Enter: 0xff8d,
  KP_Home: 0xff95,
  KP_Left: 0xff96,
  KP_Up: 0xff97,
  KP_Right: 0xff98,
  KP_Down: 0xff99,
  KP_Prior: 0xff9a,
  KP_Next: 0xff9b,
  KP_End: 0xff9c,
  KP_Begin: 0xff9d,
  KP_Insert: 0xff9e,
  KP_Delete: 0xff9f,
  Shift_L: 0xffe1,
  Shift_R: 0xffe2,
  Control_L: 0xffe3,
  Control_R: 0xffe4,
  Caps_Lock: 0xffe5,
  Meta_L: 0xffe7,
  Meta_R: 0xffe8,
  Alt_L: 0xffe9,
  Alt_R: 0xffea,
  Super_L: 0xffeb,
  Super_R: 0xffec,
} as const;

const LOC_RIGHT = 2;
const LOC_NUMPAD = 3;

/** Map a browser keyboard event to an X11 keysym. */
export function keysymFromKeyboardEvent(e: {
  key: string;
  location?: number;
  code?: string;
}): number | null {
  const key = e.key;
  const loc = e.location ?? 0;
  if (!key || key === 'Unidentified' || key === 'Dead' || key === 'Process') return null;

  if (/^F\d+$/.test(key)) {
    const n = Number(key.slice(1));
    if (n >= 1 && n <= 24) return 0xffbe + (n - 1);
  }

  switch (key) {
    case 'Enter': return loc === LOC_NUMPAD ? XK.KP_Enter : XK.Return;
    case 'Tab': return XK.Tab;
    case 'Backspace': return XK.BackSpace;
    case 'Escape': return XK.Escape;
    case 'Delete': return loc === LOC_NUMPAD ? XK.KP_Delete : XK.Delete;
    case 'Insert': return loc === LOC_NUMPAD ? XK.KP_Insert : XK.Insert;
    case 'Home': return loc === LOC_NUMPAD ? XK.KP_Home : XK.Home;
    case 'End': return loc === LOC_NUMPAD ? XK.KP_End : XK.End;
    case 'PageUp': return loc === LOC_NUMPAD ? XK.KP_Prior : XK.Prior;
    case 'PageDown': return loc === LOC_NUMPAD ? XK.KP_Next : XK.Next;
    case 'ArrowLeft': return loc === LOC_NUMPAD ? XK.KP_Left : XK.Left;
    case 'ArrowUp': return loc === LOC_NUMPAD ? XK.KP_Up : XK.Up;
    case 'ArrowRight': return loc === LOC_NUMPAD ? XK.KP_Right : XK.Right;
    case 'ArrowDown': return loc === LOC_NUMPAD ? XK.KP_Down : XK.Down;
    case 'Clear': return XK.Begin;
    case 'CapsLock': return XK.Caps_Lock;
    case 'NumLock': return XK.Num_Lock;
    case 'ScrollLock': return XK.Scroll_Lock;
    case 'Pause': return XK.Pause;
    case 'ContextMenu': return XK.Menu;
    case 'Shift': return loc === LOC_RIGHT ? XK.Shift_R : XK.Shift_L;
    case 'Control': return loc === LOC_RIGHT ? XK.Control_R : XK.Control_L;
    case 'Alt':
    case 'AltGraph': return key === 'AltGraph' || loc === LOC_RIGHT ? XK.Alt_R : XK.Alt_L;
    case 'Meta':
    case 'OS': return loc === LOC_RIGHT ? XK.Super_R : XK.Super_L;
    default: break;
  }

  const chars = Array.from(key);
  if (chars.length === 1) {
    const cp = chars[0].codePointAt(0);
    if (cp != null) return cp < 0x100 ? cp : 0x01000000 + cp;
  }
  return null;
}
