import type { HallLayout, Point3 } from './hallLayout';

export const SECTION_LOAD_RADIUS = 8;

export interface RankedSection {
  key: string;
  distance: number;
}

export function rankSectionsByDistance(
  layout: Pick<HallLayout, 'sections' | 'desks'>,
  camera: Point3,
): RankedSection[] {
  const desksById = new Map(layout.desks.map((desk) => [desk.id, desk]));
  return layout.sections
    .map((section) => ({
      key: section.key,
      distance: Math.min(...section.deskIds.map((id) => {
        const desk = desksById.get(id);
        return desk
          ? Math.hypot(camera[0] - desk.pos[0], camera[2] - desk.pos[2])
          : Infinity;
      })),
    }))
    .sort((left, right) => left.distance - right.distance || left.key.localeCompare(right.key));
}

export function nextSectionToMount(
  layout: Pick<HallLayout, 'sections' | 'desks'>,
  camera: Point3,
  mounted: ReadonlySet<string>,
  radius = SECTION_LOAD_RADIUS,
): string | null {
  const ranked = rankSectionsByDistance(layout, camera);
  const nearest = ranked.find((section) => !mounted.has(section.key));
  if (!nearest) return null;
  return mounted.size === 0 || nearest.distance <= radius ? nearest.key : null;
}
