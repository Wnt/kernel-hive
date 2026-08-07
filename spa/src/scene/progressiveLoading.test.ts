import { describe, expect, it } from 'vitest';
import { computeHall, type HallEntry, type Point3 } from './hallLayout';
import {
  nextSectionToMount,
  rankSectionsByDistance,
  SECTION_LOAD_RADIUS,
} from './progressiveLoading';

const entries: HallEntry[] = [
  { id: 'early-a', era_year: 1981, order: 1 },
  { id: 'early-b', era_year: 1984, order: 2 },
  { id: 'middle-a', era_year: 1992, order: 3 },
  { id: 'middle-b', era_year: 1997, order: 4 },
  { id: 'late-a', era_year: 2003, order: 5 },
  { id: 'late-b', era_year: 2008, order: 6 },
];

describe('scene-v2 progressive section loading', () => {
  it('orders sections from the camera instead of catalog chronology', () => {
    const layout = computeHall(entries);
    const lateDesk = layout.desks.find((desk) => desk.sectionKey === '2000')!;
    const ranked = rankSectionsByDistance(layout, [
      lateDesk.pos[0],
      1.55,
      lateDesk.pos[2],
    ]);

    expect(ranked[0]).toMatchObject({ key: '2000', distance: 0 });
    expect(ranked.map(({ key }) => key)).not.toEqual(['1980', '1990', '2000']);
  });

  it('always mounts the nearest first, then holds distant sections behind covers', () => {
    const layout = computeHall(entries);
    const firstDesk = layout.desks.find((desk) => desk.sectionKey === '1980')!;
    const camera: Point3 = [firstDesk.pos[0], 1.55, firstDesk.pos[2]];
    const first = nextSectionToMount(layout, camera, new Set(), 0);

    expect(first).toBe('1980');
    expect(nextSectionToMount(layout, camera, new Set([first!]), 0)).toBeNull();
    expect(nextSectionToMount(
      layout,
      camera,
      new Set([first!]),
      SECTION_LOAD_RADIUS,
    )).toBe('1990');
  });
});
