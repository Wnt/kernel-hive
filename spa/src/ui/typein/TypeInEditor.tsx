import { useMemo, useRef, useState, type ClipboardEvent, type ReactNode } from 'react';
import { reach } from '../../analytics';
import { highlightLine, markBad, markOverflow, type Token } from './basicHighlight';
import { cleanListing, foldToAscii, formatDuration } from './listingText';
import type { TypeInEditorModel } from './useTypeInEditor';
import './TypeInEditor.css';

// ---------------------------------------------------------------------------
//  TypeInEditor — the panel: a plain <textarea> laid exactly over a highlighted
//  <pre>, so the browser keeps doing everything a text field does (selection,
//  undo, IME, paste, mobile keyboards) and the highlighting is paint only.
//  No editor dependency: the bundle had none, and a listing is a few hundred
//  short lines.
//
//  Keys typed here never reach the guest: useStreamInput's forwarder skips any
//  event whose target is a typing field (keyboardLock.isTypingField).
// ---------------------------------------------------------------------------

const KIND_LABEL: Record<string, string> = {
  draw: 'Draw', input: 'Input', game: 'Game', sound: 'Sound', other: 'Program',
};
const MAX_FILE_BYTES = 256 * 1024;

function Tokens({ tokens }: { tokens: readonly Token[] }) {
  return (
    <>
      {tokens.map((t, i) => (
        <span key={i} className={`ti-${t.kind}${t.over ? ' ti-over' : ''}`}>{t.text}</span>
      ))}
    </>
  );
}

// An invisible offender (a no-break space, a control character) is named by
// its code point, or the warning would point at nothing.
function showChar(ch: string): string {
  return /\s/.test(ch) || ch < ' ' ? `U+${(ch.codePointAt(0) ?? 0).toString(16).toUpperCase().padStart(4, '0')}` : ch;
}

// The registry's demo labels are menu sentences ("Type in a demo program
// (MSX-BASIC)"); in a list of programs the generic half is noise.
function demoOptionLabel(label: string | null): string {
  const rest = (label ?? '').replace(/^Type in a demo program\s*/i, '').trim();
  return !rest ? 'Demo listing' : rest.startsWith('(') ? `Demo listing ${rest}` : `Demo listing: ${rest}`;
}

function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}

function lineList(lines: readonly number[]): string {
  const shown = lines.slice(0, 6).join(', ');
  return lines.length > 6 ? `${shown}…` : shown;
}

export function TypeInEditor({ model, displayName, onClose }: {
  model: TypeInEditorModel;
  displayName: string;
  onClose: () => void;
}) {
  const preRef = useRef<HTMLPreElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const { config, spec, check, run, progress } = model;
  const typing = run === 'typing';

  const syncScroll = (ta: HTMLTextAreaElement) => {
    if (!preRef.current) return;
    preRef.current.scrollTop = ta.scrollTop;
    preRef.current.scrollLeft = ta.scrollLeft;
  };

  // A paste is cleaned (line ends, tabs, trailing blanks) but never stripped:
  // a character the machine cannot take stays visible and is flagged below.
  const onPaste = (e: ClipboardEvent<HTMLTextAreaElement>) => {
    const pasted = e.clipboardData.getData('text/plain');
    if (!pasted) return;
    e.preventDefault();
    const ta = e.currentTarget;
    const clean = cleanListing(pasted);
    const next = ta.value.slice(0, ta.selectionStart) + clean + ta.value.slice(ta.selectionEnd);
    const caret = ta.selectionStart + clean.length;
    model.setText(next);
    requestAnimationFrame(() => { ta.selectionStart = ta.selectionEnd = caret; });
    reach('typein.text.pasted', 'act');
  };

  const onFile = async (file: File | undefined) => {
    if (!file) return;
    if (file.size > MAX_FILE_BYTES) { setNotice(`${file.name} is too large for a type-in listing.`); return; }
    const text = await file.text();
    const controls = [...text].filter((ch) => ch < ' ' && ch !== '\n' && ch !== '\r' && ch !== '\t').length;
    if (text.includes('\0') || controls > 4) {
      setNotice(`${file.name} is a tokenised program, not a text listing. LIST it on a machine and copy the text instead.`);
      return;
    }
    if (model.load(text, file.name)) {
      setNotice(null);
      reach('typein.file.opened', 'act');
    }
  };

  const openExample = (value: string) => {
    if (value === 'demo' && model.demoText != null) {
      if (model.load(model.demoText, model.demoLabel ?? 'Demo program')) reach('typein.example.loaded', 'act');
      return;
    }
    const example = model.doc?.examples.find((ex) => ex.file === value);
    if (example && model.load(example.text, example.title)) reach('typein.example.loaded', 'act');
  };

  const fold = () => {
    const { text, changed } = foldToAscii(model.text);
    if (changed) { model.setText(text); reach('typein.ascii.folded', 'act'); }
  };

  const loadedExample = model.doc?.examples.find((ex) => ex.title === model.sourceLabel);
  const lines = model.text.split('\n');
  // What a keyword-entry machine cannot type, by editor line, painted red.
  const issueRanges = useMemo(() => {
    const byLine = new Map<number, { at: number; len: number }[]>();
    for (const issue of check.keywordIssues) {
      byLine.set(issue.line, [...(byLine.get(issue.line) ?? []), { at: issue.at, len: issue.text.length }]);
    }
    return byLine;
  }, [check.keywordIssues]);
  const pct = progress && progress.totalChars ? Math.min(100, Math.round((100 * progress.chars) / progress.totalChars)) : 0;

  let status: ReactNode;
  if (typing && progress) {
    status = <span>Typing line {Math.max(1, progress.line)} of {progress.lines}…</span>;
  } else if (run === 'done') {
    status = (
      <span className="ti-ok">
        Typed {plural(model.runLines, 'line')}. Click the picture, {spec.runHint ?? 'type RUN and press RETURN'}.
      </span>
    );
  } else if (run === 'stopped' && progress) {
    status = <span>Stopped at line {progress.line} of {progress.lines}. Nothing more was typed.</span>;
  } else if (run === 'disconnected') {
    status = <span className="ti-err">The connection dropped{progress ? ` at line ${progress.line}` : ''}, so typing stopped.</span>;
  } else if (run === 'error') {
    status = <span className="ti-err">Typing failed. Try again.</span>;
  } else if (check.lines.length) {
    status = <span>{plural(model.runLines, 'line')} · about {formatDuration(model.estimateMs)}</span>;
  }

  return (
    <section className="ti-panel" aria-label="Type-in editor">
      <header className="ti-head">
        <div className="ti-title">
          <strong>Type-in editor</strong>
          <span className="ti-sub">{spec.name} · {displayName}</span>
        </div>
        <button type="button" className="ti-close" onClick={onClose} aria-label="Close the editor" title="Close the editor">×</button>
      </header>

      <div className="ti-tools">
        <select
          className="ti-select"
          value=""
          disabled={typing}
          onChange={(e) => openExample(e.target.value)}
          aria-label="Open an example program"
        >
          <option value="">{model.doc ? 'Open an example…' : 'Examples loading…'}</option>
          {model.demoText != null && <option value="demo">{demoOptionLabel(model.demoLabel)}</option>}
          {model.doc?.examples.map((ex) => (
            <option key={ex.file} value={ex.file}>{KIND_LABEL[ex.kind] ?? 'Program'}: {ex.title}</option>
          ))}
        </select>
        <button type="button" className="ti-btn" disabled={typing} onClick={() => fileRef.current?.click()}>Open file…</button>
        <input
          ref={fileRef}
          type="file"
          accept=".bas,.txt,.lst,.asc,text/plain"
          hidden
          onChange={(e) => { void onFile(e.target.files?.[0]); e.target.value = ''; }}
        />
      </div>
      {loadedExample?.description && <p className="ti-note">{loadedExample.description}</p>}
      {config.hint && <p className="ti-hint">{config.hint}</p>}
      {notice && <p className="ti-warn" role="status">{notice}</p>}

      <div className="ti-code">
        <pre ref={preRef} className="ti-hl" aria-hidden="true">
          {lines.map((line, i) => (
            <span key={i}>
              <Tokens
                tokens={markOverflow(
                  markBad(highlightLine(line, spec, config.unreachable), issueRanges.get(i + 1) ?? []),
                  config.maxLineChars,
                )}
              />
              {'\n'}
            </span>
          ))}
          {' '}
        </pre>
        <textarea
          className="ti-input"
          value={model.text}
          readOnly={typing}
          onChange={(e) => model.setText(e.target.value)}
          onScroll={(e) => syncScroll(e.currentTarget)}
          onPaste={onPaste}
          wrap="off"
          spellCheck={false}
          autoCapitalize="off"
          autoCorrect="off"
          autoComplete="off"
          placeholder={'Paste or type a BASIC listing here, e.g.\n10 PRINT "HELLO"\n20 GOTO 10'}
          aria-label="BASIC listing"
        />
      </div>

      {check.bad.length > 0 && (
        <p className="ti-warn">
          {plural(check.bad.length, 'character')} cannot be typed on this machine:{' '}
          <span className="ti-badlist">{check.bad.map(showChar).join(' ')}</span>
          {' '}(line {lineList(check.badLines)}).
          {check.foldable > 0 && (
            <button type="button" className="ti-link" onClick={fold}>Replace typographic quotes and dashes</button>
          )}
        </p>
      )}
      {check.keywordIssues.length > 0 && (
        <div className="ti-warn" role="status">
          {check.keywordIssues.length === 1 ? 'This cannot be typed' : 'These cannot be typed'} on this machine as written:
          <ul className="ti-issues">
            {check.keywordIssues.slice(0, 4).map((issue) => (
              <li key={`${issue.line}:${issue.at}`}>
                line {issue.line}: <span className="ti-badlist">{issue.text}</span> ({issue.why})
              </li>
            ))}
            {check.keywordIssues.length > 4 && <li>and {check.keywordIssues.length - 4} more</li>}
          </ul>
        </div>
      )}
      {check.longLines.length > 0 && (
        <p className="ti-warn">
          Line {lineList(check.longLines)} {check.longLines.length === 1 ? 'is' : 'are'} longer than this machine's{' '}
          {config.maxLineChars}-character line; it would cut the end off.
        </p>
      )}
      {check.braceLines.length > 0 && (
        <p className="ti-warn">
          Magazine control codes like {'{CLR}'} (line {lineList(check.braceLines)}) are typed as written. Use CHR$ codes
          instead, e.g. PRINT CHR$(147) to clear the screen.
        </p>
      )}

      <footer className="ti-foot">
        {typing && <div className="ti-bar" aria-hidden="true"><span style={{ width: `${pct}%` }} /></div>}
        <div className="ti-row">
          <div className="ti-status" role="status" aria-live="polite">{status}</div>
          {typing ? (
            <button type="button" className="ti-btn ti-stop" onClick={model.stop}>■ Stop</button>
          ) : (
            <button
              type="button"
              className="ti-btn ti-go"
              disabled={!!model.blocked}
              title={model.blocked ?? 'Type this listing into the machine, one key at a time'}
              onClick={model.start}
            >
              ⌨ Type into machine
            </button>
          )}
        </div>
        <label className="ti-check">
          <input
            type="checkbox"
            checked={model.clearFirst}
            disabled={typing}
            onChange={(e) => model.setClearFirst(e.target.checked)}
          />
          Clear the machine's old program first ({spec.clearCommand})
        </label>
        {!typing && model.blocked && model.blocked !== 'Nothing to type yet' && (
          <p className="ti-note">{model.blocked}.</p>
        )}
        <p className="ti-note ti-tip">Plain-text listings (.bas, .txt), not tokenised .prg files. Paste with Ctrl+V or ⌘V.</p>
        {model.doc && model.doc.manuals.length > 0 && (
          <nav className="ti-manuals" aria-label="Manuals">
            <span>Manuals:</span>
            {model.doc.manuals.map((m) => (
              <a key={m.url} href={m.url} target="_blank" rel="noreferrer" title={m.note}
                onClick={() => reach('typein.manual.opened', 'act')}>
                {m.title}{m.lang && m.lang !== 'en' ? ` (${m.lang})` : ''}
              </a>
            ))}
          </nav>
        )}
      </footer>
    </section>
  );
}
