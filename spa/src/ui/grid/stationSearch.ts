// ============================================================================
//  STATION SEARCH — the grid's client-side filter
//  ---------------------------------------------------------------------------
//  Four rules, and the reason it feels right is that the first two apply to
//  BOTH sides of the comparison:
//
//  1. TERMS, not strings. Text becomes runs of letters and runs of digits, so
//     "Windows 3.11", "win3.11" and "windows 3 11" all reduce to the same
//     terms. Splitting at the letter/digit boundary is what makes `win2000`,
//     `nt4`, `win31` and `98se` work without a single alias entry.
//  2. PREFIX per term, never substring. Substring search makes `3` match
//     "Windows 3.11", "NT 3.51", "Mac OS 7.5.3" and "A/UX 3.0.1" at once — the
//     `3` inside "7.5.3" is not what anybody meant, and a filter that behaves
//     that way reads as broken. A term prefix keeps `3` to the machines whose
//     version starts with 3, and still lets `win` reach "Windows".
//  3. AND across what was typed, OR inside one word's aliases. Every
//     whitespace-separated chunk must match; a chunk the alias table knows
//     (searchAliases.ts) matches if ANY of its phrases does.
//  4. A BARE NUMBER is a version or a year, so it is looked up only in the
//     fields that carry versions and years. Otherwise `3` also finds the
//     3.5 MHz Z80 in an `arch` string and the "OmniWeb 3" in an app list, and
//     `2000` finds every station in the 2000s.
//
//  The searchable text is assembled from the registry-derived manifest fields
//  only — no station fact is re-typed here. The two free-prose fields are
//  deliberately left out: `notes` is the operator's technical note (kiosk
//  distro, capture backend, MAME driver) and made half the fleet answer to
//  `linux`; `blurb` is curator prose thick with cross-references, and made
//  `windows 2000` match Windows XP. What is left is identity plus the curated
//  period-software lists, so `solitaire`, `netscape` and `workbench` still find
//  their machines without dragging the rest of the collection along.
// ============================================================================

import { SEARCH_ALIASES } from './searchAliases';

/** The manifest fields a station is searched by. Structural on purpose: the app
 *  passes EnrichedVM, the unit tests pass rendered manifest rows. */
export interface SearchableStation {
  id: string;
  displayName: string;
  year: number | string;
  lineage: string;
  arch: string;
  eraLabel?: string;
  periodBrowser?: string;
  eraSoftware?: readonly string[];
  iconicApps?: readonly string[];
}

/** One station's searchable terms, in the two pools rule 4 distinguishes. */
export interface StationTerms {
  /** Where a version or a year can legitimately live: name, lineage, year, label. */
  readonly versions: readonly string[];
  /** Those plus arch and the curated software lists — everything else. */
  readonly all: readonly string[];
}

/** All terms must prefix-match. */
type Phrase = readonly string[];
/** Any phrase may match — one typed word, or whatever it is an alias for. */
type Chunk = readonly Phrase[];
/** Every chunk must match. An empty query is an empty list: everything matches. */
export type StationQuery = readonly Chunk[];

const DIGITS = /^[0-9]+$/;

function fold(text: string): string {
  return text.toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g, '');
}

/** Lowercase runs of letters / runs of digits. "Windows 3.11" -> windows,3,11. */
export function terms(text: string): string[] {
  return fold(text).match(/[a-z]+|[0-9]+/g) ?? [];
}

/** How a typed word is looked up in SEARCH_ALIASES: folded, alphanumerics only. */
export function aliasKey(word: string): string {
  return fold(word).replace(/[^a-z0-9]+/g, '');
}

function sortedTerms(...text: string[]): string[] {
  return [...new Set(terms(text.join(' ')))].sort();
}

/** The term pools a station is matched against. */
export function stationTerms(vm: SearchableStation): StationTerms {
  const versions = sortedTerms(
    vm.id,
    vm.displayName,
    String(vm.year),
    vm.lineage,
    vm.eraLabel ?? '',
  );
  const all = [...new Set([...versions, ...terms([
    vm.arch,
    vm.periodBrowser ?? '',
    (vm.eraSoftware ?? []).join(' '),
    (vm.iconicApps ?? []).join(' '),
  ].join(' '))])].sort();
  return { versions, all };
}

/** Parse what was typed into chunks of alternative phrases. */
export function parseQuery(query: string): StationQuery {
  const chunks: Chunk[] = [];
  for (const word of query.split(/\s+/)) {
    if (!word) continue;
    // An alias REPLACES the word rather than widening it. "w2k" spelled out
    // term by term is w/2/k, three prefixes that reach half the collection; the
    // table already lists the literal spelling wherever it should still count
    // (`dos` keeps 'dos', `unix` keeps 'unix'), so a shorthand means exactly
    // what the table says it means and nothing more.
    const phrases: Phrase[] = [];
    for (const expansion of SEARCH_ALIASES[aliasKey(word)] ?? [word]) {
      const phrase = terms(expansion);
      if (phrase.length > 0) phrases.push(phrase);
    }
    if (phrases.length > 0) chunks.push(phrases);
  }
  return chunks;
}

/** Does this station's term pools satisfy the parsed query? */
export function matchesQuery(station: StationTerms, query: StationQuery): boolean {
  return query.every((chunk) => chunk.some(
    (phrase) => phrase.every((term) => {
      const pool = DIGITS.test(term) ? station.versions : station.all;
      return pool.some((candidate) => candidate.startsWith(term));
    }),
  ));
}
