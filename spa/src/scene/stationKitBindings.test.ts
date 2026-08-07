import { describe, expect, it } from 'vitest';
import manifest from '../../../scripts/serve/webroot/gallery-manifest.json' with { type: 'json' };
import { computeHall, type HallEntry } from './hallLayout';
import {
  assemblyForTile,
  hasIntegratedKeyboard,
} from './machines';
import { buildStationKitBindings } from './stationKitBindings';

describe('station kit bindings', () => {
  it('never dresses an integrated-keyboard assembly with a spare keyboard', () => {
    const entries: HallEntry[] = manifest.entries.map((entry) => ({
      id: entry.id,
      displayName: entry.displayName,
      era_year: entry.era_year,
      order: entry.order,
    }));
    const layout = computeHall(entries);
    const bindings = buildStationKitBindings(layout);
    const spare = bindings.heroes.find((binding) => (
      binding.asset === 'spareKeyboard'
    ));
    const desk = layout.desks.find((candidate) => (
      spare?.id === `spare-keyboard:${candidate.id}`
    ));

    expect(spare).toBeDefined();
    expect(desk).toBeDefined();
    expect(hasIntegratedKeyboard(assemblyForTile(
      desk!.entry.assemblyId ?? desk!.entry.id,
    ))).toBe(false);
    expect(bindings.cableCoils).toHaveLength(2);
    expect(bindings.cableCoils.every((binding) => (
      binding.id.startsWith(`spare-keyboard-cable:${desk!.id}:`)
    ))).toBe(true);
  });

  it('omits the spare and its cable when every available desk has an integrated keyboard', () => {
    const layout = computeHall([{
      id: 'apple2',
      era_year: 1988,
      order: 0,
      assemblyId: 'apple2',
    }]);
    const bindings = buildStationKitBindings(layout);

    expect(bindings.heroes).not.toEqual(expect.arrayContaining([
      expect.objectContaining({ asset: 'spareKeyboard' }),
    ]));
    expect(bindings.cableCoils).toEqual([]);
  });
});
