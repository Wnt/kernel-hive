import type { Transport } from '../../three/archetypeRegistry';
import type { Session } from '../../data/session';

// ============================================================================
//  grid/exhibitAccess — what `/os/:osId` shows THIS session for THIS exhibit.
//  ---------------------------------------------------------------------------
//  A visitor who opens an exhibit they cannot drive used to land on one of two
//  dead ends: StreamView's own stub ("Showcase exhibit — a poster and placard
//  only. Not interactively streamable in this build.") for a `showcase`
//  transport, or — for a `walkin` session — a silent `<Navigate to="/" />`
//  that threw the URL away. Neither is the exhibit's own NOTES (the rich
//  ExhibitPoster: year, lineage, RAM, a real screenshot), which is the honest
//  answer to "what is this thing" either way.
//
//  Two independent reasons a visitor cannot be handed the live stream:
//
//    1. NOBODY can drive it — `transport === 'showcase'`, a poster/placard
//       exhibit with no live station behind it at all (2 of 96 today: macos,
//       riscos — `three/archetypeRegistry.ts`'s own count).
//    2. THIS role cannot drive ANY streamable exhibit at `/os/:osId` — a
//       walk-in account and an anonymous stranger each get exactly ONE
//       interactive surface, and it is not this one: a walk-in's is their own
//       `/walkin/play/<os>` clone of the three walk-in-designated stations
//       (`isPlayableByWalkin`, ./lineup.ts), an anonymous stranger's is the
//       landing hero's own claimed cell. `scripts/serve/auth/gate.py`'s
//       `walkin_allows`/`anon_allows` refuse `/signal/<osId>.json` for
//       anything but the caller's OWN claimed clone's signal path — so even a
//       walk-in-designated station is unreachable at the SHARED museum's
//       `/os/<id>` (lineup.test.ts already documents this for the grid card:
//       "never offers a walk-in a station stream — the gate would refuse
//       it"). `isPlayableByWalkin` therefore does NOT gate this decision —
//       admin/viewer are the only roles this route ever streams to.
//
//  Either way the honest answer is the exhibit's own notes (ExhibitPoster,
//  mounted as the ROUTE's content rather than an overlay on top of one, so
//  the URL stays real, shareable and reload-safe) — never a dead end, never a
//  redirect that drops the address. `stub` survives as the fallback for the
//  one gap notes cannot fill: no poster document exists for this id (measured
//  2026-09-10: 0 of 96 — every registry/posters/*.md has a matching station).
// ============================================================================

export type ExhibitView = 'stream' | 'notes' | 'stub';

/**
 * Should `/os/:osId` stream this exhibit, show its notes, or fall back to the
 * old stub? `hasPoster` comes from `data/posterIndex.ts` (`posterFor(osId) !==
 * undefined`), a generated, synchronous existence check — no fetch needed to
 * decide which view to render.
 */
export function exhibitViewFor(
  role: Session['role'],
  transport: Transport,
  hasPoster: boolean,
): ExhibitView {
  const drivable = transport !== 'showcase' && (role === 'admin' || role === 'viewer');
  if (drivable) return 'stream';
  return hasPoster ? 'notes' : 'stub';
}
