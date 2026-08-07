import { useEffect, useMemo } from 'react';
import { useTexture } from '@react-three/drei';
import { invalidate } from '@react-three/fiber';
import {
  NoColorSpace,
  RepeatWrapping,
  SRGBColorSpace,
  type Texture,
} from 'three';

const ROOM_TEXTURE_URLS = {
  carpetAlbedo: '/assets/textures/room/carpet-albedo.jpg',
  carpetRoughness: '/assets/textures/room/carpet-roughness.jpg',
  pineAlbedo: '/assets/textures/room/pine-albedo.jpg',
  pineRoughness: '/assets/textures/room/pine-roughness.jpg',
  pineNormal: '/assets/textures/room/pine-normal.jpg',
  deskAlbedo: '/assets/textures/room/desk-albedo.jpg',
  deskRoughness: '/assets/textures/room/desk-roughness.jpg',
  tileAlbedo: '/assets/textures/room/tile-albedo.jpg',
  tileRoughness: '/assets/textures/room/tile-roughness.jpg',
  plasterAlbedo: '/assets/textures/room/plaster-albedo.jpg',
  plasterRoughness: '/assets/textures/room/plaster-roughness.jpg',
} as const;

export interface RoomTextureSources {
  carpetAlbedo: Texture;
  carpetRoughness: Texture;
  pineAlbedo: Texture;
  pineRoughness: Texture;
  pineNormal: Texture;
  deskAlbedo: Texture;
  deskRoughness: Texture;
  tileAlbedo: Texture;
  tileRoughness: Texture;
  plasterAlbedo: Texture;
  plasterRoughness: Texture;
}

export function useRoomTextureSources(): RoomTextureSources {
  const sources = useTexture(ROOM_TEXTURE_URLS) as RoomTextureSources;
  useEffect(() => {
    invalidate();
  }, [sources]);
  return sources;
}

export function useTiledRoomTexture(
  source: Texture | undefined,
  repeat: readonly [number, number],
  albedo = false,
  offset: readonly [number, number] = [0, 0],
): Texture | undefined {
  const [repeatX, repeatY] = repeat;
  const [offsetX, offsetY] = offset;
  const texture = useMemo(() => {
    if (!source) return undefined;
    const clone = source.clone();
    clone.wrapS = RepeatWrapping;
    clone.wrapT = RepeatWrapping;
    clone.repeat.set(repeatX, repeatY);
    clone.offset.set(offsetX, offsetY);
    clone.colorSpace = albedo ? SRGBColorSpace : NoColorSpace;
    clone.anisotropy = 8;
    clone.needsUpdate = true;
    return clone;
  }, [albedo, offsetX, offsetY, repeatX, repeatY, source]);

  useEffect(() => () => texture?.dispose(), [texture]);
  return texture;
}
