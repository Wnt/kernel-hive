import { CEILING_GRID_MODULE, CEILING_HEIGHT, DESK_MODULE } from './hallSpec';

export type Point3 = [number, number, number];

export interface HallEntry {
  id: string;
  displayName?: string;
  era_year: number;
  order: number;
  assemblyId?: string;
  bootVideo?: { mp4: string };
}

export interface HallDesk {
  id: string;
  entry: HallEntry;
  sectionKey: string;
  row: number;
  column: number;
  pos: Point3;
  rotY: number;
  deskModel: 'schoolDesk' | 'deskPedestalWood';
  variation: ExhibitVariation;
}

export interface LocalPlacementVariation {
  offset: Point3;
  yaw: number;
}

export interface ExhibitVariation {
  machine: LocalPlacementVariation;
  keyboard: LocalPlacementVariation;
  mouse: LocalPlacementVariation;
  placard: LocalPlacementVariation & { lean: number };
  aging: {
    yellowing: number;
    valueOffset: number;
    roughnessOffset: number;
  };
}

export type SetDressingModel =
  | 'officeChairA'
  | 'officeChairB'
  | 'chairTubularRed'
  | 'chairPlywoodOrange'
  | 'chairTaskBlue'
  | 'deskPedestalWood'
  | 'cableRun'
  | 'shelfUnit'
  | 'deskClutter';

export interface HallProp {
  id: string;
  model: SetDressingModel;
  pos: Point3;
  rotY: number;
  scale?: Point3;
  deskId?: string;
}

interface HallSection {
  key: string;
  label: string;
  decade: number;
  entries: HallEntry[];
  deskIds: string[];
  rowCount: number;
  centerZ: number;
  zMin: number;
  zMax: number;
}

interface HallEraMarker {
  id: string;
  label: string;
  pos: Point3;
  rotY: number;
}

interface RailSpec {
  loop: Point3[];
  look: Point3[];
}

export interface HallLayout {
  count: number;
  dims: {
    width: number;
    depth: number;
    height: number;
    tileStripDepth: number;
  };
  columns: number;
  sections: HallSection[];
  desks: HallDesk[];
  troffers: Point3[];
  windows: Array<{ id: string; z: number; width: number }>;
  eraMarkers: HallEraMarker[];
  props: HallProp[];
  railSpec: RailSpec;
}

const COLUMNS_MAX = 6;
const DESK_PITCH_X = 1.66;
const ROW_PITCH_Z = 1.1;
const WALK_AISLE_CLEARANCE_Z = 1.28;
const SECTION_PAD_Z =
  DESK_MODULE.depth + WALK_AISLE_CLEARANCE_Z - ROW_PITCH_Z;
const FRONT_BACK_MARGIN = 2.05;
const WALL_RAIL_CLEARANCE = 1.06;
const VIEW_OFFSET = (DESK_MODULE.depth + WALK_AISLE_CLEARANCE_Z) / 2 + 0.015;
const RAIL_INWARD_DEGREES = 42;
const TROFFER_PITCH = CEILING_GRID_MODULE * 4;
const TROFFER_WALL_CLEARANCE = 1.2;
export const CHAIR_BACK_CLEARANCE = 0.025;

interface FloorAabb {
  minX: number;
  maxX: number;
  minZ: number;
  maxZ: number;
}

const CHAIR_BACK_BOUNDS = {
  officeChairA: { halfWidth: 0.21, halfDepth: 0.04, centerZ: -0.168 },
  officeChairB: { halfWidth: 0.215, halfDepth: 0.032, centerZ: -0.177 },
  chairTubularRed: { halfWidth: 0.207, halfDepth: 0.032, centerZ: -0.189 },
  chairPlywoodOrange: { halfWidth: 0.225, halfDepth: 0.027, centerZ: -0.192 },
  chairTaskBlue: { halfWidth: 0.22, halfDepth: 0.043, centerZ: -0.174 },
} as const;

type ChairModel = keyof typeof CHAIR_BACK_BOUNDS;

function decadeFor(year: number): number {
  return Math.floor(year / 10) * 10;
}

function stableVariation(id: string, salt: number): number {
  let hash = 2166136261 ^ salt;
  for (let index = 0; index < id.length; index += 1) {
    hash = Math.imul(hash ^ id.charCodeAt(index), 16777619);
  }
  return (hash >>> 0) / 0xffffffff * 2 - 1;
}

function unitVariation(id: string, salt: number): number {
  return (stableVariation(id, salt) + 1) / 2;
}

function signedRange(id: string, salt: number, min: number, max: number): number {
  const variation = stableVariation(id, salt);
  const magnitude = min + Math.abs(variation) * (max - min);
  return (variation < 0 ? -1 : 1) * magnitude;
}

function degrees(value: number): number {
  return value * Math.PI / 180;
}

function exhibitVariation(id: string): ExhibitVariation {
  return {
    machine: {
      offset: [
        signedRange(id, 151, 0.02, 0.06),
        0,
        signedRange(id, 157, 0.02, 0.06),
      ],
      yaw: degrees(signedRange(id, 163, 2, 5)),
    },
    keyboard: {
      offset: [
        signedRange(id, 167, 0.03, 0.08),
        0,
        signedRange(id, 173, 0.03, 0.08),
      ],
      yaw: degrees(signedRange(id, 179, 1.5, 4)),
    },
    mouse: {
      offset: [
        signedRange(id, 181, 0.015, 0.07),
        0,
        signedRange(id, 191, 0.015, 0.06),
      ],
      yaw: degrees(signedRange(id, 193, 2, 9)),
    },
    placard: {
      offset: [
        stableVariation(id, 197) * 0.06,
        stableVariation(id, 199) * 0.012,
        stableVariation(id, 211) * 0.055,
      ],
      yaw: degrees(signedRange(id, 223, 2, 5)),
      lean: degrees(signedRange(id, 227, 1, 4)),
    },
    aging: {
      yellowing: unitVariation(id, 229) * 0.055,
      valueOffset: stableVariation(id, 233) * 0.04,
      roughnessOffset: stableVariation(id, 239) * 0.07,
    },
  };
}

function deskPoint(desk: HallDesk, local: Point3): Point3 {
  const sin = Math.sin(desk.rotY);
  const cos = Math.cos(desk.rotY);
  return [
    desk.pos[0] + local[0] * cos + local[2] * sin,
    desk.pos[1] + local[1],
    desk.pos[2] - local[0] * sin + local[2] * cos,
  ];
}

export function deskTopAabb(desk: HallDesk): FloorAabb {
  const cos = Math.abs(Math.cos(desk.rotY));
  const sin = Math.abs(Math.sin(desk.rotY));
  const halfX = DESK_MODULE.width / 2 * cos + DESK_MODULE.depth / 2 * sin;
  const halfZ = DESK_MODULE.width / 2 * sin + DESK_MODULE.depth / 2 * cos;
  return {
    minX: desk.pos[0] - halfX,
    maxX: desk.pos[0] + halfX,
    minZ: desk.pos[2] - halfZ,
    maxZ: desk.pos[2] + halfZ,
  };
}

export function chairBackAabb(prop: HallProp): FloorAabb | null {
  if (!(prop.model in CHAIR_BACK_BOUNDS)) return null;
  const bounds = CHAIR_BACK_BOUNDS[prop.model as ChairModel];
  const cos = Math.cos(prop.rotY);
  const sin = Math.sin(prop.rotY);
  const centerX = prop.pos[0] + bounds.centerZ * sin;
  const centerZ = prop.pos[2] + bounds.centerZ * cos;
  const halfX = bounds.halfWidth * Math.abs(cos) + bounds.halfDepth * Math.abs(sin);
  const halfZ = bounds.halfWidth * Math.abs(sin) + bounds.halfDepth * Math.abs(cos);
  return {
    minX: centerX - halfX,
    maxX: centerX + halfX,
    minZ: centerZ - halfZ,
    maxZ: centerZ + halfZ,
  };
}

function clearsDeskTops(prop: HallProp, desks: HallDesk[]): boolean {
  const back = chairBackAabb(prop);
  if (!back) return true;
  return desks.every((desk) => {
    const top = deskTopAabb(desk);
    return back.maxX + CHAIR_BACK_CLEARANCE <= top.minX
      || back.minX - CHAIR_BACK_CLEARANCE >= top.maxX
      || back.maxZ + CHAIR_BACK_CLEARANCE <= top.minZ
      || back.minZ - CHAIR_BACK_CLEARANCE >= top.maxZ;
  });
}

function buildSetDressing(width: number, depth: number, desks: HallDesk[]): HallProp[] {
  const props: HallProp[] = [];
  const chairModels = [
    'officeChairA',
    'officeChairB',
    'chairTubularRed',
    'chairPlywoodOrange',
    'chairTaskBlue',
  ] as const;
  const chairRuns = new Map<string, { model: (typeof chairModels)[number]; count: number }>();
  for (const desk of desks) {
    const deskId = desk.id;
    props.push({
      id: `cable:${desk.entry.id}`,
      model: 'cableRun',
      pos: deskPoint(desk, [0, 0, -0.54]),
      rotY: desk.rotY + degrees(stableVariation(desk.entry.id, 241) * 2.5),
      scale: [
        0.94 + unitVariation(desk.entry.id, 251) * 0.12,
        0.96 + unitVariation(desk.entry.id, 257) * 0.08,
        0.94 + unitVariation(desk.entry.id, 263) * 0.12,
      ],
      deskId,
    });
    if (desk.deskModel === 'deskPedestalWood') {
      props.push({
        id: `desk-variant:${desk.entry.id}`,
        model: 'deskPedestalWood',
        pos: desk.pos,
        rotY: desk.rotY,
        deskId,
      });
    }
    if (stableVariation(desk.entry.id, 79) > -0.7) {
      const rowKey = `${desk.sectionKey}:${desk.row}`;
      let chairIndex = Math.min(
        chairModels.length - 1,
        Math.floor(unitVariation(desk.entry.id, 83) * chairModels.length),
      );
      const previous = chairRuns.get(rowKey);
      if (previous?.model === chairModels[chairIndex] && previous.count === 3) {
        chairIndex = (chairIndex + 1) % chairModels.length;
      }
      const model = chairModels[chairIndex];
      chairRuns.set(rowKey, {
        model,
        count: previous?.model === model ? previous.count + 1 : 1,
      });
      const aisleAngle = unitVariation(desk.entry.id, 269) > 0.88;
      const compactClassroomChair = model === 'chairTubularRed'
        || model === 'chairPlywoodOrange';
      const seededPullOut = 0.3 + unitVariation(desk.entry.id, 103)
        * (compactClassroomChair ? 0.1 : 0.08);
      const lateralSide = desk.pos[0] < -0.1
        ? 1
        : desk.pos[0] > 0.1
          ? -1
          : stableVariation(desk.entry.id, 89) < 0 ? -1 : 1;
      const localX = lateralSide * (
        0.47 + unitVariation(desk.entry.id, aisleAngle ? 271 : 89) * 0.08
      );
      const rotY = desk.rotY + Math.PI + (
        aisleAngle
          ? degrees(4 + unitVariation(desk.entry.id, 277) * 2)
          : degrees(stableVariation(desk.entry.id, 97) * 6)
      );
      const candidatePullOuts = Array.from(
        { length: 65 },
        (_, index) => 0.28 + index * 0.005,
      ).sort((a, b) => Math.abs(a - seededPullOut) - Math.abs(b - seededPullOut));
      const chairAt = (pullOut: number): HallProp => ({
        id: `chair:${desk.entry.id}`,
        model,
        pos: deskPoint(desk, [localX, 0, pullOut]),
        rotY,
        deskId,
      });
      const chair = candidatePullOuts
        .map(chairAt)
        .find((candidate) => clearsDeskTops(candidate, desks));
      if (chair) props.push(chair);
    } else {
      chairRuns.delete(`${desk.sectionKey}:${desk.row}`);
    }
    if (stableVariation(desk.entry.id, 107) > 1 / 3) {
      props.push({
        id: `clutter:${desk.entry.id}`,
        model: 'deskClutter',
        pos: deskPoint(desk, [-0.58, DESK_MODULE.height, -0.015]),
        rotY: desk.rotY + stableVariation(desk.entry.id, 109) * Math.PI / 60,
        deskId,
      });
    }
  }
  return props;
}

function buildRail(width: number, desks: HallDesk[]): RailSpec {
  const loop: Point3[] = [];
  const sideX = width / 2 - WALL_RAIL_CLEARANCE;
  const rows = new Map<string, HallDesk[]>();
  for (const desk of desks) {
    // Rows inside a decade form a dense furniture bank. The rail uses the
    // 1.28 m cross-decade walk aisles in front of each bank rather than
    // attempting to pass through the chair-filled gaps inside it.
    if (desk.row !== 0) continue;
    const key = desk.sectionKey;
    const row = rows.get(key) ?? [];
    row.push(desk);
    rows.set(key, row);
  }
  const orderedRows = [...rows.values()].sort((a, b) => b[0].pos[2] - a[0].pos[2]);

  orderedRows.forEach((row, index) => {
    const representative = row[0];
    const facing = Math.cos(representative.rotY);
    const viewDistance = index === 0
      ? 1.32
      : index === orderedRows.length - 1
        ? VIEW_OFFSET + 0.05
        : VIEW_OFFSET;
    const viewZ = representative.pos[2] + facing * viewDistance;
    const leftToRight = index % 2 === (orderedRows.length % 2 === 0 ? 1 : 0);
    const startX = leftToRight ? -sideX : sideX;
    const endX = -startX;
    const xs = [startX, startX * 0.55, 0, endX * 0.55, endX];
    xs.forEach((x) => {
      loop.push([x, 0, viewZ]);
    });

    const next = orderedRows[index + 1]?.[0];
    if (next) {
      const nextFacing = Math.cos(next.rotY);
      const nextViewZ = next.pos[2] + nextFacing * VIEW_OFFSET;
      // A hold point keeps the outgoing corner exhibit acquired; the paired
      // point below it acquires the next row before the next straight begins.
      loop.push([endX, 0, viewZ - 0.08]);
      loop.push([endX, 0, nextViewZ + 0.08]);
    }
  });

  const first = loop[0];
  const last = loop[loop.length - 1];
  loop.push([sideX, 0, last[2] + 0.6]);
  loop.push([sideX, 0, last[2] + 1.2]);
  for (let step = 1; step <= 9; step += 1) {
    const fraction = step / 10;
    const z = last[2] + (first[2] - last[2]) * fraction;
    loop.push([sideX, 0, z]);
  }
  if (first[0] < 0) {
    loop.push([sideX, 0, first[2]]);
    loop.push([0, 0, first[2]]);
  }
  // The return leg moves north along the pine aisle while looking across the
  // desk field, then eases south before the loop closes on the first row.
  const look = loop.map(([x, , z]): Point3 => {
    const inwardDegrees = RAIL_INWARD_DEGREES * x / sideX;
    const angle = inwardDegrees * Math.PI / 180;
    return [x - Math.sin(angle) * 5, 0, z - Math.cos(angle) * 5];
  });
  return { loop, look };
}

export function computeHall(input: readonly HallEntry[]): HallLayout {
  const entries = [...input].sort((a, b) => a.order - b.order || a.id.localeCompare(b.id));
  if (entries.length === 0) throw new Error('computeHall requires at least one entry');
  const seen = new Set<string>();
  for (const entry of entries) {
    if (seen.has(entry.id)) throw new Error(`duplicate hall entry id: ${entry.id}`);
    if (!Number.isInteger(entry.era_year)) throw new Error(`invalid era_year for ${entry.id}`);
    seen.add(entry.id);
  }

  const byDecade = new Map<number, HallEntry[]>();
  for (const entry of entries) {
    const decade = decadeFor(entry.era_year);
    const group = byDecade.get(decade) ?? [];
    group.push(entry);
    byDecade.set(decade, group);
  }
  for (const group of byDecade.values()) {
    group.sort((a, b) => a.era_year - b.era_year || a.order - b.order);
  }
  const groups = [...byDecade].sort(([a], [b]) => a - b);
  const columns = Math.min(COLUMNS_MAX, Math.max(3, Math.ceil(Math.sqrt(entries.length))));
  const groupWidth = (columns - 1) * DESK_PITCH_X + DESK_MODULE.width;
  const width = Math.max(12.8, Math.ceil((groupWidth + 2.8) * 10) / 10);
  const rowCounts = groups.map(([, group]) => Math.ceil(group.length / columns));
  const depth = FRONT_BACK_MARGIN * 2
    + rowCounts.reduce((sum, rows) => sum + rows * ROW_PITCH_Z + SECTION_PAD_Z, 0);
  const sections: HallSection[] = [];
  const desks: HallDesk[] = [];
  const eraMarkers: HallEraMarker[] = [];
  let cursorZ = depth / 2 - FRONT_BACK_MARGIN;

  groups.forEach(([decade, group], sectionIndex) => {
    const rowCount = rowCounts[sectionIndex];
    const rowSizes = Array.from({ length: rowCount }, (_, row) =>
      Math.floor(group.length / rowCount) + (row < group.length % rowCount ? 1 : 0));
    const sectionTop = cursorZ;
    group.forEach((entry, index) => {
      let row = 0;
      let column = index;
      while (column >= rowSizes[row]) {
        column -= rowSizes[row];
        row += 1;
      }
      const itemsInRow = rowSizes[row];
      const rowWidth = (itemsInRow - 1) * DESK_PITCH_X;
      const x = -rowWidth / 2 + column * DESK_PITCH_X
        + stableVariation(entry.id, 17) * 0.045;
      const z = sectionTop - 0.5 - row * ROW_PITCH_Z
        + stableVariation(entry.id, 31) * 0.035;
      desks.push({
        id: `desk:${entry.id}`,
        entry,
        sectionKey: String(decade),
        row,
        column,
        pos: [x, 0, z],
        rotY: stableVariation(entry.id, 47) * Math.PI / 72,
        deskModel: unitVariation(entry.id, 149) > 0.86
          ? 'deskPedestalWood'
          : 'schoolDesk',
        variation: exhibitVariation(entry.id),
      });
    });
    const sectionBottom = sectionTop - rowCount * ROW_PITCH_Z - SECTION_PAD_Z;
    const label = `${decade}s`;
    const sectionDesks = desks.filter((desk) => desk.sectionKey === String(decade));
    sections.push({
      key: String(decade),
      label,
      decade,
      entries: group,
      deskIds: sectionDesks.map((desk) => desk.id),
      rowCount,
      centerZ: (sectionTop + sectionBottom) / 2,
      zMin: sectionBottom,
      zMax: sectionTop,
    });
    eraMarkers.push({
      id: `era-marker:${decade}`,
      label,
      pos: [-width / 2 + 0.75, 0, sectionTop - 0.58],
      rotY: Math.PI / 2,
    });
    cursorZ = sectionBottom;
  });

  const troffers: Point3[] = [];
  const minTrofferX = Math.ceil(
    (-width / 2 + TROFFER_WALL_CLEARANCE) / TROFFER_PITCH,
  );
  const maxTrofferX = Math.floor(
    (width / 2 - TROFFER_WALL_CLEARANCE) / TROFFER_PITCH,
  );
  const minTrofferZ = Math.ceil(
    (-depth / 2 + TROFFER_WALL_CLEARANCE) / TROFFER_PITCH,
  );
  const maxTrofferZ = Math.floor(
    (depth / 2 - TROFFER_WALL_CLEARANCE) / TROFFER_PITCH,
  );
  for (let zIndex = minTrofferZ; zIndex <= maxTrofferZ; zIndex += 1) {
    for (let xIndex = minTrofferX; xIndex <= maxTrofferX; xIndex += 1) {
      troffers.push([
        xIndex * TROFFER_PITCH,
        CEILING_HEIGHT,
        zIndex * TROFFER_PITCH,
      ]);
    }
  }
  const windowCount = Math.max(3, Math.ceil(depth / 2.4));
  const bayWidth = depth / windowCount;
  const windows = Array.from({ length: windowCount }, (_, index) => ({
    id: `window:${index}`,
    z: -depth / 2 + bayWidth * (index + 0.5),
    width: bayWidth,
  }));

  return {
    count: entries.length,
    dims: { width, depth, height: CEILING_HEIGHT, tileStripDepth: Math.max(1.6, depth * 0.08) },
    columns,
    sections,
    desks,
    troffers,
    windows,
    eraMarkers,
    props: buildSetDressing(width, depth, desks),
    railSpec: buildRail(width, desks),
  };
}
