import { useEffect } from 'react';
import { useThree } from '@react-three/fiber';
import { Vector3 } from 'three';
import { DESK_MODULE } from './hallSpec';
import type { HallLayout } from './hallLayout';

interface SceneExhibitDebugEntry {
  id: string;
  row: number;
  sectionKey: string;
  ndc: [number, number];
}

export default function SceneInteractionDebug({ layout }: { layout: HallLayout }) {
  const { camera } = useThree();

  useEffect(() => {
    if (!import.meta.env.DEV) return undefined;
    const debugWindow = window as typeof window & {
      __museumExhibitDebug?: () => SceneExhibitDebugEntry[];
    };
    debugWindow.__museumExhibitDebug = () => layout.desks.map((desk) => {
      const point = new Vector3(
        desk.pos[0],
        desk.pos[1] + DESK_MODULE.height + 0.015,
        desk.pos[2],
      ).project(camera);
      return {
        id: desk.entry.id,
        row: desk.row,
        sectionKey: desk.sectionKey,
        ndc: [point.x, point.y],
      };
    });
    return () => {
      delete debugWindow.__museumExhibitDebug;
    };
  }, [camera, layout]);

  return null;
}
