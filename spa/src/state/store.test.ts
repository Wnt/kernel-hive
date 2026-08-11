// Soft hide (registry `listing` -> manifest `listed: false`) has exactly one
// property worth protecting, and it is the one that rots: a hidden exhibit is
// ABSENT FROM EVERY LISTING but STILL RESOLVABLE BY ID, so /os/<id> keeps
// streaming. The obvious "fix" — dropping the row before it reaches the store —
// passes any grid assertion and silently breaks the direct URL, which is the
// entire point of the feature. So this file pins both halves at once, against
// the REAL generated manifest, not a fixture that could drift from it.
//
// It is discoverability, never access control: the hidden row ships in the
// public manifest and anyone holding the URL gets in.
import { beforeEach, describe, expect, it } from 'vitest';
import manifestDocument from '../../../scripts/serve/webroot/gallery-manifest.json' with { type: 'json' };
import appSource from '../App.tsx?raw';
import gridSource from '../ui/grid/GridView.tsx?raw';
import hallSource from '../scene/SceneV2.tsx?raw';
import { validateGalleryManifest } from '../data/galleryManifest';
import { storedLineup } from '../data/useManifest';
import { useMuseum } from './store';
import type { EnrichedVM } from '../types';

const manifest = validateGalleryManifest(manifestDocument);
if (!manifest) throw new Error('generated gallery manifest failed validation');

const stored = storedLineup(manifest.entries);
const hiddenIds = stored.filter((vm) => vm.listed === false).map((vm) => vm.id);

// Fixtures rather than named real stations: every hide in the registry today is
// meant to be deleted again (the spike lands, the phone dock ships), and a test
// that only works while some station happens to be hidden would go red on the day
// the feature is used correctly.
const sample = manifest.entries[0];
const listedRow: EnrichedVM = { ...sample, id: 'fixture-listed', listed: undefined };
const hiddenRow: EnrichedVM = { ...sample, id: 'fixture-hidden', listed: false };
const posterRow: EnrichedVM = { ...sample, id: 'fixture-poster', transport: 'showcase' };

describe('storedLineup — what is allowed to reach the store', () => {
  it('drops showcase posters but KEEPS soft-hidden tiles', () => {
    // The distinction the whole feature rests on. A poster has no station behind
    // it, so there is nothing to resolve; a hidden station is alive, and dropping
    // its row here is exactly the deployment-only workaround this replaced —
    // it would take /os/<id> down with it.
    expect(storedLineup([listedRow, hiddenRow, posterRow]).map((vm) => vm.id))
      .toEqual(['fixture-listed', 'fixture-hidden']);
  });
});

describe('museum store lineups', () => {
  beforeEach(() => useMuseum.getState().setVMs([]));

  it('keeps a hidden tile out of the listed lineup but resolvable by id', () => {
    useMuseum.getState().setVMs([listedRow, hiddenRow]);
    const { vms, listedVms } = useMuseum.getState();
    // Absent from what the grid and the hall render (and from their counts)...
    expect(listedVms.map((vm) => vm.id)).toEqual(['fixture-listed']);
    // ...but still there for /os/:osId to find. This is the direct-URL property.
    expect(vms.map((vm) => vm.id)).toEqual(['fixture-listed', 'fixture-hidden']);
    expect(vms.find((vm) => vm.id === 'fixture-hidden')).toBeDefined();
  });

  it('defaults to listed, so an entry without the field is unaffected', () => {
    useMuseum.getState().setVMs([listedRow]);
    expect(useMuseum.getState().listedVms).toEqual([listedRow]);
  });

  it('honours the shipped manifest, which flags hidden rows and only those', () => {
    // Also pins the empty-diff promise: the generator emits `listed` for hidden
    // rows alone, so adding the field cost every other station nothing.
    expect(stored.filter((vm) => vm.listed !== undefined).map((vm) => vm.id)).toEqual(hiddenIds);
    useMuseum.getState().setVMs(stored);
    const { vms, listedVms } = useMuseum.getState();
    expect(listedVms).toHaveLength(stored.length - hiddenIds.length);
    for (const id of hiddenIds) {
      expect(listedVms.some((vm) => vm.id === id)).toBe(false);
      expect(vms.some((vm) => vm.id === id)).toBe(true);
    }
  });
});

// The store can only keep that promise if the listing surfaces actually read
// `listedVms`. Nothing else in a node-env unit suite can bind a React render
// site to a store field, and switching one back to `vms` would quietly put the
// hidden stations back on the floor with no test going red — so assert it against
// the source text (imported through Vite's ?raw, hence no node typings).
describe('listing surfaces read the listed lineup', () => {
  it.each([
    ['grid', gridSource],
    ['3D hall', hallSource],
  ])('%s renders listedVms and never the full lineup', (_name, text) => {
    expect(text).toMatch(/\.listedVms\b/);
    expect(text).not.toMatch(/\.vms\b/);
  });

  it('the /os/:osId route still resolves against the full lineup', () => {
    expect(appSource).toMatch(/\.vms\b/);
  });
});
