import { useEffect, useMemo } from 'react';
import { useTexture } from '@react-three/drei';
import { invalidate } from '@react-three/fiber';
import { NoColorSpace, type Texture } from 'three';
import type { HallLayout } from './hallLayout';

const BAKED_DIMS = {
  width: 12.8,
  depth: 19,
  height: 2.8,
} as const;

const ROOT = '/assets/textures/hall-lightmaps/hall-12p8x19p0';

export const HALL_LIGHTMAP_URLS = {
  floor: `${ROOT}-floor.jpg`,
  ceiling: `${ROOT}-ceiling.jpg`,
  backWall: `${ROOT}-back-wall.jpg`,
  frontWall: `${ROOT}-front-wall.jpg`,
  pineWall: `${ROOT}-pine-wall.jpg`,
  windowWall: `${ROOT}-window-wall.jpg`,
} as const;

export interface HallLightmapSources {
  floor: Texture;
  ceiling: Texture;
  backWall: Texture;
  frontWall: Texture;
  pineWall: Texture;
  windowWall: Texture;
}

function close(left: number, right: number) {
  return Math.abs(left - right) < 1e-4;
}

export function hallLightmapsEnabled(layout: HallLayout, search: string) {
  const requested = new URLSearchParams(search).get('bakedLight');
  if (requested === '0' || requested === 'false') return false;
  const { width, depth, height } = layout.dims;
  return close(width, BAKED_DIMS.width)
    && close(depth, BAKED_DIMS.depth)
    && close(height, BAKED_DIMS.height);
}

export function useHallLightmapSources(): HallLightmapSources {
  const sources = useTexture(HALL_LIGHTMAP_URLS) as HallLightmapSources;
  useEffect(() => {
    for (const texture of Object.values(sources)) {
      texture.colorSpace = NoColorSpace;
      texture.anisotropy = 8;
      texture.needsUpdate = true;
    }
    invalidate();
  }, [sources]);
  return sources;
}

export function useHallLightmapTexture(url: string): Texture {
  const texture = useTexture(url);
  useEffect(() => {
    texture.colorSpace = NoColorSpace;
    texture.anisotropy = 8;
    texture.needsUpdate = true;
    invalidate();
  }, [texture]);
  return texture;
}

export function useSurfaceLightmap(
  source: Texture | undefined,
  repeat: readonly [number, number] = [1, 1],
  offset: readonly [number, number] = [0, 0],
) {
  const [repeatX, repeatY] = repeat;
  const [offsetX, offsetY] = offset;
  const texture = useMemo(() => {
    if (!source) return undefined;
    const clone = source.clone();
    clone.colorSpace = NoColorSpace;
    clone.repeat.set(repeatX, repeatY);
    clone.offset.set(offsetX, offsetY);
    clone.anisotropy = 8;
    clone.needsUpdate = true;
    return clone;
  }, [offsetX, offsetY, repeatX, repeatY, source]);
  useEffect(() => () => texture?.dispose(), [texture]);
  return texture;
}
