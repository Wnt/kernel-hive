// ============================================================================
//  analytics/catalogue/walkin — the walk-in plane and the on-screen keyboard
//  ---------------------------------------------------------------------------
//  One area per file so a parallel wave of instrumentation work has no shared
//  editing surface. See catalogue/types.ts for what each field means and
//  catalogue/index.ts for how these merge; the rules that make a declaration
//  worth making — and the gate that stops a declared-but-uncalled probe from
//  reading as a dead feature — are in the index.
// ============================================================================

import type { FlowSpec, MetricSpec, ProbeSpec } from './types.ts';

export const WALKIN_PROBES = {
  'keyboard.osk.used': {
    area: 'keyboard',
    owner: 'src/ui/keyboard/OnScreenKeyboard.tsx',
    what: 'a key was pressed on the ON-SCREEN keyboard, not a physical one',
    grades: ['act'],
  },
} as const satisfies Record<string, ProbeSpec>;

export const WALKIN_FLOWS = {} as const satisfies Record<string, FlowSpec>;

export const WALKIN_METRICS = {} as const satisfies Record<string, MetricSpec>;
