// ============================================================================
//  analytics/catalogue/typein — the type-in code editor on BASIC machines.
//  ---------------------------------------------------------------------------
//  One area per file so a parallel wave of instrumentation work has no shared
//  editing surface. See catalogue/types.ts for what each field means and
//  catalogue/index.ts for how these merge.
//
//  The question these answer is the operator's: is the editor used, and how —
//  do visitors bring their own listing (paste, file) or open ours (examples),
//  and do the runs they start finish? Nothing about the CONTENT leaves the tab:
//  no text, no file name, no example id. The only size is a bucketed line
//  count, which says how long listings are — the number the pacing work needs.
//
//  Typing itself is synthetic input (useStreamControl.typeText brackets it with
//  withSyntheticInput), so a run's thousands of key edges never count as
//  `station.key.used`; these probes are the editor's own record of it.
// ============================================================================

import type { FlowSpec, MetricSpec, ProbeSpec } from './types.ts';

export const TYPEIN_PROBES = {
  'typein.editor.opened': {
    area: 'keyboard',
    owner: 'src/ui/typein/useTypeInEditor.ts',
    what: 'a visitor opened the type-in code editor on a BASIC machine',
    grades: ['act'],
  },
  'typein.text.pasted': {
    area: 'keyboard',
    owner: 'src/ui/typein/TypeInEditor.tsx',
    what: 'a visitor pasted a listing into the editor — the clipboard-to-keystrokes ask, met without a helper tool',
    grades: ['act'],
  },
  'typein.file.opened': {
    area: 'keyboard',
    owner: 'src/ui/typein/TypeInEditor.tsx',
    what: 'a visitor loaded a plain-text listing from their own device',
    grades: ['act'],
  },
  'typein.example.loaded': {
    area: 'keyboard',
    owner: 'src/ui/typein/TypeInEditor.tsx',
    what: 'a visitor opened one of the machine\'s example programs (or its demo listing) into the editor',
    grades: ['act'],
  },
  'typein.ascii.folded': {
    area: 'keyboard',
    owner: 'src/ui/typein/TypeInEditor.tsx',
    what: 'a listing arrived with typographic characters the machine cannot receive and the visitor let the editor replace them',
    grades: ['act'],
  },
  'typein.run.completed': {
    area: 'keyboard',
    owner: 'src/ui/typein/useTypeInEditor.ts',
    what: 'a whole listing was typed into the machine without being stopped or cut off',
    grades: ['show', 'auto'],
  },
  'typein.run.stopped': {
    area: 'keyboard',
    owner: 'src/ui/typein/useTypeInEditor.ts',
    what: 'a visitor pressed Stop during a run',
    grades: ['act'],
  },
  'typein.manual.opened': {
    area: 'keyboard',
    owner: 'src/ui/typein/TypeInEditor.tsx',
    what: 'a visitor followed a link to the machine\'s own manual from the editor',
    grades: ['act'],
  },
  'poster.manual.opened': {
    area: 'poster',
    owner: 'src/ui/ExhibitPoster.tsx',
    what: 'a visitor followed a link to the machine\'s own manual from its exhibit notes',
    grades: ['act'],
  },
} as const satisfies Record<string, ProbeSpec>;

export const TYPEIN_FLOWS = {
  // `start` is the click on Type; `typed` the last line's ENTER. The drop-off
  // splits by reason: `stopped` (the visitor's Stop), `disconnected` (the
  // stream went away mid-run), `error`.
  'typein.run': {
    area: 'keyboard',
    what: 'typing a listing from the editor into the machine, from the click to the last line',
    steps: ['start', 'typed'],
  },
} as const satisfies Record<string, FlowSpec>;

export const TYPEIN_METRICS = {
  'typein.run.lineCount': {
    area: 'keyboard',
    owner: 'src/ui/typein/useTypeInEditor.ts',
    what: 'a high value means visitors type long listings, so per-station pacing and the daemon\'s key queue must hold across hundreds of lines, not a five-line demo',
    scale: 'count',
  },
} as const satisfies Record<string, MetricSpec>;
