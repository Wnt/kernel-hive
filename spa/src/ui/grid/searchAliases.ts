// ============================================================================
//  SEARCH ALIASES — the ONE hand-written home for gallery search shorthand
//  ---------------------------------------------------------------------------
//  Everything a visitor can type that IS already a station fact — the name, the
//  year, the lineage, the arch, the era, the period software, the blurb — comes
//  from `registry/stations/<id>.json` via the rendered gallery manifest, and is
//  matched by stationSearch.ts. Nothing in this file may repeat one of those
//  values: the registry stays the single source for what a station IS.
//
//  What lives here is the other half — knowledge about ENGLISH SHORTHAND, which
//  is not a fact about any station: that "w2k" is how people write Windows 2000,
//  and that "unix" names a family no registry field spells out per entry. Those
//  are properties of the query, not of the exhibit, so a station-level field
//  would have been the wrong home (and would have had to be re-typed 15 times).
//
//  Keys are ALIAS KEYS: lowercased, every non-alphanumeric character removed
//  (stationSearch.aliasKey). Values are PHRASES, tried as alternatives — a chunk
//  matches when ANY one of its phrases matches, and a phrase matches when ALL of
//  its terms prefix-match something in the station's text.
//
//  Deliberately small. stationSearch splits terms at letter/digit boundaries, so
//  `nt4`, `win3`, `win31`, `win311`, `98se`, `xp`, `3.11` and `windows2000`
//  already land on the right station with no entry here. Add an alias only for a
//  shorthand whose letters appear NOWHERE in the station's own words.
// ============================================================================

// The UNIX family, spelled as the words that identify a member in its own
// registry text (see the note on the `unix` key below).
const UNIX_FAMILY = [
  'unix', 'bsd', 'osf', 'darwin', 'xnu',
  'irix', 'solaris', 'sunos', 'hp ux', 'aux', 'tru64', 'nextstep', 'rhapsody',
];

export const SEARCH_ALIASES: Readonly<Record<string, readonly string[]>> = {
  // ---- Windows shorthand. "win2000"/"win 2000" need nothing; "2k" does. ----
  w2k: ['windows 2000'],
  win2k: ['windows 2000'],
  w2000: ['windows 2000'],
  '2k': ['windows 2000'],
  wfw: ['windows 3.11'],            // Windows for Workgroups
  wfwg: ['windows 3.11'],
  '311': ['windows 3.11'],          // typed as "3.11", punctuation stripped
  win9x: ['windows 95', 'windows 98'],
  winnt: ['windows nt'],
  msft: ['microsoft'],

  // ---- DOS. "dos" alone already hits MS-DOS and the DOS-era label; FreeDOS
  //      spells its name as one word, so the prefix rule needs the whole word. --
  dos: ['dos', 'freedos'],
  msdos: ['ms dos'],
  pcdos: ['dos'],

  // ---- Mac. "Mac OS 7.5.3" is two words, "macOS Sequoia" is one — a visitor
  //      typing either spelling means both machines. ----
  macos: ['macos', 'mac os'],
  osx: ['mac os x', 'macos', 'rhapsody'],
  macosx: ['mac os x', 'macos', 'rhapsody'],
  classicmacos: ['mac os 7'],

  // ---- The UNIX family. No registry field declares family membership, and the
  //      honest answer is not one word: most members say "Unix" somewhere in
  //      their own lineage or blurb, and the rest are identified by the name of
  //      the Unix they ARE. Listing those names here (rather than a list of
  //      station ids) keeps the entry from rotting: a Unix station added
  //      tomorrow whose lineage says "Unix" matches with no edit to this file.
  //
  //      Judged in, from the registry text: IRIX/Indy, Tru64 (Digital UNIX),
  //      Solaris, SunOS, HP-UX, A/UX, NEWS-OS (4.3BSD), NeXTSTEP, Rhapsody,
  //      macOS (Darwin/XNU), 2.11BSD on the PDP-11, and the two from-scratch
  //      "Unix-like" hobby systems that describe themselves that way.
  //      Judged OUT: BeOS and Haiku (BeOS is not Unix and neither is its heir),
  //      QNX (a POSIX real-time microkernel, not of the family), and the Linux
  //      distributions — `linux` is its own query and already works. ----
  unix: UNIX_FAMILY,
  nix: UNIX_FAMILY,
  unices: UNIX_FAMILY,
};
