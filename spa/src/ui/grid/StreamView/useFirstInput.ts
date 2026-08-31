// ============================================================================
//  useFirstInput — witness the visitor's FIRST touch of a working machine.
//  ---------------------------------------------------------------------------
//  `station.open.toFirstInputMs` is the gallery's discoverability number: how
//  long somebody looks at a machine that is already streaming before daring to
//  use it. The session hook cannot witness that itself — the events land on the
//  view's own elements, which it does not own — so this hook watches them and
//  reports the first one, exactly as `sinkProbe` hands the session hook the
//  <video> state it also cannot reach.
//
//  WHY IT DETACHES AFTER ONE EDGE. Only the first edge changes anything, and a
//  station session is expected to see thousands more. Listening for the life of
//  the session in the CAPTURE phase of a hot input path, to set a boolean that
//  is already true, is a cost with no measurement behind it.
//
//  WHY IT WAITS FOR `live`. The clock starts at the first painted frame, so an
//  edge before that is a visitor clicking at a spinner — impatience with the
//  connect, which `station.open.toFirstFrameMs` already covers, and which would
//  otherwise be recorded here as a negative or absurd "time to touch".
//
//  WHY `isTrusted`. Same reason the intent ladder insists on it: a dispatched
//  event is the software acting. The type-in demo and the win9x boot-modal
//  auto-dismiss both put edges on the wire with nobody in the room, and
//  crediting those would report every scripted station as instantly
//  discoverable — the exact opposite of the truth, since a station that types
//  for you is one nobody had to work out how to use.
// ============================================================================

import { useEffect, type RefObject } from 'react';

export function useFirstInput({
  live,
  stageRef,
  noteInput,
}: {
  /** The machine is painting. Before this there is nothing to touch. */
  live: boolean;
  /** The station's own stage — the pointer surface for this guest. */
  stageRef: RefObject<HTMLDivElement | null>;
  noteInput: () => void;
}): void {
  useEffect(() => {
    if (!live) return;
    const stage = stageRef.current;
    let done = false;
    const hit = (e: Event) => {
      // Untrusted edges are the software driving the exhibit, not a visitor.
      if (done || !e.isTrusted) return;
      done = true;
      noteInput();
      off();
    };
    const off = () => {
      try { stage?.removeEventListener('pointerdown', hit, true); } catch { /* noop */ }
      try { window.removeEventListener('keydown', hit, true); } catch { /* noop */ }
    };
    // Capture phase, so an edge is witnessed before any handler can stop it
    // propagating — several of the touch and lock handlers do exactly that.
    stage?.addEventListener('pointerdown', hit, true);
    // Keys never reach the stage element: a keyboard-only exhibit is driven
    // from a window-level keydown (useStreamInput), so that is where the first
    // key edge for those stations has to be seen.
    window.addEventListener('keydown', hit, true);
    return off;
  }, [live, stageRef, noteInput]);
}
