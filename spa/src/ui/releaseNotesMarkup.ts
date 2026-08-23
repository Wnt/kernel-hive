// The release notes' inline markup, tokenised for rendering.
//
// The authored prose in registry/release-notes/*.json may use exactly four
// constructs, and scripts/release_notes_markup.py validates them before any of
// it is published:
//
//     [Windows 3.11](station:win311)   a machine the reader can go and use
//     **ICQ**                          a product or piece of software
//     *AlphaServer ES40*               hardware, chips, eras
//     <u>...</u>                       one per week, that week's headline
//
// WHY TOKENS RATHER THAN HTML. The same authored string is published to GitHub
// markdown and to this page. Handing the raw string to dangerouslySetInnerHTML
// would make every future editor of a week file an author of markup that runs
// in the gallery, which is a bad trade for four constructs. Parsing to a small
// closed token union instead means anything the vocabulary does not cover is
// rendered as literal text — the failure mode is an ugly asterisk, never an
// injected tag.
//
// STATION LINKS RESOLVE HERE, NOT IN THE FILE. The prose carries the station
// ID; markdown expands it to an absolute gallery URL and this expands it to the
// SPA's own relative /os/<id> route. Relative is load-bearing: a staged UI
// served from /staging/<session>/ has its own router base, and an absolute URL
// would bounce a reviewer out of the staged copy and into production.
//
// This file is deliberately pure and DOM-free so vitest can exercise it under
// plain Node, the same arrangement as releaseNotesView.ts.

export type MarkupToken =
  | { kind: 'text'; text: string }
  | { kind: 'station'; text: string; id: string }
  | { kind: 'bold'; children: MarkupToken[] }
  | { kind: 'italic'; children: MarkupToken[] }
  | { kind: 'underline'; children: MarkupToken[] };

// Order matters: `**` must be tried before `*`, or every bold opener is read as
// an empty italic. Underline is non-greedy so two of them on one line cannot
// swallow the text between.
//
// Held as a SOURCE STRING and compiled per call, not as one shared /g regex.
// parseMarkup recurses into nested children, and a shared /g object carries
// `lastIndex` across those calls: the child's scan rewinds it, the parent's
// `exec` then re-matches the token it just consumed, and the loop never
// terminates. Resetting `lastIndex` on entry does not fix it — the child resets
// it too, and the parent is mid-iteration when that happens. A fresh regex per
// call has no shared state to corrupt.
const TOKEN_SOURCE =
  String.raw`\[([^\]\n]+)\]\(station:([a-z0-9]+)\)|\*\*([\s\S]+?)\*\*|<u>([\s\S]+?)<\/u>|\*([^*\n]+)\*`;

// Emphasis may nest one level (a station link inside the week's underline is the
// case that actually occurs). The guard is not about expected input — it is so a
// pathological or hand-edited string cannot recurse without bound in a viewer's
// browser.
const MAX_DEPTH = 4;

function push(tokens: MarkupToken[], text: string): void {
  if (!text) return;
  const last = tokens[tokens.length - 1];
  if (last?.kind === 'text') last.text += text;
  else tokens.push({ kind: 'text', text });
}

export function parseMarkup(text: string, depth = 0): MarkupToken[] {
  const tokens: MarkupToken[] = [];
  if (depth >= MAX_DEPTH) {
    push(tokens, text);
    return tokens;
  }
  const re = new RegExp(TOKEN_SOURCE, 'g');
  let cursor = 0;
  let match: RegExpExecArray | null;
  while ((match = re.exec(text)) !== null) {
    push(tokens, text.slice(cursor, match.index));
    const [whole, linkText, stationId, bold, underline, italic] = match;
    if (stationId !== undefined) tokens.push({ kind: 'station', text: linkText, id: stationId });
    else if (bold !== undefined) tokens.push({ kind: 'bold', children: parseMarkup(bold, depth + 1) });
    else if (underline !== undefined) tokens.push({ kind: 'underline', children: parseMarkup(underline, depth + 1) });
    else if (italic !== undefined) tokens.push({ kind: 'italic', children: parseMarkup(italic, depth + 1) });
    cursor = match.index + whole.length;
  }
  push(tokens, text.slice(cursor));
  return tokens;
}

/** The prose with every marker dropped — what a reader actually reads. Used for
 *  React keys and anywhere a plain string is needed. */
export function plainText(tokens: MarkupToken[]): string {
  return tokens
    .map((token) => (token.kind === 'text' || token.kind === 'station' ? token.text : plainText(token.children)))
    .join('');
}

/** Every station this prose links to, in order of first appearance. */
export function linkedStations(tokens: MarkupToken[]): string[] {
  const found: string[] = [];
  const walk = (list: MarkupToken[]): void => {
    for (const token of list) {
      if (token.kind === 'station') {
        if (!found.includes(token.id)) found.push(token.id);
      } else if (token.kind !== 'text') walk(token.children);
    }
  };
  walk(tokens);
  return found;
}

export function stationPath(id: string): string {
  return `/os/${id}`;
}
