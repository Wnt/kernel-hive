//  keyHold — the visitor's physical keys vs a typist (the type-in editor, the
//  demo listing). While a typist keys into the guest, the visitor's own keys
//  must not reach it: a Shift or Cmd held for a screenshot turns VIC-20 letters
//  into graphics glyphs mid-listing. A hold drops physical key edges, and keeps
//  the books so the guest never sees an orphan release afterwards or a key
//  "pressed" retroactively: what was held (or went down) during the hold has
//  its repeats and its release swallowed until it comes up.

export interface KeyHold {
  /** Start a hold (nests). `releaseHeld` runs once, first, when the outermost
   *  hold begins; it must release every key the guest believes is down. */
  hold(releaseHeld: () => void): () => void;
  /** Should this physical key edge (KeyboardEvent.code) be dropped? Tracks it. */
  dropEvent(code: string, down: boolean): boolean;
  /** Same for a keysym-addressed edge (the on-screen keyboard). */
  dropKeysym(keysym: number, down: boolean): boolean;
  /** The guest was told every key is up (blur, disconnect): forget the books. */
  reset(): void;
}

export function createKeyHold(): KeyHold {
  let holds = 0;
  const physDown = new Set<string>();
  const ignoredCodes = new Set<string>();
  const ignoredKeysyms = new Set<number>();

  // Drop while held (remember the key); after the hold, swallow what we
  // remembered until it comes up.
  const gate = <T>(set: Set<T>, key: T, down: boolean): boolean => {
    if (holds > 0) {
      if (down) set.add(key); else set.delete(key);
      return true;
    }
    if (!set.has(key)) return false;
    if (!down) set.delete(key);
    return true;
  };

  return {
    hold(releaseHeld) {
      if (holds++ === 0) {
        for (const c of physDown) ignoredCodes.add(c);
        releaseHeld();
      }
      let released = false;
      return () => {
        if (released) return;
        released = true;
        holds = Math.max(0, holds - 1);
      };
    },
    dropEvent(code, down) {
      if (down) physDown.add(code); else physDown.delete(code);
      return gate(ignoredCodes, code, down);
    },
    dropKeysym: (keysym, down) => gate(ignoredKeysyms, keysym, down),
    reset() {
      physDown.clear();
      if (holds === 0) { ignoredCodes.clear(); ignoredKeysyms.clear(); }
    },
  };
}
