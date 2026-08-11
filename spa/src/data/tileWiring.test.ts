import { describe, expect, it } from 'vitest';
import manifest from '../../../scripts/serve/webroot/gallery-manifest.json' with { type: 'json' };
import { ASSEMBLIES_BY_TILE } from '../scene/machines';
import { EXHIBIT_IDENTITIES } from '../scene/machineIdentity';
import { OS_FAMILY } from '../ui/keyboard/keyboardProfiles';
import { posterFor } from './posters';

// ---------------------------------------------------------------------------
//  A tile in the registry lineup is not a finished exhibit. Landing one means
//  wiring it into several places the registry generator does NOT write, and
//  every one of them has been forgotten at least once:
//
//    - OS_FAMILY            -> covered by keyboardProfiles.test.ts
//    - ASSEMBLIES_BY_TILE   -> covered by machines.test.ts
//    - EXHIBIT_IDENTITY     -> a type-level Record exhaustiveness check, so it
//                              fails `npm run build` and NOTHING else. A branch
//                              could be green on the whole vitest suite and
//                              still not compile. That is what this file is for.
//    - posters              -> registry/posters/<id>.md and the 1024x768 hero
//                              at spa/public/posters/<id>/desktop.webp. mpf2
//                              shipped with neither. Their presence on disk is
//                              enforced by `tiles-registry.py validate`; here we
//                              check the poster reached the generated SPA data.
//
//  Everything here is checked against the GENERATED manifest, so adding a tile
//  to the registry is what turns these red — the reminder arrives with the
//  work, not after someone notices the exhibit looks wrong.
// ---------------------------------------------------------------------------

const streamhostTiles = [...manifest.entries]
  .sort((a, b) => a.order - b.order)
  .filter((e) => e.transport === 'streamhost');

// The visitor-facing museum copy, straight from the manifest the SPA fetches at
// runtime (registry/tiles/<id>.json `museum` is the hand-written source).
type MuseumCopy = {
  id: string;
  lineage: string;
  arch: string;
  blurb?: string;
  ramMB?: number;
  ramKB?: number;
};
const museumRows: MuseumCopy[] = manifest.entries;

describe('every production tile is fully wired into the SPA', () => {
  it('has entries in the lineup at all (guards against an empty manifest)', () => {
    expect(streamhostTiles.length).toBeGreaterThan(0);
  });

  it.each(streamhostTiles.map((e) => e.id))('%s has a scene exhibit identity', (id) => {
    // Missing entries here fail `npm run build` with a Record exhaustiveness
    // error and no test — this makes the same omission visible in the suite.
    expect(EXHIBIT_IDENTITIES[id as keyof typeof EXHIBIT_IDENTITIES]).toBeDefined();
  });

  it.each(streamhostTiles.map((e) => e.id))('%s has a machine assembly', (id) => {
    expect(ASSEMBLIES_BY_TILE[id as keyof typeof ASSEMBLIES_BY_TILE]).toBeDefined();
  });

  it.each(streamhostTiles.map((e) => e.id))('%s has a keyboard profile', (id) => {
    expect(OS_FAMILY[id]).toBeDefined();
  });

  it.each(streamhostTiles.map((e) => e.id))('%s has an exhibit poster', (id) => {
    // The .md and its hero image existing on disk is checked by
    // `tiles-registry.py validate`, which can see the filesystem; here we
    // assert the generated poster actually reached the SPA.
    expect(posterFor(id)).toBeDefined();
  });
});

describe('museum copy stays visitor-facing', () => {
  const RIG_WORDS = /\b(MAME|QEMU|streamhost|qcow2|kiosk|VICE|hatari|cap32|fs-uae|LinApple|snapshot|framebuffer|emulat\w*)\b/i;

  it.each(museumRows.map((m) => [m.id, m] as const))('%s: lineage is a heritage, not a paragraph', (_id, m) => {
    // "Windows NT 3.x", not four sentences. The long form belongs in the
    // poster prose; a card-sized field that runs to a paragraph swamps the
    // fields either side of it.
    expect(m.lineage.length).toBeLessThanOrEqual(120);
  });

  it.each(museumRows.map((m) => [m.id, m] as const))('%s: no rig detail in visitor-facing copy', (_id, m) => {
    // `notes` is operator-facing and may name the emulator; lineage/blurb/arch
    // are read by visitors and must describe the real machine only.
    for (const field of [m.lineage, m.blurb ?? '', m.arch]) {
      expect(field).not.toMatch(RIG_WORDS);
    }
  });

  it.each(museumRows.map((m) => [m.id, m] as const))('%s: has a blurb of its own', (_id, m) => {
    // A missing blurb leaves the placard bare — `notes` is operator-facing and
    // must never stand in for it in front of visitors.
    expect((m.blurb ?? '').trim().length).toBeGreaterThan(0);
  });

  it.each(museumRows.map((m) => [m.id, m] as const))('%s: states memory in a unit it can express', (_id, m) => {
    // ramMB is whole megabytes, so an 8-bit machine carrying 0 renders as
    // "0 MB" beside an arch line reading "64 KB". Sub-megabyte machines
    // declare ramKB instead.
    if (m.ramMB === 0) expect(m.ramKB, `${m.id}: ramMB 0 needs ramKB`).toBeGreaterThan(0);
  });
});
