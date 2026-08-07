import { Suspense, useEffect, useMemo } from 'react';
import {
  CanvasTexture,
  DataTexture,
  LinearFilter,
  RGBAFormat,
  SRGBColorSpace,
} from 'three';
import type { HallDesk, HallLayout } from './hallLayout';
import { PALETTE } from './hallSpec';
import ArchiveWall from './ArchiveWall';
import CeilingSystem from './CeilingSystem';
import DecadeFixtures from './DecadeFixtures';
import DressingLayer from './DressingLayer';
import InstancedHallGeometry from './InstancedHallGeometry';
import {
  type HallLightmapSources,
  hallLightmapsEnabled,
  useHallLightmapSources,
  useSurfaceLightmap,
} from './hallLightmaps';
import {
  type RoomTextureSources,
  useRoomTextureSources,
  useTiledRoomTexture,
} from './roomMaterials';

function CarpetPlane({
  color,
  depth,
  layoutWidth,
  position,
  sources,
  floorLightmap,
  hallDepth,
  hallWidth,
  textureOffsetZ = 0,
}: {
  color: string;
  depth: number;
  layoutWidth: number;
  position: [number, number, number];
  sources?: RoomTextureSources;
  floorLightmap?: HallLightmapSources['floor'];
  hallDepth: number;
  hallWidth: number;
  textureOffsetZ?: number;
}) {
  const map = useTiledRoomTexture(
    sources?.carpetAlbedo,
    [layoutWidth / 2, depth / 2],
    true,
    [0, textureOffsetZ / 2],
  );
  const roughnessMap = useTiledRoomTexture(
    sources?.carpetRoughness,
    [layoutWidth / 2, depth / 2],
    false,
    [0, textureOffsetZ / 2],
  );
  const aoMap = useSurfaceLightmap(
    floorLightmap,
    [layoutWidth / hallWidth, depth / hallDepth],
    [
      (hallWidth - layoutWidth) / (2 * hallWidth),
      (hallDepth / 2 - (position[2] + depth / 2)) / hallDepth,
    ],
  );
  return (
    <mesh rotation={[-Math.PI / 2, 0, 0]} position={position}>
      <planeGeometry args={[layoutWidth, depth]} />
      <meshStandardMaterial
        color={color}
        map={map}
        aoMap={aoMap}
        aoMapIntensity={1}
        roughness={sources ? 1 : 0.97}
        roughnessMap={roughnessMap}
      />
    </mesh>
  );
}

function TrafficWear({
  depth,
  phase,
  position,
  width,
}: {
  depth: number;
  phase: number;
  position: [number, number, number];
  width: number;
}) {
  const alphaMap = useMemo(() => {
    const size = 128;
    const data = new Uint8Array(size * size * 4);
    for (let y = 0; y < size; y += 1) {
      const vertical = y / (size - 1) * 2 - 1;
      for (let x = 0; x < size; x += 1) {
        const horizontal = x / (size - 1) * 2 - 1;
        const centerAisle = Math.exp(-(horizontal * horizontal) / 0.16);
        const crossAisles = Math.exp(-(vertical * vertical) / 0.34) * 0.35;
        const broadMottle = (
          0.24
          + Math.sin(horizontal * 3.1 + vertical * 1.7 + phase) * 0.11
          + Math.sin(horizontal * 7.3 - vertical * 3.2 + phase * 1.9) * 0.07
        );
        const edgeFade = Math.min(1, (1 - Math.abs(vertical)) * 5);
        const value = Math.round(
          Math.min(
            1,
            (broadMottle + centerAisle * 0.55 + crossAisles) * edgeFade,
          ) * 255,
        );
        const index = (y * size + x) * 4;
        data[index] = value;
        data[index + 1] = value;
        data[index + 2] = value;
        data[index + 3] = 255;
      }
    }
    const texture = new DataTexture(data, size, size, RGBAFormat);
    texture.minFilter = LinearFilter;
    texture.magFilter = LinearFilter;
    texture.anisotropy = 8;
    texture.needsUpdate = true;
    return texture;
  }, [phase]);
  useEffect(() => () => alphaMap.dispose(), [alphaMap]);
  return (
    <mesh rotation={[-Math.PI / 2, 0, 0]} position={position} renderOrder={1}>
      <planeGeometry args={[width, depth]} />
      <meshStandardMaterial
        alphaMap={alphaMap}
        color="#39434b"
        depthWrite={false}
        opacity={0.24}
        roughness={1}
        transparent
      />
    </mesh>
  );
}

function createDaylightWashTexture() {
  const canvas = document.createElement('canvas');
  canvas.width = 128;
  canvas.height = 4;
  const context = canvas.getContext('2d');
  if (!context) throw new Error('2D canvas is required for the daylight wash');
  const gradient = context.createLinearGradient(0, 0, canvas.width, 0);
  gradient.addColorStop(0, 'rgba(255, 255, 255, 0.92)');
  gradient.addColorStop(0.38, 'rgba(255, 255, 255, 0.34)');
  gradient.addColorStop(0.78, 'rgba(255, 255, 255, 0.05)');
  gradient.addColorStop(1, 'rgba(255, 255, 255, 0)');
  context.fillStyle = gradient;
  context.fillRect(0, 0, canvas.width, canvas.height);
  const texture = new CanvasTexture(canvas);
  texture.minFilter = LinearFilter;
  texture.magFilter = LinearFilter;
  texture.colorSpace = SRGBColorSpace;
  return texture;
}

function createPerimeterAoTexture() {
  const size = 128;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const context = canvas.getContext('2d');
  if (!context) throw new Error('2D canvas is required for junction occlusion');
  const image = context.createImageData(size, size);
  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      const edgeDistance = Math.min(x, y, size - 1 - x, size - 1 - y);
      const alpha = Math.max(0, 1 - edgeDistance / 7);
      const index = (y * size + x) * 4;
      image.data[index] = 255;
      image.data[index + 1] = 255;
      image.data[index + 2] = 255;
      image.data[index + 3] = Math.round(alpha * alpha * 255);
    }
  }
  context.putImageData(image, 0, 0);
  const texture = new CanvasTexture(canvas);
  texture.minFilter = LinearFilter;
  texture.magFilter = LinearFilter;
  return texture;
}

function FloorLightingOverlays({ layout }: { layout: HallLayout }) {
  const daylight = useMemo(createDaylightWashTexture, []);
  const perimeterAo = useMemo(createPerimeterAoTexture, []);
  useEffect(() => () => {
    daylight.dispose();
    perimeterAo.dispose();
  }, [daylight, perimeterAo]);
  const { width, depth } = layout.dims;
  return (
    <>
      <mesh position={[0, 0.0035, 0]} renderOrder={2} rotation={[-Math.PI / 2, 0, 0]}>
        <planeGeometry args={[width, depth]} />
        <meshBasicMaterial
          color="#c0ddf2"
          depthWrite={false}
          map={daylight}
          opacity={0.19}
          transparent
        />
      </mesh>
      <mesh position={[0, 0.0045, 0]} renderOrder={3} rotation={[-Math.PI / 2, 0, 0]}>
        <planeGeometry args={[width, depth]} />
        <meshBasicMaterial
          color="#273038"
          depthWrite={false}
          map={perimeterAo}
          opacity={0.18}
          transparent
        />
      </mesh>
    </>
  );
}

function Floor({
  lightmaps,
  layout,
  sources,
}: {
  lightmaps?: HallLightmapSources;
  layout: HallLayout;
  sources?: RoomTextureSources;
}) {
  const { width, depth, tileStripDepth } = layout.dims;
  const tileMap = useTiledRoomTexture(
    sources?.tileAlbedo,
    [width / 1.2, tileStripDepth / 1.2],
    true,
  );
  const tileRoughness = useTiledRoomTexture(
    sources?.tileRoughness,
    [width / 1.2, tileStripDepth / 1.2],
  );
  const tileAoMap = useSurfaceLightmap(
    lightmaps?.floor,
    [1, tileStripDepth / depth],
    [0, (depth - tileStripDepth) / depth],
  );
  return (
    <group>
      <CarpetPlane
        color={PALETTE.carpet}
        depth={depth - tileStripDepth}
        layoutWidth={width}
        position={[0, 0, tileStripDepth / 2]}
        sources={sources}
        floorLightmap={lightmaps?.floor}
        hallDepth={depth}
        hallWidth={width}
      />
      {layout.sections.map((section, index) => (
        <CarpetPlane
          key={`carpet-zone:${section.key}`}
          color={index % 2 === 0 ? '#53606a' : '#4b5660'}
          depth={section.zMax - section.zMin - 0.18}
          layoutWidth={width - 1.5}
          position={[0, 0.0015, section.centerZ]}
          sources={sources}
          floorLightmap={lightmaps?.floor}
          hallDepth={depth}
          hallWidth={width}
          textureOffsetZ={section.zMin}
        />
      ))}
      {sources && layout.sections.map((section, index) => (
        <TrafficWear
          key={`traffic-wear:${section.key}`}
          depth={section.zMax - section.zMin - 0.2}
          phase={index * 1.37}
          position={[0, 0.0025, section.centerZ]}
          width={width - 1.55}
        />
      ))}
      <mesh
        rotation={[-Math.PI / 2, 0, 0]}
        position={[0, 0.001, -depth / 2 + tileStripDepth / 2]}
      >
        <planeGeometry args={[width, tileStripDepth]} />
        <meshStandardMaterial
          color={PALETTE.tileFloor}
          aoMap={tileAoMap}
          aoMapIntensity={1}
          envMapIntensity={1.18}
          map={tileMap}
          metalness={0.02}
          roughness={sources ? 1 : 0.55}
          roughnessMap={tileRoughness}
        />
      </mesh>
      {!lightmaps && <FloorLightingOverlays layout={layout} />}
    </group>
  );
}

function WindowWall({
  lightmap,
  layout,
  sources,
}: {
  lightmap?: HallLightmapSources['windowWall'];
  layout: HallLayout;
  sources?: RoomTextureSources;
}) {
  const { width, depth, height } = layout.dims;
  const sillH = 0.85;
  const headH = 0.45;
  const winH = height - sillH - headH;
  const sillMap = useTiledRoomTexture(
    sources?.plasterAlbedo,
    [depth / 1.5, sillH / 1.5],
    true,
  );
  const headMap = useTiledRoomTexture(
    sources?.plasterAlbedo,
    [depth / 1.5, headH / 1.5],
    true,
    [0.37, 0.19],
  );
  const sillRoughness = useTiledRoomTexture(
    sources?.plasterRoughness,
    [depth / 1.5, sillH / 1.5],
  );
  const headRoughness = useTiledRoomTexture(
    sources?.plasterRoughness,
    [depth / 1.5, headH / 1.5],
    false,
    [0.37, 0.19],
  );
  const sillAoMap = useSurfaceLightmap(
    lightmap,
    [1, sillH / height],
    [0, 0],
  );
  const headAoMap = useSurfaceLightmap(
    lightmap,
    [1, headH / height],
    [0, 1 - headH / height],
  );
  return (
    <group position={[-width / 2, 0, 0]} rotation={[0, Math.PI / 2, 0]}>
      <mesh position={[0, sillH / 2, 0]}>
        <planeGeometry args={[depth, sillH]} />
        <meshStandardMaterial
          color={PALETTE.wall}
          map={sillMap}
          aoMap={sillAoMap}
          aoMapIntensity={1}
          roughness={sources ? 1 : 0.92}
          roughnessMap={sillRoughness}
        />
      </mesh>
      <mesh position={[0, height - headH / 2, 0]}>
        <planeGeometry args={[depth, headH]} />
        <meshStandardMaterial
          color={PALETTE.wall}
          map={headMap}
          aoMap={headAoMap}
          aoMapIntensity={1}
          roughness={sources ? 1 : 0.92}
          roughnessMap={headRoughness}
        />
      </mesh>
      {layout.windows.map((bay) => (
        <group key={bay.id} position={[bay.z, sillH + winH / 2, 0]}>
          <mesh>
            <planeGeometry args={[bay.width - 0.14, winH]} />
            <meshStandardMaterial
              color="#dfe7ee"
              emissive="#e8eef4"
              emissiveIntensity={1}
              roughness={1}
            />
          </mesh>
          <mesh position={[0, 0, 0.01]}>
            <planeGeometry args={[0.05, winH]} />
            <meshStandardMaterial color="#d8d5cd" roughness={0.7} />
          </mesh>
        </group>
      ))}
    </group>
  );
}

function Walls({
  lightmaps,
  layout,
  sources,
}: {
  lightmaps?: HallLightmapSources;
  layout: HallLayout;
  sources?: RoomTextureSources;
}) {
  const { width, depth, height } = layout.dims;
  const backWallMap = useTiledRoomTexture(
    sources?.plasterAlbedo,
    [width / 1.5, height / 1.5],
    true,
  );
  const frontWallMap = useTiledRoomTexture(
    sources?.plasterAlbedo,
    [width / 1.5, height / 1.5],
    true,
    [0.41, 0.23],
  );
  const pineMap = useTiledRoomTexture(
    sources?.pineAlbedo,
    [depth / 1.2, height / 1.2],
    true,
  );
  const pineRoughness = useTiledRoomTexture(
    sources?.pineRoughness,
    [depth / 1.2, height / 1.2],
  );
  const pineNormal = useTiledRoomTexture(
    sources?.pineNormal,
    [depth / 1.2, height / 1.2],
  );
  const backWallRoughness = useTiledRoomTexture(
    sources?.plasterRoughness,
    [width / 1.5, height / 1.5],
  );
  const frontWallRoughness = useTiledRoomTexture(
    sources?.plasterRoughness,
    [width / 1.5, height / 1.5],
    false,
    [0.41, 0.23],
  );
  const backWallAo = useSurfaceLightmap(lightmaps?.backWall);
  const frontWallAo = useSurfaceLightmap(lightmaps?.frontWall);
  const pineWallAo = useSurfaceLightmap(lightmaps?.pineWall);
  return (
    <group>
      <mesh position={[0, height / 2, -depth / 2]}>
        <planeGeometry args={[width, height]} />
        <meshStandardMaterial
          color={PALETTE.wall}
          map={backWallMap}
          aoMap={backWallAo}
          aoMapIntensity={1}
          roughness={sources ? 1 : 0.92}
          roughnessMap={backWallRoughness}
        />
      </mesh>
      <mesh position={[0, height / 2, depth / 2]} rotation={[0, Math.PI, 0]}>
        <planeGeometry args={[width, height]} />
        <meshStandardMaterial
          color={PALETTE.wall}
          map={frontWallMap}
          aoMap={frontWallAo}
          aoMapIntensity={1}
          roughness={sources ? 1 : 0.92}
          roughnessMap={frontWallRoughness}
        />
      </mesh>
      <group position={[width / 2, 0, 0]} rotation={[0, -Math.PI / 2, 0]}>
        <mesh position={[0, height / 2, 0]}>
          <planeGeometry args={[depth, height]} />
          <meshStandardMaterial
            color={PALETTE.pine}
            map={pineMap}
            aoMap={pineWallAo}
            aoMapIntensity={1}
            normalMap={pineNormal}
            normalScale={[0.22, 0.22]}
            roughness={sources ? 1 : 0.8}
            roughnessMap={pineRoughness}
          />
        </mesh>
      </group>
      <WindowWall
        layout={layout}
        lightmap={lightmaps?.windowWall}
        sources={sources}
      />
    </group>
  );
}

function BakedShellSurfaces({
  layout,
  sources,
}: {
  layout: HallLayout;
  sources: RoomTextureSources;
}) {
  const lightmaps = useHallLightmapSources();
  return (
    <>
      <Floor layout={layout} lightmaps={lightmaps} sources={sources} />
      <Walls layout={layout} lightmaps={lightmaps} sources={sources} />
    </>
  );
}

function TexturedShellSurfaces({
  baked,
  layout,
}: {
  baked: boolean;
  layout: HallLayout;
}) {
  const sources = useRoomTextureSources();
  if (baked) {
    return (
      <Suspense fallback={(
        <>
          <Floor layout={layout} sources={sources} />
          <Walls layout={layout} sources={sources} />
        </>
      )}
      >
        <BakedShellSurfaces layout={layout} sources={sources} />
      </Suspense>
    );
  }
  return (
    <>
      <Floor layout={layout} sources={sources} />
      <Walls layout={layout} sources={sources} />
    </>
  );
}

interface Props {
  layout: HallLayout;
  onOpenInfo?: (tileId: string) => void;
  onHoverInfo?: (slot: HallDesk, pointerType: string | null) => void;
}

export default function HallShell({ layout, onOpenInfo, onHoverInfo }: Props) {
  const baked = hallLightmapsEnabled(layout, window.location.search);
  return (
    <group>
      <CeilingSystem baked={baked} layout={layout} />
      <ArchiveWall layout={layout} />
      <Suspense fallback={(
        <>
          <Floor layout={layout} />
          <Walls layout={layout} />
        </>
      )}
      >
        <TexturedShellSurfaces baked={baked} layout={layout} />
      </Suspense>
      <InstancedHallGeometry
        layout={layout}
        onOpenInfo={onOpenInfo}
        onHoverInfo={onHoverInfo}
      />
      <DecadeFixtures layout={layout} />
      <DressingLayer
        layout={layout}
        onOpenInfo={onOpenInfo}
        onHoverInfo={onHoverInfo}
      />
    </group>
  );
}
