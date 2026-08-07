import { useEffect, useMemo } from 'react';
import { useGLTF } from '@react-three/drei';
import { Box3 } from 'three';
import type { MachineModel } from './machines';
import {
  prepareModelScene,
  type MachineAging,
  type MachineFinish,
} from './modelNormalization';
import ScreenPlane from './ScreenPlane';

// Loads a sourced GLB and normalizes it into predictable space: uniform scale
// so its height equals targetH, centered on X/Z, base resting at y=0, facing
// -Z→+Z (plus optional per-model yaw fix). Authoring scale/origin never leaks
// into layout code.
interface Props {
  model: MachineModel;
  aging?: MachineAging;
  finish?: MachineFinish;
  tileId?: string;
  bootVideo?: string;
  onOpenInfo?: () => void;
  onHoverInfo?: (pointerType: string | null) => void;
}

export default function NormalizedModel({
  model,
  aging,
  finish,
  tileId,
  bootVideo,
  onOpenInfo,
  onHoverInfo,
}: Props) {
  const { scene } = useGLTF(model.url);
  const prepared = useMemo(
    () => prepareModelScene(scene, model, aging, finish),
    [aging, finish, model, scene],
  );
  useEffect(() => {
    if (!import.meta.env.DEV) return;
    const bounds = new Box3().setFromObject(prepared);
    const store = (window as unknown as {
      __normalizedModelBounds?: Record<string, {
        min: [number, number, number];
        max: [number, number, number];
      }>;
    });
    store.__normalizedModelBounds ??= {};
    store.__normalizedModelBounds[model.url] = {
      min: bounds.min.toArray(),
      max: bounds.max.toArray(),
    };
  }, [model.url, prepared]);
  return (
    <group>
      <primitive object={prepared} />
      {model.screen && tileId && (
        <ScreenPlane
          tileId={tileId}
          bootVideo={bootVideo}
          screen={model.screen}
          onOpenInfo={onOpenInfo}
          onHoverInfo={onHoverInfo}
        />
      )}
    </group>
  );
}
