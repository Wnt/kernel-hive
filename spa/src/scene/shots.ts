import type { HallLayout, Point3 } from './hallLayout';
import { DESK_MODULE } from './hallSpec';

export interface Shot {
  position: Point3;
  target: Point3;
}

const DESK_SHOT_HEIGHT = 1.18;
const DESK_SHOT_DISTANCE = 1.25;
const THREE_QUARTER_ANGLE = 35 * Math.PI / 180;

interface DeskShotAdjustment {
  angle?: number;
  distance?: number;
  height?: number;
  targetY?: number;
}

interface DeskShotAdjustments {
  front?: DeskShotAdjustment;
  three4?: DeskShotAdjustment;
}

const degrees = (value: number) => value * Math.PI / 180;

// Dense 1.1 m row spacing means a mathematically straight pin can land inside
// the next desk. Keep exceptions local so the complete inspection set remains
// stable while the affected stations retain distinct, usable audit views.
const DESK_SHOT_ADJUSTMENTS: Partial<Record<string, DeskShotAdjustments>> = {
  nt351: { front: { angle: degrees(-35), distance: 1.16 } },
  os2warp: { front: { angle: degrees(-35), distance: 1.16 } },
  nt4: { front: { angle: degrees(-35), distance: 1.16 } },
  redstar2: { three4: { angle: degrees(18), distance: 1.12 } },
  win2000: {
    front: { distance: 1.38, targetY: 0.91 },
    three4: { distance: 1.38, targetY: 0.91 },
  },
  winxp: {
    front: { distance: 1.38, targetY: 0.91 },
    three4: { distance: 1.42, targetY: 0.91 },
  },
  ninefront: {
    front: { distance: 1.38, targetY: 0.91 },
    three4: { distance: 1.42, targetY: 0.91 },
  },
};

function deskShotPosition(
  desk: HallLayout['desks'][number],
  angle: number,
  distance = DESK_SHOT_DISTANCE,
  height = DESK_SHOT_HEIGHT,
): Point3 {
  const localX = Math.sin(angle) * distance;
  const localZ = Math.cos(angle) * distance;
  const sin = Math.sin(desk.rotY);
  const cos = Math.cos(desk.rotY);
  return [
    desk.pos[0] + localX * cos + localZ * sin,
    height,
    desk.pos[2] - localX * sin + localZ * cos,
  ];
}

function computeShots(layout: HallLayout): Record<string, Shot> {
  const { width, depth } = layout.dims;
  const rowAnchors = layout.desks.filter((desk, index, desks) =>
    desks.findIndex((candidate) =>
      candidate.sectionKey === desk.sectionKey && candidate.row === desk.row) === index);
  const firstDesk = layout.desks[0];
  const frontRightDesk = layout.desks
    .filter((desk) =>
      desk.sectionKey === firstDesk?.sectionKey && desk.row === firstDesk.row)
    .sort((a, b) => b.pos[0] - a.pos[0])[0] ?? firstDesk;
  const middleRow = rowAnchors[Math.floor(rowAnchors.length / 2)] ?? firstDesk;
  const firstSection = layout.sections[0];
  const pineDesk = layout.desks
    .filter((desk) => desk.sectionKey === firstSection.key)
    .sort((a, b) => b.pos[0] - a.pos[0])[0] ?? firstDesk;
  const exhibitTarget = (desk = firstDesk): Point3 => [
    desk?.pos[0] ?? 0,
    0.96,
    desk?.pos[2] ?? 0,
  ];
  const shots: Record<string, Shot> = {
    entrance: {
      position: [width * 0.38, 1.6, depth / 2 - 1.2],
      target: exhibitTarget(middleRow),
    },
    hallWide: {
      position: [
        (frontRightDesk?.pos[0] ?? width * 0.25) - DESK_MODULE.width / 2 - 0.03,
        1.58,
        (frontRightDesk?.pos[2] ?? depth / 2 - 2) + 1.18,
      ],
      target: [0, 1.02, middleRow?.pos[2] ?? 0],
    },
    pineWall: {
      position: [-width / 2 + 1.35, 1.55, (pineDesk?.pos[2] ?? firstSection.centerZ) + 0.8],
      target: exhibitTarget(pineDesk),
    },
    archiveWall: {
      position: [width * 0.36, 1.55, -depth / 2 + 2.3],
      target: [0, 1.25, -depth / 2 + 0.24],
    },
    lineup: {
      position: [0, 1.2, Math.min(4.6, depth * 0.22)],
      target: [0, 0.88, 0],
    },
    lineupOne: {
      position: [width * 0.03, 1.18, Math.min(1.5, depth * 0.08)],
      target: [0, 0.9, 0],
    },
    corner: {
      position: [-width / 2 + 1.2, 1.5, depth / 2 - 1.2],
      target: exhibitTarget(firstDesk),
    },
  };
  if (firstDesk) {
    shots.deskSeated = {
      position: [firstDesk.pos[0], 1.2, firstDesk.pos[2] + 1.5],
      target: [firstDesk.pos[0], 0.96, firstDesk.pos[2]],
    };
    shots.corridorFront = {
      position: [-width / 2 + 1.2, 1.6, firstDesk.pos[2] + 1],
      target: [width / 2 - 1.2, 0.95, firstDesk.pos[2]],
    };
  }
  if (middleRow) {
    shots.corridorMiddle = {
      position: [
        -width / 2 + 1.2,
        1.58,
        middleRow.pos[2] + DESK_MODULE.depth / 2 + 0.31,
      ],
      target: [width / 2 - 1.2, 0.95, middleRow.pos[2]],
    };
  }
  for (const section of layout.sections) {
    const sectionFirstDesk = layout.desks.find((desk) => desk.sectionKey === section.key);
    if (!sectionFirstDesk) continue;
    shots[`section-${section.label}-wide`] = {
      position: [-width / 2 + 1.15, 1.58, section.centerZ + 0.35],
      target: [0, 1, section.centerZ],
    };
    const facing = Math.cos(sectionFirstDesk.rotY);
    shots[`section-${section.label}-seated`] = {
      position: [sectionFirstDesk.pos[0], 1.2, sectionFirstDesk.pos[2] + facing * 1.5],
      target: [sectionFirstDesk.pos[0], 0.96, sectionFirstDesk.pos[2]],
    };
  }
  for (const desk of layout.desks) {
    const adjustments = DESK_SHOT_ADJUSTMENTS[desk.entry.id];
    const front = adjustments?.front;
    const three4 = adjustments?.three4;
    const frontTarget = exhibitTarget(desk);
    frontTarget[1] = front?.targetY ?? frontTarget[1];
    const three4Target = exhibitTarget(desk);
    three4Target[1] = three4?.targetY ?? three4Target[1];
    shots[`desk-${desk.entry.id}-front`] = {
      position: deskShotPosition(
        desk,
        front?.angle ?? 0,
        front?.distance,
        front?.height,
      ),
      target: frontTarget,
    };
    shots[`desk-${desk.entry.id}-three4`] = {
      position: deskShotPosition(
        desk,
        three4?.angle ?? THREE_QUARTER_ANGLE,
        three4?.distance,
        three4?.height,
      ),
      target: three4Target,
    };
  }
  return shots;
}

export function shotNames(layout: HallLayout): string[] {
  return Object.keys(computeShots(layout));
}

export function shotFromUrl(search: string, layout: HallLayout): Shot | null {
  const name = new URLSearchParams(search).get('shot');
  return name ? (computeShots(layout)[name] ?? null) : null;
}
