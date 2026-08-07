import { CatmullRomCurve3, Vector3 } from 'three';
import { describe, expect, it } from 'vitest';
import manifest from '../../../scripts/serve/webroot/gallery-manifest.json' with { type: 'json' };
import {
  CHAIR_BACK_CLEARANCE,
  chairBackAabb,
  computeHall,
  deskTopAabb,
  type HallEntry,
  type HallLayout,
  type HallProp,
} from './hallLayout';
import {
  CEILING_GRID_MODULE,
  CEILING_HEIGHT,
  DESK_MODULE,
} from './hallSpec';

const registryEntries: HallEntry[] = [...manifest.entries]
  .sort((a, b) => a.order - b.order)
  .map((entry) => ({
    id: entry.id,
    displayName: entry.displayName,
    era_year: entry.era_year,
    order: entry.order,
  }));

function entriesAt(count: number): HallEntry[] {
  const entries = registryEntries.slice(0, Math.min(36, count));
  let source = 0;
  while (entries.length < count) {
    const original = registryEntries[source % registryEntries.length];
    entries.push({
      ...original,
      id: `test-${entries.length}-${original.id}`,
      order: 1000 + entries.length,
      assemblyId: original.id,
    });
    source += 1;
  }
  return entries;
}

function distanceToDesk(point: Vector3, desk: HallLayout['desks'][number]): number {
  const dx = Math.max(Math.abs(point.x - desk.pos[0]) - DESK_MODULE.width / 2, 0);
  const dz = Math.max(Math.abs(point.z - desk.pos[2]) - DESK_MODULE.depth / 2, 0);
  return Math.hypot(dx, dz);
}

const PROP_FOOTPRINTS: Record<HallProp['model'], [number, number]> = {
  officeChairA: [0.345, 0.345],
  officeChairB: [0.345, 0.345],
  chairTubularRed: [0.25, 0.27],
  chairPlywoodOrange: [0.25, 0.27],
  chairTaskBlue: [0.32, 0.32],
  deskPedestalWood: [0.73, 0.36],
  // The wide floor raceway is 11 mm high and intentionally walkable; guard
  // camera clearance against the waist-height cable basket and drop instead.
  cableRun: [0.4, 0.1],
  shelfUnit: [0.43, 0.28],
  deskClutter: [0.2, 0.16],
};

function distanceToProp(point: Vector3, prop: HallProp): number {
  const dx = point.x - prop.pos[0];
  const dz = point.z - prop.pos[2];
  const cos = Math.cos(prop.rotY);
  const sin = Math.sin(prop.rotY);
  const localX = dx * cos - dz * sin;
  const localZ = dx * sin + dz * cos;
  const [halfWidth, halfDepth] = PROP_FOOTPRINTS[prop.model];
  return Math.hypot(
    Math.max(Math.abs(localX) - halfWidth, 0),
    Math.max(Math.abs(localZ) - halfDepth, 0),
  );
}

function propPositionAtDesk(prop: HallProp, desk: HallLayout['desks'][number]) {
  const dx = prop.pos[0] - desk.pos[0];
  const dz = prop.pos[2] - desk.pos[2];
  const cos = Math.cos(desk.rotY);
  const sin = Math.sin(desk.rotY);
  return {
    x: dx * cos - dz * sin,
    z: dx * sin + dz * cos,
  };
}

function analyze(layout: HallLayout) {
  const curve = new CatmullRomCurve3(
    layout.railSpec.loop.map((point) => new Vector3(...point)),
    true,
    'centripetal',
  );
  const lookCurve = new CatmullRomCurve3(
    layout.railSpec.look.map((point) => new Vector3(...point)),
    true,
    'centripetal',
  );
  curve.arcLengthDivisions = 400;
  lookCurve.arcLengthDivisions = 400;
  const samples = 4000;
  let minWall = Infinity;
  let minWallAt = { t: 0, x: 0, z: 0 };
  let minDesk = Infinity;
  let minDeskAt = { t: 0, x: 0, z: 0, id: '' };
  let minProp = Infinity;
  let minPropAt = { t: 0, x: 0, z: 0, id: '' };
  let maxGazeRate = 0;
  let maxGazeT = 0;
  let maxGazeDirs = { from: [0, 0, 0], to: [0, 0, 0] };
  const coverage = new Map<string, { angle: number; distance: number }>();
  for (const desk of layout.desks) coverage.set(desk.id, { angle: Infinity, distance: Infinity });

  const directionAt = (t: number) => {
    const wrapped = ((t % 1) + 1) % 1;
    const point = curve.getPointAt(wrapped);
    point.y = 1.55;
    const target = lookCurve.getPoint(curve.getUtoTmapping(wrapped, 0));
    target.y += 0.95;
    return target.sub(point).normalize();
  };

  for (let index = 0; index < samples; index += 1) {
    const t = index / samples;
    const point = curve.getPointAt(t);
    point.y = 1.55;
    const wall = Math.min(
      layout.dims.width / 2 - Math.abs(point.x),
      layout.dims.depth / 2 - Math.abs(point.z),
    );
    if (wall < minWall) {
      minWall = wall;
      minWallAt = { t, x: point.x, z: point.z };
    }
    for (const desk of layout.desks) {
      const deskDistance = distanceToDesk(point, desk);
      if (deskDistance < minDesk) {
        minDesk = deskDistance;
        minDeskAt = { t, x: point.x, z: point.z, id: desk.id };
      }
      const toDesk = new Vector3(desk.pos[0], 0.95, desk.pos[2]).sub(point);
      const distance = toDesk.length();
      if (distance < 1.6 || distance > 6) continue;
      const angle = directionAt(t).angleTo(toDesk.normalize()) * 180 / Math.PI;
      const best = coverage.get(desk.id)!;
      if (angle < best.angle) coverage.set(desk.id, { angle, distance });
    }
    for (const prop of layout.props) {
      const propDistance = distanceToProp(point, prop);
      if (propDistance < minProp) {
        minProp = propDistance;
        minPropAt = { t, x: point.x, z: point.z, id: prop.id };
      }
    }
    const gazeRate = directionAt(t).angleTo(directionAt(t + 0.005)) * 180 / Math.PI * 2;
    if (gazeRate > maxGazeRate) {
      maxGazeRate = gazeRate;
      maxGazeT = t;
      maxGazeDirs = {
        from: directionAt(t).toArray(),
        to: directionAt(t + 0.005).toArray(),
      };
    }
  }
  return {
    minWall,
    minWallAt,
    minDesk,
    minDeskAt,
    minProp,
    minPropAt,
    maxGazeRate,
    maxGazeT,
    maxGazeDirs,
    maxCoverageAngle: Math.max(...[...coverage.values()].map((item) => item.angle)),
    worstCoverageDesk: [...coverage].sort((a, b) => b[1].angle - a[1].angle)[0][0],
    minCoverageDistance: Math.min(...[...coverage.values()].map((item) => item.distance)),
    maxCoverageDistance: Math.max(...[...coverage.values()].map((item) => item.distance)),
  };
}

describe('parametric decade hall', () => {
  it.each([36, 50])('derives every fixture and one stable desk per entry at N=%i', (count) => {
    const entries = entriesAt(count);
    const layout = computeHall(entries);
    expect(layout.count).toBe(count);
    expect(layout.desks.map((desk) => desk.id)).toEqual(
      expect.arrayContaining(entries.map((entry) => `desk:${entry.id}`)),
    );
    expect(layout.sections.map((section) => section.decade)).toEqual(
      [...layout.sections.map((section) => section.decade)].sort((a, b) => a - b),
    );
    expect(layout.eraMarkers.map((marker) => marker.label)).toEqual(
      layout.sections.map((section) => section.label),
    );
    expect(layout.eraMarkers).toHaveLength(layout.sections.length);
    expect('dividers' in layout).toBe(false);
    expect(layout.troffers.length).toBeGreaterThan(count / 2);
    for (const [x, , z] of layout.troffers) {
      expect(x / CEILING_GRID_MODULE).toBeCloseTo(
        Math.round(x / CEILING_GRID_MODULE),
        10,
      );
      expect(z / CEILING_GRID_MODULE).toBeCloseTo(
        Math.round(z / CEILING_GRID_MODULE),
        10,
      );
    }
    expect(layout.windows.length).toBeGreaterThan(5);
    expect(layout.dims.height).toBe(2.8);
    expect(CEILING_HEIGHT).toBe(2.8);
    expect(CEILING_GRID_MODULE).toBe(0.6);
    expect(DESK_MODULE.height).toBe(0.72);
    expect(DESK_MODULE.width).toBeGreaterThanOrEqual(1.5);
    expect(DESK_MODULE.depth).toBeGreaterThanOrEqual(0.8);
    for (const section of layout.sections) {
      const sizes = Array.from({ length: section.rowCount }, (_, row) =>
        layout.desks.filter((desk) => desk.sectionKey === section.key && desk.row === row).length);
      expect(Math.max(...sizes) - Math.min(...sizes), section.key).toBeLessThanOrEqual(1);
    }
    const chairs = layout.props.filter((prop) => prop.id.startsWith('chair:'));
    const cables = layout.props.filter((prop) => prop.model === 'cableRun');
    const clutter = layout.props.filter((prop) => prop.model === 'deskClutter');
    const vintageDesks = layout.props.filter((prop) => prop.model === 'deskPedestalWood');
    expect(chairs.length).toBeGreaterThanOrEqual(Math.floor(count * 0.75));
    expect(chairs.length).toBeLessThanOrEqual(Math.ceil(count * 0.95));
    expect(cables).toHaveLength(count);
    expect(clutter.length).toBeGreaterThanOrEqual(Math.floor(count * 0.2));
    expect(clutter.length).toBeLessThanOrEqual(Math.ceil(count * 0.45));
    expect(vintageDesks.length).toBeGreaterThanOrEqual(2);
    expect(vintageDesks).toHaveLength(
      layout.desks.filter((desk) => desk.deskModel === 'deskPedestalWood').length,
    );
    expect(layout.props.filter((prop) => prop.model === 'shelfUnit')).toHaveLength(0);
    expect(computeHall(entries).props).toEqual(layout.props);
  });

  it.each([36, 50])('keeps seeded exhibit variation subtle and accumulated at N=%i', (count) => {
    const layout = computeHall(entriesAt(count));
    const radians = (degrees: number) => degrees * Math.PI / 180;

    for (const desk of layout.desks) {
      for (const offset of [
        desk.variation.machine.offset[0],
        desk.variation.machine.offset[2],
      ]) {
        expect(Math.abs(offset), `${desk.id} machine offset`).toBeGreaterThanOrEqual(0.02);
        expect(Math.abs(offset), `${desk.id} machine offset`).toBeLessThanOrEqual(0.06);
      }
      expect(Math.abs(desk.variation.machine.yaw), `${desk.id} machine yaw`)
        .toBeGreaterThanOrEqual(radians(2));
      expect(Math.abs(desk.variation.machine.yaw), `${desk.id} machine yaw`)
        .toBeLessThanOrEqual(radians(5));
      for (const offset of [
        desk.variation.keyboard.offset[0],
        desk.variation.keyboard.offset[2],
      ]) {
        expect(Math.abs(offset), `${desk.id} keyboard offset`).toBeGreaterThanOrEqual(0.03);
        expect(Math.abs(offset), `${desk.id} keyboard offset`).toBeLessThanOrEqual(0.08);
      }
      expect(Math.abs(desk.variation.keyboard.yaw), `${desk.id} keyboard yaw`)
        .toBeLessThanOrEqual(radians(4));
      expect(Math.abs(desk.variation.mouse.offset[0]), `${desk.id} mouse x`)
        .toBeLessThanOrEqual(0.07);
      expect(Math.abs(desk.variation.mouse.offset[2]), `${desk.id} mouse z`)
        .toBeLessThanOrEqual(0.06);
      expect(Math.abs(desk.variation.mouse.yaw), `${desk.id} mouse yaw`)
        .toBeLessThanOrEqual(radians(9));
      expect(Math.abs(desk.variation.placard.offset[0]), `${desk.id} placard x`)
        .toBeLessThanOrEqual(0.06);
      expect(Math.abs(desk.variation.placard.offset[2]), `${desk.id} placard z`)
        .toBeLessThanOrEqual(0.055);
      expect(Math.abs(desk.variation.placard.lean), `${desk.id} placard lean`)
        .toBeLessThanOrEqual(radians(4));
      expect(Math.abs(desk.variation.aging.valueOffset), `${desk.id} aging value`)
        .toBeLessThanOrEqual(0.04);
      expect(Math.abs(desk.variation.aging.roughnessOffset), `${desk.id} aging roughness`)
        .toBeLessThanOrEqual(0.07);
      expect(desk.variation.aging.yellowing, `${desk.id} aging yellowing`)
        .toBeGreaterThanOrEqual(0);
      expect(desk.variation.aging.yellowing, `${desk.id} aging yellowing`)
        .toBeLessThanOrEqual(0.055);
    }

    const chairByDesk = new Map(
      layout.props
        .filter((prop) => prop.id.startsWith('chair:'))
        .map((prop) => [prop.deskId, prop]),
    );
    for (const section of layout.sections) {
      for (let row = 0; row < section.rowCount; row += 1) {
        const stations = layout.desks
          .filter((desk) => desk.sectionKey === section.key && desk.row === row)
          .sort((a, b) => a.column - b.column);
        let previous: HallProp['model'] | undefined;
        let run = 0;
        for (const desk of stations) {
          const chair = chairByDesk.get(desk.id);
          const model = chair?.model;
          run = model && model === previous ? run + 1 : model ? 1 : 0;
          expect(run, `${section.key} row ${row}`).toBeLessThan(4);
          previous = model;
          if (!chair) continue;
          const local = propPositionAtDesk(chair, desk);
          expect(local.z, chair.id).toBeGreaterThanOrEqual(0.28);
          expect(local.z, chair.id).toBeLessThanOrEqual(0.6);
          expect(Math.abs(chair.rotY - desk.rotY - Math.PI), chair.id)
            .toBeLessThanOrEqual(radians(6));
        }
      }
    }
    for (const model of ['chairTubularRed', 'chairPlywoodOrange', 'chairTaskBlue']) {
      expect(
        layout.props.filter((prop) => prop.model === model).length,
        model,
      ).toBeGreaterThan(0);
    }

    for (const cable of layout.props.filter((prop) => prop.model === 'cableRun')) {
      const desk = layout.desks.find((item) => item.id === cable.deskId)!;
      expect(Math.abs(cable.rotY - desk.rotY), cable.id).toBeLessThanOrEqual(radians(3));
      expect(cable.scale, cable.id).toBeDefined();
      for (const scale of cable.scale!) {
        expect(scale, cable.id).toBeGreaterThanOrEqual(0.94);
        expect(scale, cable.id).toBeLessThanOrEqual(1.06);
      }
    }
  });

  it.each([
    ['registry', registryEntries],
    ['expanded', entriesAt(50)],
  ])('keeps every chair-back AABB clear of every desk-top AABB: %s', (_, entries) => {
    const layout = computeHall(entries);
    for (const chair of layout.props.filter((prop) => prop.id.startsWith('chair:'))) {
      const back = chairBackAabb(chair)!;
      for (const desk of layout.desks) {
        const top = deskTopAabb(desk);
        const separated = back.maxX + CHAIR_BACK_CLEARANCE <= top.minX
          || back.minX - CHAIR_BACK_CLEARANCE >= top.maxX
          || back.maxZ + CHAIR_BACK_CLEARANCE <= top.minZ
          || back.minZ - CHAIR_BACK_CLEARANCE >= top.maxZ;
        expect(separated, `${chair.id} back overlaps ${desk.id} top`).toBe(true);
      }
    }
  });

  it('keeps identities outside an expanded decade in the same local row and column', () => {
    const base = entriesAt(36);
    const before = computeHall(base);
    const added: HallEntry = {
      id: 'new-1990s-entry',
      era_year: 1999,
      order: 999,
    };
    const after = computeHall([...base, added]);
    for (const desk of before.desks.filter((item) => item.sectionKey !== '1990')) {
      const next = after.desks.find((item) => item.id === desk.id);
      expect([next?.row, next?.column], desk.id).toEqual([desk.row, desk.column]);
    }
  });

  it.each([36, 50])('packs row banks tightly around 1.2-1.5 m walk aisles at N=%i', (count) => {
    const layout = computeHall(entriesAt(count));
    const rowCenters = layout.sections.flatMap((section) =>
      Array.from({ length: section.rowCount }, (_, row) => {
        const desks = layout.desks.filter((desk) =>
          desk.sectionKey === section.key && desk.row === row);
        return {
          sectionKey: section.key,
          z: desks.reduce((sum, desk) => sum + desk.pos[2], 0) / desks.length,
        };
      }));
    for (let index = 1; index < rowCenters.length; index += 1) {
      const previous = rowCenters[index - 1];
      const current = rowCenters[index];
      const edgeClearance = previous.z - current.z - DESK_MODULE.depth;
      if (previous.sectionKey === current.sectionKey) {
        expect(edgeClearance).toBeGreaterThanOrEqual(0.2);
        expect(edgeClearance).toBeLessThanOrEqual(0.4);
      } else {
        expect(edgeClearance).toBeGreaterThanOrEqual(1.2);
        expect(edgeClearance).toBeLessThanOrEqual(1.5);
      }
    }
  });

  it.each([36, 50])('preserves the numeric rail guards at N=%i', (count) => {
    const metrics = analyze(computeHall(entriesAt(count)));
    expect(metrics.minWall, JSON.stringify(metrics)).toBeGreaterThanOrEqual(0.9);
    expect(metrics.minDesk, JSON.stringify(metrics)).toBeGreaterThanOrEqual(0.27);
    expect(metrics.minProp, JSON.stringify(metrics)).toBeGreaterThanOrEqual(0.27);
    expect(metrics.maxGazeRate, JSON.stringify(metrics)).toBeLessThanOrEqual(12.5);
    // Dense banks intentionally layer their second/third row behind the
    // acquired front row; all remain inside the 38-degree camera frame.
    expect(metrics.maxCoverageAngle, JSON.stringify(metrics)).toBeLessThanOrEqual(23);
    expect(metrics.minCoverageDistance, JSON.stringify(metrics)).toBeGreaterThanOrEqual(1.6);
    expect(metrics.maxCoverageDistance, JSON.stringify(metrics)).toBeLessThanOrEqual(6);
  });
});
