import { Suspense, useEffect, useMemo } from 'react';
import { useThree } from '@react-three/fiber';
import {
  CanvasTexture,
  Euler,
  LinearFilter,
  LinearMipmapLinearFilter,
  Matrix4,
  Quaternion,
  RepeatWrapping,
  SRGBColorSpace,
  Vector3,
  type Texture,
} from 'three';
import type { HallLayout, Point3 } from './hallLayout';
import {
  CEILING_GRID_MODULE,
  PALETTE,
  TROFFER_SIZE,
} from './hallSpec';
import { Instances } from './InstancedHallGeometry';
import {
  HALL_LIGHTMAP_URLS,
  useHallLightmapTexture,
  useSurfaceLightmap,
} from './hallLightmaps';

const TILE_PATTERN_CELLS = 16;
const TILE_PATTERN_SIZE = 1536;
const GRID_FACE_WIDTH = 0.024;
const GRID_DROP = 0.009;
const REVEAL_WIDTH = 0.025;

function transform(position: Point3, scale: Point3, rotation: Point3 = [0, 0, 0]) {
  return new Matrix4().compose(
    new Vector3(...position),
    new Quaternion().setFromEuler(new Euler(...rotation)),
    new Vector3(...scale),
  );
}

function randomFor(seed: number) {
  let value = seed | 0;
  return () => {
    value ^= value << 13;
    value ^= value >>> 17;
    value ^= value << 5;
    return (value >>> 0) / 0xffffffff;
  };
}

function createTileTexture(width: number, depth: number, anisotropy: number) {
  const canvas = document.createElement('canvas');
  canvas.width = TILE_PATTERN_SIZE;
  canvas.height = TILE_PATTERN_SIZE;
  const context = canvas.getContext('2d');
  if (!context) throw new Error('2d canvas unavailable');

  const cellSize = TILE_PATTERN_SIZE / TILE_PATTERN_CELLS;
  context.fillStyle = PALETTE.ceiling;
  context.fillRect(0, 0, canvas.width, canvas.height);
  for (let z = 0; z < TILE_PATTERN_CELLS; z += 1) {
    for (let x = 0; x < TILE_PATTERN_CELLS; x += 1) {
      const random = randomFor(4919 + x * 131 + z * 977);
      const tone = 228 + Math.round((random() - 0.5) * 11);
      context.fillStyle = `rgb(${tone + 6}, ${tone + 3}, ${tone - 5})`;
      context.fillRect(x * cellSize + 2, z * cellSize + 2, cellSize - 4, cellSize - 4);

      for (let speck = 0; speck < 110; speck += 1) {
        const px = x * cellSize + 4 + random() * (cellSize - 8);
        const py = z * cellSize + 4 + random() * (cellSize - 8);
        const alpha = 0.12 + random() * 0.24;
        const radius = 0.55 + random() * 1.25;
        context.fillStyle = `rgba(82, 78, 70, ${alpha})`;
        context.fillRect(px, py, radius, radius);
      }
    }
  }

  context.strokeStyle = '#c4c1b9';
  context.lineWidth = 3;
  for (let index = 0; index <= TILE_PATTERN_CELLS; index += 1) {
    const offset = index * cellSize;
    context.beginPath();
    context.moveTo(offset, 0);
    context.lineTo(offset, TILE_PATTERN_SIZE);
    context.stroke();
    context.beginPath();
    context.moveTo(0, offset);
    context.lineTo(TILE_PATTERN_SIZE, offset);
    context.stroke();
  }

  const texture = new CanvasTexture(canvas);
  const patternSpan = CEILING_GRID_MODULE * TILE_PATTERN_CELLS;
  texture.colorSpace = SRGBColorSpace;
  texture.wrapS = RepeatWrapping;
  texture.wrapT = RepeatWrapping;
  texture.repeat.set(width / patternSpan, depth / patternSpan);
  texture.offset.set(
    ((-(width / 2) / patternSpan) % 1 + 1) % 1,
    ((-(depth / 2 + CEILING_GRID_MODULE / 2) / patternSpan) % 1 + 1) % 1,
  );
  texture.magFilter = LinearFilter;
  texture.minFilter = LinearMipmapLinearFilter;
  texture.anisotropy = anisotropy;
  return texture;
}

function createDiffuserTexture(anisotropy: number) {
  const canvas = document.createElement('canvas');
  canvas.width = 256;
  canvas.height = 512;
  const context = canvas.getContext('2d');
  if (!context) throw new Error('2d canvas unavailable');

  context.fillStyle = '#cec5aa';
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.strokeStyle = 'rgba(90, 86, 76, 0.24)';
  context.lineWidth = 1;
  for (let x = -canvas.height; x < canvas.width + canvas.height; x += 9) {
    context.beginPath();
    context.moveTo(x, 0);
    context.lineTo(x + canvas.height, canvas.height);
    context.stroke();
  }
  context.strokeStyle = 'rgba(255, 255, 248, 0.28)';
  for (let x = 0; x < canvas.width + canvas.height; x += 12) {
    context.beginPath();
    context.moveTo(x, 0);
    context.lineTo(x - canvas.height, canvas.height);
    context.stroke();
  }

  const texture = new CanvasTexture(canvas);
  texture.colorSpace = SRGBColorSpace;
  texture.anisotropy = anisotropy;
  return texture;
}

function gridLinePositions(span: number, phase: number) {
  const positions: number[] = [];
  const first = Math.ceil((-span / 2 - phase) / CEILING_GRID_MODULE);
  const last = Math.floor((span / 2 - phase) / CEILING_GRID_MODULE);
  for (let index = first; index <= last; index += 1) {
    positions.push(index * CEILING_GRID_MODULE + phase);
  }
  return positions;
}

function CeilingSurface({
  layout,
  lightmap,
}: {
  layout: HallLayout;
  lightmap?: Texture;
}) {
  const { width, depth, height } = layout.dims;
  const anisotropy = useThree((state) => state.gl.capabilities.getMaxAnisotropy());
  const tileTexture = useMemo(
    () => createTileTexture(width, depth, anisotropy),
    [anisotropy, depth, width],
  );
  const diffuserTexture = useMemo(
    () => createDiffuserTexture(anisotropy),
    [anisotropy],
  );
  useEffect(() => () => tileTexture.dispose(), [tileTexture]);
  useEffect(() => () => diffuserTexture.dispose(), [diffuserTexture]);
  const aoMap = useSurfaceLightmap(lightmap);

  const matrices = useMemo(() => {
    const tees: Matrix4[] = [];
    for (const x of gridLinePositions(width, 0)) {
      tees.push(transform(
        [x, height - GRID_DROP / 2, 0],
        [GRID_FACE_WIDTH, GRID_DROP, depth],
      ));
    }
    for (const z of gridLinePositions(depth, CEILING_GRID_MODULE / 2)) {
      tees.push(transform(
        [0, height - GRID_DROP / 2, z],
        [width, GRID_DROP, GRID_FACE_WIDTH],
      ));
    }

    const reveals = [
      transform(
        [-width / 2 + REVEAL_WIDTH / 2, height - 0.012, 0],
        [REVEAL_WIDTH, 0.02, depth],
      ),
      transform(
        [width / 2 - REVEAL_WIDTH / 2, height - 0.012, 0],
        [REVEAL_WIDTH, 0.02, depth],
      ),
      transform(
        [0, height - 0.012, -depth / 2 + REVEAL_WIDTH / 2],
        [width, 0.02, REVEAL_WIDTH],
      ),
      transform(
        [0, height - 0.012, depth / 2 - REVEAL_WIDTH / 2],
        [width, 0.02, REVEAL_WIDTH],
      ),
    ];

    const housings: Matrix4[] = [];
    const rims: Matrix4[] = [];
    const diffusers: Matrix4[] = [];
    const [trofferWidth, trofferDepth] = TROFFER_SIZE;
    const rimWidth = 0.034;
    for (const [x, , z] of layout.troffers) {
      housings.push(transform(
        [x, height + 0.02, z],
        [trofferWidth - 0.012, 0.055, trofferDepth - 0.012],
      ));
      rims.push(
        transform(
          [x - trofferWidth / 2 + rimWidth / 2, height - 0.006, z],
          [rimWidth, 0.022, trofferDepth],
        ),
        transform(
          [x + trofferWidth / 2 - rimWidth / 2, height - 0.006, z],
          [rimWidth, 0.022, trofferDepth],
        ),
        transform(
          [x, height - 0.006, z - trofferDepth / 2 + rimWidth / 2],
          [trofferWidth - rimWidth * 2, 0.022, rimWidth],
        ),
        transform(
          [x, height - 0.006, z + trofferDepth / 2 - rimWidth / 2],
          [trofferWidth - rimWidth * 2, 0.022, rimWidth],
        ),
      );
      diffusers.push(transform(
        [x, height - 0.014, z],
        [trofferWidth - rimWidth * 2.5, trofferDepth - rimWidth * 2.5, 1],
        [Math.PI / 2, 0, 0],
      ));
    }
    return { tees, reveals, housings, rims, diffusers };
  }, [depth, height, layout.troffers, width]);

  return (
    <group>
      <mesh rotation={[Math.PI / 2, 0, 0]} position={[0, height, 0]}>
        <planeGeometry args={[width, depth]} />
        <meshStandardMaterial
          map={tileTexture}
          aoMap={aoMap}
          aoMapIntensity={1}
          bumpMap={tileTexture}
          bumpScale={0.006}
          color="#fffdf7"
          roughness={0.97}
        />
      </mesh>
      <Instances matrices={matrices.tees}>
        <boxGeometry />
        <meshStandardMaterial color={PALETTE.ceilingGrid} roughness={0.48} metalness={0.32} />
      </Instances>
      <Instances matrices={matrices.reveals}>
        <boxGeometry />
        <meshStandardMaterial color="#5f5c56" roughness={0.82} />
      </Instances>
      <Instances matrices={matrices.housings}>
        <boxGeometry />
        <meshStandardMaterial color="#8f8c85" roughness={0.58} metalness={0.22} />
      </Instances>
      <Instances matrices={matrices.rims}>
        <boxGeometry />
        <meshStandardMaterial color="#c8c4bb" roughness={0.42} metalness={0.4} />
      </Instances>
      <Instances matrices={matrices.diffusers}>
        <planeGeometry />
        <meshStandardMaterial
          map={diffuserTexture}
          emissiveMap={diffuserTexture}
          color="#ffffff"
          emissive="#ded4b9"
          emissiveIntensity={0.52}
          roughness={0.66}
        />
      </Instances>
    </group>
  );
}

function BakedCeiling({ layout }: { layout: HallLayout }) {
  const lightmap = useHallLightmapTexture(HALL_LIGHTMAP_URLS.ceiling);
  return <CeilingSurface layout={layout} lightmap={lightmap} />;
}

export default function CeilingSystem({
  baked = false,
  layout,
}: {
  baked?: boolean;
  layout: HallLayout;
}) {
  if (!baked) return <CeilingSurface layout={layout} />;
  return (
    <Suspense fallback={<CeilingSurface layout={layout} />}>
      <BakedCeiling layout={layout} />
    </Suspense>
  );
}
