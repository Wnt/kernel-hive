import { useCallback, useEffect, useRef, useState } from 'react';
import type { RefObject } from 'react';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import type { DemoProgram } from '../../../types';
import { demoProgramFor } from '../../../data/demoPrograms';
import { keyboardFor } from '../../../data/keyboards';
import { typeDemoProgram } from './typeDemoProgram';

// ---------------------------------------------------------------------------
//  useDemoProgram — stage-menu state for "type in a demo program".
//
//  Which tiles have one is DATA (registry demoProgram → data/demoPrograms.ts),
//  never an id check here: a tile without a listing simply gets no menu row.
//
//  States mirror useRestoreFlow's busy/err vocabulary, so the menu row can be
//  disabled while typing and cannot double-fire.
// ---------------------------------------------------------------------------

export type DemoState = 'idle' | 'typing' | 'err';

export function useDemoProgram({
  osId, streamable, controlRef,
}: {
  osId: string;
  streamable: boolean;
  controlRef: RefObject<StreamControlHandle | null>;
}): {
  program: DemoProgram | undefined;
  state: DemoState;
  typeIn: () => void;
} {
  const program = streamable ? demoProgramFor(osId) : undefined;
  const [state, setState] = useState<DemoState>('idle');
  // Flipped on unmount so an in-flight typing loop stops keying into a torn-down
  // session instead of running to completion against a dead handle.
  const goneRef = useRef(false);
  // Authoritative re-entry guard: the menu row is disabled while typing, but a
  // second click must not be able to interleave two listings either way.
  const busyRef = useRef(false);
  useEffect(() => () => { goneRef.current = true; }, []);

  const typeIn = useCallback(() => {
    if (!program || busyRef.current) return;
    const handle = controlRef.current;
    if (!handle) { setState('err'); return; }
    busyRef.current = true;
    setState('typing');
    void typeDemoProgram({
      program, handle, keyboard: keyboardFor(osId), cancelled: () => goneRef.current,
    })
      .then(() => { if (!goneRef.current) setState('idle'); })
      .catch(() => { if (!goneRef.current) setState('err'); })
      .finally(() => { busyRef.current = false; });
  }, [program, osId, controlRef]);

  return { program, state, typeIn };
}
