import type { HallDesk, HallLayout, Point3 } from './hallLayout';
import { DESK_MODULE } from './hallSpec';
import { identityForTile } from './machineIdentity';
import {
  assemblyForTile,
  hasIntegratedKeyboard,
} from './machines';

type StationKitAsset = 'binders' | 'floppyBox' | 'mousePad';
type StationKitHero = 'phoneDockEarly' | 'phoneDockModern' | 'spareKeyboard';

interface StationKitBinding {
  asset: StationKitAsset;
  id: string;
  position: Point3;
  rotation: Point3;
  scale: Point3;
}

interface StationKitHeroBinding extends Omit<StationKitBinding, 'asset'> {
  asset: StationKitHero;
}

interface CableCoilBinding extends Omit<StationKitBinding, 'asset'> {
  id: `spare-keyboard-cable:${string}:${number}`;
}

function stableVariation(id: string, salt: number) {
  let hash = 2166136261 ^ salt;
  for (let index = 0; index < id.length; index += 1) {
    hash = Math.imul(hash ^ id.charCodeAt(index), 16777619);
  }
  return (hash >>> 0) / 0xffffffff * 2 - 1;
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

export function buildStationKitBindings(layout: HallLayout) {
  const assets: StationKitBinding[] = [];
  const heroes: StationKitHeroBinding[] = [];
  const cableCoils: CableCoilBinding[] = [];
  const add = (
    desk: HallDesk,
    asset: StationKitAsset,
    id: string,
    local: Point3,
    yaw: number,
    scale: number,
  ) => assets.push({
    asset,
    id,
    position: deskPoint(desk, local),
    rotation: [0, yaw, 0],
    scale: [scale, scale, scale],
  });

  for (const desk of layout.desks) {
    const { kit } = identityForTile(desk.entry.assemblyId ?? desk.entry.id);
    const yaw = desk.rotY + stableVariation(desk.id, 409) * Math.PI / 30;
    if (kit === 'eightBit') {
      add(
        desk, 'floppyBox', `cartridge-box:${desk.id}`,
        [0.56, DESK_MODULE.height + 0.002, -0.22], yaw, 0.86,
      );
      if (stableVariation(desk.id, 419) > -0.1) {
        add(
          desk, 'binders', `period-manual:${desk.id}`,
          [-0.57, DESK_MODULE.height + 0.002, -0.23], yaw - 0.04, 0.68,
        );
      }
    } else if (kit === 'office90') {
      add(
        desk, 'mousePad', `mouse-pad:${desk.id}`,
        [0.45, DESK_MODULE.height + 0.004, 0.06], yaw, 0.92,
      );
      add(
        desk,
        stableVariation(desk.id, 421) > -0.25 ? 'binders' : 'floppyBox',
        `manual-media:${desk.id}`,
        [-0.57, DESK_MODULE.height + 0.002, 0.11],
        yaw - 0.03,
        0.78,
      );
    } else if (kit === 'modern') {
      heroes.push({
        asset: desk.entry.era_year <= 2011 ? 'phoneDockEarly' : 'phoneDockModern',
        id: `phone-dock:${desk.id}`,
        position: deskPoint(
          desk,
          [-0.57, DESK_MODULE.height + 0.002, -0.16],
        ),
        rotation: [0, yaw, 0],
        scale: [0.86, 0.86, 0.86],
      });
      add(
        desk, 'mousePad', `mouse-pad:${desk.id}`,
        [0.45, DESK_MODULE.height + 0.004, 0.05], yaw + 0.02, 0.88,
      );
    } else if (kit === 'mobile') {
      add(
        desk, 'binders', `mobile-manual:${desk.id}`,
        [0.48, DESK_MODULE.height + 0.002, -0.2], yaw, 0.62,
      );
    } else {
      add(
        desk,
        desk.entry.era_year < 2002 ? 'floppyBox' : 'binders',
        `workstation-kit:${desk.id}`,
        [-0.57, DESK_MODULE.height + 0.002, -0.22],
        yaw,
        0.72,
      );
    }
  }

  // The spare keyboard belongs on a desk whose machine does NOT have one built
  // in — a loose keyboard beside a PET or a C64 reads as clutter, not as period
  // dressing. It is preferred in the first section, but the search FALLS BACK to
  // the rest of the hall: adding the pre-1980 Commodores (pet2001, cbm8032) made
  // the oldest section entirely all-in-one machines, and a first-section-only
  // search silently dropped the prop from the scene altogether.
  const firstSection = layout.sections[0];
  const eligible = (desk: HallDesk) => !hasIntegratedKeyboard(assemblyForTile(
    desk.entry.assemblyId ?? desk.entry.id,
  ));
  const byDepth = (a: HallDesk, b: HallDesk) => b.pos[0] - a.pos[0];
  const spareKeyboardDesk = layout.desks
    .filter((desk) => desk.sectionKey === firstSection?.key)
    .sort(byDepth)
    .find(eligible)
    ?? [...layout.desks].sort(byDepth).find(eligible);
  if (spareKeyboardDesk) {
    heroes.push({
      asset: 'spareKeyboard',
      id: `spare-keyboard:${spareKeyboardDesk.id}`,
      position: deskPoint(
        spareKeyboardDesk,
        [-0.58, DESK_MODULE.height + 0.055, 0.08],
      ),
      rotation: [1.08, spareKeyboardDesk.rotY - 0.12, -0.08],
      scale: [0.9, 0.9, 0.9],
    });
    const coilPosition = deskPoint(
      spareKeyboardDesk,
      [-0.43, DESK_MODULE.height + 0.035, 0.2],
    );
    cableCoils.push(
      {
        id: `spare-keyboard-cable:${spareKeyboardDesk.id}:0`,
        position: coilPosition,
        rotation: [-Math.PI / 2, spareKeyboardDesk.rotY, 0],
        scale: [1, 1, 1],
      },
      {
        id: `spare-keyboard-cable:${spareKeyboardDesk.id}:1`,
        position: [
          coilPosition[0] + 0.025,
          coilPosition[1] + 0.008,
          coilPosition[2] - 0.01,
        ],
        rotation: [-Math.PI / 2, spareKeyboardDesk.rotY + 0.08, 0],
        scale: [0.76, 0.76, 0.76],
      },
    );
  }

  return { assets, cableCoils, heroes };
}
