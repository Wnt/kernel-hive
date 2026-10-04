import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { RefObject } from 'react';
import type { StreamControlHandle } from '../../three/useStreamControl';
import type { TypeInConfig, TypeInDoc } from '../../types';
import { demoProgramFor, typeInFor } from '../../data/demoPrograms';
import { useTypeInDoc } from '../../data/posterDocs';
import { beginFlow, reach, recordMetric } from '../../analytics';
import type { FlowHandle } from '../../analytics/flows';
import type { Attrs } from '../../analytics/trace';
import type { TypingProgress } from '../grid/StreamView/typeDemoProgram';
import { dialectSpec, type DialectSpec } from './basicDialects';
import { keywordMachineFor, type KeywordMachine } from './keywordEntry';
import { checkListing, cleanListing, estimateMs, type ListingCheck } from './listingText';
import { paceFor, typeListing } from './typeInRun';

// ---------------------------------------------------------------------------
//  useTypeInEditor — the type-in code editor's state, owned by StreamView so a
//  listing survives closing and reopening the panel.
//
//  WHICH STATIONS: data only. A registry `typeIn` block (validated against the
//  station's drain rate) is the whole opt-in; no id is ever checked here.
//
//  TYPING goes through the same paced engine as the demo listing (typeLines:
//  one character per typeText call, the station's per-character wait between
//  them), never one typeText(wholeText) burst. Stop aborts the wait in flight
//  and the engine checks before every key, so nothing leaves after Stop. A
//  dropped stream stops the run the same way, and the run never STARTS without
//  a live, open stream.
// ---------------------------------------------------------------------------

type RunState = 'idle' | 'typing' | 'done' | 'stopped' | 'disconnected' | 'error';

export interface TypeInEditorModel {
  readonly osId: string;
  readonly config: TypeInConfig;
  readonly spec: DialectSpec;
  /** The keyword transcoder, on a keyword-entry machine (zxspectrum, zx81). */
  readonly keywords: KeywordMachine | undefined;
  readonly text: string;
  setText(text: string): void;
  /** Replace the listing (asks first when the visitor has unsaved edits). */
  load(text: string, label: string): boolean;
  readonly sourceLabel: string | null;
  readonly demoText: string | null;
  readonly demoLabel: string | null;
  readonly doc: TypeInDoc | undefined;
  readonly check: ListingCheck;
  readonly estimateMs: number;
  readonly run: RunState;
  readonly progress: TypingProgress | null;
  /** Why the Type button is off, or null when it is on. */
  readonly blocked: string | null;
  start(): void;
  stop(): void;
}

const DRAFT_KEY = (osId: string) => `kh.typein.draft.${osId}`;

function readDraft(osId: string): string | null {
  try { return window.localStorage.getItem(DRAFT_KEY(osId)); } catch { return null; }
}

function writeDraft(osId: string, text: string): void {
  try {
    if (text.trim()) window.localStorage.setItem(DRAFT_KEY(osId), text);
    else window.localStorage.removeItem(DRAFT_KEY(osId));
  } catch { /* private mode / blocked storage: the draft just does not persist */ }
}

export function useTypeInEditor({
  osId, streamable, controlRef, inputReady, otherTypistBusy, stationAttrs,
}: {
  osId: string;
  streamable: boolean;
  controlRef: RefObject<StreamControlHandle | null>;
  /** A live picture AND an open input channel. */
  inputReady: boolean;
  /** The demo typist is running — two typists would interleave their keys. */
  otherTypistBusy: boolean;
  stationAttrs: Attrs;
}): { available: boolean; open: boolean; toggle: () => void; close: () => void; typing: boolean; model: TypeInEditorModel | null } {
  const config = streamable ? typeInFor(osId) : undefined;
  const demo = config ? demoProgramFor(osId) : undefined;
  const demoText = demo ? demo.lines.join('\n') : null;

  const [open, setOpen] = useState(false);
  const [text, setTextState] = useState<string>(() => (config ? readDraft(osId) ?? demoText ?? '' : ''));
  // What the editor last LOADED: the visitor's edits are whatever differs.
  const [baseline, setBaseline] = useState<string>(() => (config && readDraft(osId) == null ? demoText ?? '' : ''));
  const [sourceLabel, setSourceLabel] = useState<string | null>(() =>
    config && readDraft(osId) == null && demo ? demo.label : null);
  const [run, setRun] = useState<RunState>('idle');
  const [progress, setProgress] = useState<TypingProgress | null>(null);

  const textRef = useRef(text);
  textRef.current = text;
  const abortRef = useRef<AbortController | null>(null);
  const flowRef = useRef<FlowHandle | null>(null);
  const goneRef = useRef(false);
  useEffect(() => () => {
    goneRef.current = true;
    abortRef.current?.abort();
    flowRef.current?.close();
  }, []);

  // Examples and manuals are runtime content (poster-docs.json): fetched the
  // first time the panel opens, never for a visitor who does not.
  const [everOpened, setEverOpened] = useState(false);
  const doc = useTypeInDoc(osId, !!config && everOpened);
  // A station with no demo listing opens on its first example, once, if the
  // visitor has nothing of their own in the editor yet.
  const seeded = useRef(false);
  useEffect(() => {
    if (seeded.current || !doc) return;
    seeded.current = true;
    const first = doc.examples[0];
    if (first && !textRef.current.trim()) {
      setTextState(first.text);
      setBaseline(first.text);
      setSourceLabel(first.title);
    }
  }, [doc]);

  // An edit after a run starts a new one: the "Typed 12 lines" line described
  // the listing as it WAS, not the one now in the editor.
  const setText = useCallback((next: string) => {
    setTextState(next);
    writeDraft(osId, next);
    setRun((r) => (r === 'typing' ? r : 'idle'));
  }, [osId]);

  const load = useCallback((next: string, label: string) => {
    const dirty = textRef.current.trim() !== '' && textRef.current !== baseline;
    if (dirty && !window.confirm(`Replace your listing with “${label}”? Your edits will be lost.`)) return false;
    const clean = cleanListing(next);
    setTextState(clean);
    setBaseline(clean);
    setSourceLabel(label);
    writeDraft(osId, '');
    setRun('idle');
    return true;
  }, [baseline, osId]);

  const toggle = useCallback(() => {
    setOpen((was) => {
      if (!was) setEverOpened(true);
      return !was;
    });
  }, []);
  // Reported outside the updater: StrictMode runs updaters twice (ANALYTICS.md §11).
  const wasOpen = useRef(false);
  useEffect(() => {
    if (open && !wasOpen.current) reach('typein.editor.opened', 'act');
    wasOpen.current = open;
  }, [open]);
  const close = useCallback(() => setOpen(false), []);

  const spec = useMemo(() => dialectSpec(config?.dialect ?? 'cbm-basic'), [config?.dialect]);
  const keywordDialect = config?.dialect === 'sinclair-basic' || config?.dialect === 'zx81-basic';
  const keywords = useMemo(() => (keywordDialect ? keywordMachineFor(osId) : undefined), [keywordDialect, osId]);
  const check = useMemo(() => checkListing(text, config ?? {}, spec, keywords), [text, config, spec, keywords]);
  const pace = useMemo(() => (config ? paceFor(config, check.lines) : null), [config, check.lines]);
  const estimate = pace ? estimateMs(check.keystrokes, pace) : 0;

  const typing = run === 'typing';
  const blocked = typing ? 'Typing…'
    : !inputReady ? 'Waiting for the machine to connect'
    : otherTypistBusy ? 'The demo program is being typed'
    : check.lines.length === 0 ? 'Nothing to type yet'
    : check.bad.length > 0 ? 'Some characters cannot be typed on this machine'
    : keywordDialect && !keywords ? 'This machine has no key table for its keywords'
    : check.keywordIssues.length > 0 ? 'Some of the listing cannot be typed on this machine'
    : null;

  const start = useCallback(() => {
    const handle = controlRef.current;
    if (!config || abortRef.current || blocked) return;
    if (!handle || !handle.isConnected()) { setRun('disconnected'); return; }
    const lines = checkListing(textRef.current, config, spec, keywords).lines;
    const abort = new AbortController();
    abortRef.current = abort;
    const flow = beginFlow('typein.run');
    flow.tag(stationAttrs);
    flowRef.current = flow;
    recordMetric('typein.run.lineCount', lines.length);
    setRun('typing');
    setProgress({ line: 0, lines: lines.length, chars: 0, totalChars: 0 });
    void typeListing({ osId, config, spec, keywords, lines, handle, signal: abort.signal, onProgress: setProgress })
      .then((outcome) => {
        if (outcome === 'done') {
          flow.step('typed');
          flow.ok();
          reach('typein.run.completed', 'show');
        } else flow.fail(outcome);
        if (!goneRef.current) setRun(outcome);
      })
      .catch(() => {
        flow.fail('error');
        if (!goneRef.current) setRun('error');
      })
      .finally(() => {
        abortRef.current = null;
        flowRef.current = null;
      });
  }, [config, blocked, controlRef, spec, keywords, osId, stationAttrs]);

  const stop = useCallback(() => {
    if (!abortRef.current) return;
    reach('typein.run.stopped', 'act');
    abortRef.current.abort();
  }, []);

  // The Stop button must still answer while the panel is closed: closing it
  // mid-run stops the run rather than leaving keys flowing behind a hidden UI.
  useEffect(() => { if (!open) abortRef.current?.abort(); }, [open]);

  if (!config) return { available: false, open: false, toggle, close, typing: false, model: null };
  return {
    available: true,
    open,
    toggle,
    close,
    typing,
    model: {
      osId, config, spec, keywords, text, setText, load, sourceLabel,
      demoText, demoLabel: demo?.label ?? null, doc, check,
      estimateMs: estimate, run, progress, blocked, start, stop,
    },
  };
}
