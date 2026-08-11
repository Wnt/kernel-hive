import { describe, expect, it } from 'vitest';
import { renderedEntries } from '../data/lineupFixture';
import { computeHall, type HallEntry } from './hallLayout';
import { shotFromUrl, shotNames } from './shots';

const entries: HallEntry[] = renderedEntries.map((entry) => ({
  id: entry.id,
  displayName: entry.displayName,
  era_year: entry.era_year,
  order: entry.order,
}));
const layout = computeHall(entries);

describe('generated hall shots', () => {
  it('retains every harness bookmark name', () => {
    expect(shotNames(layout)).toEqual(expect.arrayContaining([
      'entrance',
      'hallWide',
      'pineWall',
      'archiveWall',
      'lineup',
      'lineupOne',
      'corner',
      'deskSeated',
      'corridorFront',
      'corridorMiddle',
    ]));
  });

  it('aims archiveWall along the populated rear-wall run', () => {
    const archive = shotFromUrl('?shot=archiveWall', layout);
    expect(archive).not.toBeNull();
    expect(archive?.target[0]).toBe(0);
    expect(archive?.target[1]).toBeGreaterThan(1);
    expect(archive?.target[2]).toBeCloseTo(-layout.dims.depth / 2 + 0.24);
    expect(archive!.position[2] - archive!.target[2]).toBeGreaterThan(2);
  });

  it('generates front and three-quarter inspection pins for every desk', () => {
    const names = shotNames(layout);
    for (const desk of layout.desks) {
      expect(names).toContain(`desk-${desk.entry.id}-front`);
      expect(names).toContain(`desk-${desk.entry.id}-three4`);
    }
  });

  it('keeps dense-row and placard fixes scoped to their desk pins', () => {
    const nt351 = layout.desks.find((desk) => desk.entry.id === 'nt351')!;
    const nt351Front = shotFromUrl('?shot=desk-nt351-front', layout)!;
    const winxpThree4 = shotFromUrl('?shot=desk-winxp-three4', layout)!;
    const c64Front = shotFromUrl('?shot=desk-c64-front', layout)!;

    expect(nt351Front.position[0]).not.toBeCloseTo(nt351.pos[0]);
    expect(winxpThree4.target[1]).toBe(0.91);
    expect(c64Front.target[1]).toBe(0.96);
  });

  it('keeps every generated bookmark finite and inside the hall footprint', () => {
    for (const name of shotNames(layout)) {
      const shot = shotFromUrl(`?shot=${name}`, layout);
      expect(shot, name).not.toBeNull();
      for (const value of [...shot!.position, ...shot!.target]) {
        expect(Number.isFinite(value), name).toBe(true);
      }
      expect(Math.abs(shot!.position[0]), name).toBeLessThanOrEqual(layout.dims.width / 2);
      expect(Math.abs(shot!.position[2]), name).toBeLessThanOrEqual(layout.dims.depth / 2);
      expect(Math.abs(shot!.target[0]), name).toBeLessThanOrEqual(layout.dims.width / 2);
      expect(Math.abs(shot!.target[2]), name).toBeLessThanOrEqual(layout.dims.depth / 2);
    }
  });
});
