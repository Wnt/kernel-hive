import { WALKIN_OS_IDS } from '../walkin/fixture';

// The three machines a stranger can drive, and the one line each earns on the
// switcher. Lifted verbatim from the retired walkin/WalkinLanding.tsx, whose
// three static cards this page replaces with one running machine plus a switch
// between them — the copy was right, it was the shape that was wrong.
//
// The IDS are not repeated here: WALKIN_OS_IDS is the list, in the order the
// door has always offered them, and a second copy is how the switcher would one
// day show a station the broker has never heard of.

export interface StationCopy {
  /** The name a visitor would say out loud. */
  name: string;
  /** Year · maker · shell — the placard line. */
  meta: string;
  /** Why this one is worth a minute of a stranger's time. */
  blurb: string;
  accent: string;
}

const COPY: Record<string, StationCopy> = {
  win311: {
    name: 'Windows 3.11',
    meta: '1993 · 386 PC · Program Manager',
    blurb: 'Tiled windows, Solitaire and a Program Manager full of icons — the desktop that put Windows in every office.',
    accent: '#7fb0d6',
  },
  os2warp: {
    name: 'OS/2 Warp 4',
    meta: '1996 · IBM · Workplace Shell',
    blurb: "IBM's answer to Windows 95: an object desktop, speech recognition on the box, and a following that never quite let go.",
    accent: '#1e5aa8',
  },
  rhapsody: {
    name: 'Rhapsody DR2',
    meta: '1998 · Apple · the road to Mac OS X',
    blurb: "NeXTSTEP wearing a Platinum face — Apple's developer release on the way to Mac OS X, complete with a Blue Box.",
    accent: '#8f8f9c',
  },
};

/** The switcher's stations, in the door's own order. */
export const HERO_STATIONS: readonly string[] = WALKIN_OS_IDS;

/**
 * Copy for a station id.
 *
 * Falls back to the id rather than to nothing, because the broker picks the
 * station on the random path and is allowed to enable a fourth one without this
 * file changing. An unknown machine should show up as itself, not vanish.
 */
export function stationCopy(os: string): StationCopy {
  return COPY[os] ?? { name: os, meta: 'from the collection', blurb: '', accent: '#9c4f35' };
}
