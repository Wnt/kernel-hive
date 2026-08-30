import { WALKIN_OS_IDS } from '../../walkin/fixture';

// The two role-sensitive decisions the merged grid makes, pulled out of the
// component so they can be tested as what they are: rules, not rendering.
//
// Neither of them is access control — the gate is (scripts/serve/auth/gate.py),
// and it refuses a walk-in `/gallery-manifest.json`, `/fleet-table.json` and
// every `/signal/<station>.json` whatever this file returns. What these decide
// is whether the visitor is shown a door they can walk through or one that
// would slam. A button that looks pressable and then refuses teaches the
// visitor the site is broken; a placard teaches them the museum is bigger than
// the three machines they came for (WALKIN-BRIEF §7).

/** What a walk-in is looking at: the machines they can drive, or the whole hall. */
export type WalkinScope = 'playable' | 'all';

/** The stations a walk-in may actually be handed a private clone of. */
const PLAYABLE = new Set<string>(WALKIN_OS_IDS);

export function isPlayableByWalkin(osId: string): boolean {
  return PLAYABLE.has(osId);
}

export type CardTarget =
  /** The museum's own station console, /os/<id>. */
  | { kind: 'stream'; to: string }
  /** This visitor's private clone, /walkin/play/<os>. */
  | { kind: 'clone'; to: string }
  /** No live surface for this visitor: open the placard in place. */
  | { kind: 'placard' };

/** Where a card goes, per visitor class. */
export function cardTarget(osId: string, walkin: boolean): CardTarget {
  if (!walkin) return { kind: 'stream', to: `/os/${osId}` };
  if (isPlayableByWalkin(osId)) return { kind: 'clone', to: `/walkin/play/${osId}` };
  return { kind: 'placard' };
}

/**
 * Which rows the grid shows.
 *
 * The scope switch only ever NARROWS: `all` is whatever the store already
 * holds, and for a walk-in the store holds the server's allowlist projection
 * (`/walkin/manifest.json`), never the fleet manifest. So widening the scope
 * cannot reveal a station the projection did not already carry — the fence is
 * the projection, and this is a view control inside it.
 */
export function visibleLineup<T extends { id: string }>(
  vms: readonly T[],
  walkin: boolean,
  scope: WalkinScope,
): T[] {
  if (!walkin || scope === 'all') return [...vms];
  return vms.filter((vm) => isPlayableByWalkin(vm.id));
}
