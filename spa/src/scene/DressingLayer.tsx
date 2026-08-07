import { Suspense, useEffect, useMemo } from 'react';
import { useGLTF, useTexture } from '@react-three/drei';
import {
  Euler,
  Matrix4,
  Mesh,
  Quaternion,
  SRGBColorSpace,
  Vector3,
  type BufferGeometry,
  type Group,
  type Material,
  type Texture,
} from 'three';
import type { HallDesk, HallLayout, Point3 } from './hallLayout';
import { DESK_MODULE, PALETTE } from './hallSpec';
import DensityVignettes, { WhiteWallStorageCluster } from './DensityVignettes';
import ExhibitPlacards from './ExhibitPlacards';
import { Instances } from './InstancedHallGeometry';
import {
  MODELS,
  type MachineModel,
} from './machines';
import { prepareModelScene } from './modelNormalization';
import { buildStationKitBindings } from './stationKitBindings';
import { lampScaleForDesk } from './lampScale';

const PARAM = '/assets/models/v2/param';
const POSTER = '/assets/textures/dressing';

const DRESSING_ASSETS = {
  clock: `${PARAM}/dressing-clock.glb`,
  extinguisher: `${PARAM}/dressing-extinguisher.glb`,
  plant: `${PARAM}/dressing-plant.glb`,
  lavender: `${PARAM}/dressing-lavender.glb`,
  lamp: `${PARAM}/dressing-desk-lamp.glb`,
  displayCase: `${PARAM}/dressing-display-case.glb`,
  dustSmall: `${PARAM}/dressing-dust-small.glb`,
  dustLarge: `${PARAM}/dressing-dust-large.glb`,
  jacket: `${PARAM}/dressing-jacket.glb`,
  mousePad: `${PARAM}/dressing-mouse-pad.glb`,
  binders: `${PARAM}/dressing-binders.glb`,
  floppyBox: `${PARAM}/dressing-floppy-box.glb`,
} as const;

const POSTER_URLS = [
  `${POSTER}/microdealer-1982.jpg`,
  `${POSTER}/commodore-1984.jpg`,
  `${POSTER}/terminal-1978.jpg`,
  `${POSTER}/business-pc-1985.jpg`,
  `${POSTER}/workstation-1991.jpg`,
  `${POSTER}/portable-1987.jpg`,
  `${POSTER}/personal-computers.jpg`,
  `${POSTER}/museum-service-banner.jpg`,
  `${POSTER}/wallpaper-orange-floral.jpg`,
] as const;

type AssetKey = keyof typeof DRESSING_ASSETS;
type HeroKey =
  | 'aisleChair'
  | 'luggable'
  | 'phoneDockEarly'
  | 'phoneDockModern'
  | 'spareKeyboard';

const HERO_MODELS = {
  aisleChair: MODELS.chairTaskBlue,
  luggable: MODELS.terminalB,
  phoneDockEarly: MODELS.phoneA,
  phoneDockModern: MODELS.phoneB,
  spareKeyboard: MODELS.keyboardA,
} as const satisfies Record<HeroKey, MachineModel>;

interface Placement {
  id: string;
  position: Point3;
  rotation: Point3;
  scale: Point3;
}

interface ModelSource {
  geometry: BufferGeometry;
  material: Material | undefined;
  matrix: Matrix4;
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

function sourceMeshes(scene: Group): ModelSource[] {
  scene.updateMatrixWorld(true);
  const sources: ModelSource[] = [];
  scene.traverse((object) => {
    if (!(object instanceof Mesh)) return;
    sources.push({
      geometry: object.geometry,
      material: Array.isArray(object.material) ? object.material[0] : object.material,
      matrix: object.matrixWorld.clone(),
    });
  });
  return sources;
}

function normalizedSourceMeshes(scene: Group, model: MachineModel): ModelSource[] {
  const prepared = prepareModelScene(scene, model);
  prepared.updateMatrixWorld(true);
  const sources: ModelSource[] = [];
  prepared.traverse((object) => {
    if (!(object instanceof Mesh)) return;
    sources.push({
      geometry: object.geometry,
      material: Array.isArray(object.material) ? object.material[0] : object.material,
      matrix: object.matrixWorld.clone(),
    });
  });
  if (sources.length === 0) throw new Error(`density prop GLB has no mesh: ${model.url}`);
  return sources;
}

function placementMatrices(source: ModelSource, placements: Placement[]) {
  return placements.map((placement) => new Matrix4().compose(
    new Vector3(...placement.position),
    new Quaternion().setFromEuler(new Euler(...placement.rotation)),
    new Vector3(...placement.scale),
  ).multiply(source.matrix));
}

function InstancedDressingAsset({
  asset,
  placements,
}: {
  asset: AssetKey;
  placements: Placement[];
}) {
  const { scene } = useGLTF(DRESSING_ASSETS[asset]);
  const sources = useMemo(() => sourceMeshes(scene), [scene]);
  return sources.map((source, index) => (
    <Instances
      key={`${asset}:${index}`}
      matrices={placementMatrices(source, placements)}
      geometry={source.geometry}
      material={source.material}
    />
  ));
}

function InstancedHeroModel({
  modelKey,
  placements,
}: {
  modelKey: HeroKey;
  placements: Placement[];
}) {
  const model = HERO_MODELS[modelKey];
  const { scene } = useGLTF(model.url);
  const sources = useMemo(
    () => normalizedSourceMeshes(scene, model),
    [scene, model],
  );
  return sources.map((source, index) => (
    <Instances
      key={`${modelKey}:${index}`}
      matrices={placementMatrices(source, placements)}
      geometry={source.geometry}
      material={source.material}
    />
  ));
}

function clusteredDesks(
  layout: HallLayout,
  count: number,
  sectionIndices: number[],
  salt: number,
  required: HallDesk[] = [],
) {
  const keys = new Set(
    sectionIndices
      .map((index) => layout.sections[index % layout.sections.length]?.key)
      .filter((key): key is string => Boolean(key)),
  );
  const preferred = layout.desks.filter((desk) => keys.has(desk.sectionKey));
  const overflow = layout.desks.filter((desk) => !keys.has(desk.sectionKey));
  const ranked = [...preferred, ...overflow].sort(
    (a, b) => stableVariation(b.id, salt) - stableVariation(a.id, salt),
  );
  const selected: HallDesk[] = [];
  for (const desk of [...required, ...ranked]) {
    if (selected.some((candidate) => candidate.id === desk.id)) continue;
    selected.push(desk);
    if (selected.length === count) break;
  }
  return selected;
}

function buildPlacements(layout: HallLayout) {
  const byAsset = new Map<AssetKey, Placement[]>();
  const byHero = new Map<HeroKey, Placement[]>();
  const add = (
    asset: AssetKey,
    id: string,
    position: Point3,
    rotation: Point3 = [0, 0, 0],
    scale: Point3 = [1, 1, 1],
  ) => {
    const placements = byAsset.get(asset) ?? [];
    placements.push({ id, position, rotation, scale });
    byAsset.set(asset, placements);
  };
  const addHero = (
    modelKey: HeroKey,
    id: string,
    position: Point3,
    rotation: Point3 = [0, 0, 0],
    scale: Point3 = [1, 1, 1],
  ) => {
    const placements = byHero.get(modelKey) ?? [];
    placements.push({ id, position, rotation, scale });
    byHero.set(modelKey, placements);
  };
  const { width, depth } = layout.dims;
  const firstDesk = layout.desks[0];
  const firstSection = layout.sections[0];
  const pineDesk = layout.desks
    .filter((desk) => desk.sectionKey === firstSection?.key)
    .sort((a, b) => b.pos[0] - a.pos[0])[0] ?? firstDesk;

  const lamps = clusteredDesks(
    layout,
    Math.max(1, Math.round(layout.desks.length * 0.2)),
    [0],
    311,
    [firstDesk, pineDesk].filter((desk): desk is HallDesk => Boolean(desk)),
  );
  for (const desk of lamps) {
    const lampScale = lampScaleForDesk(desk);
    add(
      'lamp',
      `lamp:${desk.id}`,
      deskPoint(desk, [
        -0.61,
        DESK_MODULE.height + 0.002,
        -0.23 + stableVariation(desk.id, 313) * 0.025,
      ]),
      [0, desk.rotY + stableVariation(desk.id, 317) * Math.PI / 30, 0],
      [lampScale, lampScale, lampScale],
    );
  }

  const stationKits = buildStationKitBindings(layout);
  for (const binding of stationKits.assets) {
    add(
      binding.asset,
      binding.id,
      binding.position,
      binding.rotation,
      binding.scale,
    );
  }
  for (const binding of stationKits.heroes) {
    addHero(
      binding.asset,
      binding.id,
      binding.position,
      binding.rotation,
      binding.scale,
    );
  }

  if (firstDesk) {
    add(
      'lavender',
      `lavender:${firstDesk.id}`,
      deskPoint(firstDesk, [-0.24, DESK_MODULE.height + 0.002, -0.30]),
      [0, firstDesk.rotY + 0.2, 0],
      [0.88, 0.88, 0.88],
    );
  }
  if (pineDesk && pineDesk.id !== firstDesk?.id) {
    add(
      'lavender',
      `lavender:${pineDesk.id}`,
      deskPoint(pineDesk, [-0.24, DESK_MODULE.height + 0.002, -0.30]),
      [0, pineDesk.rotY - 0.14, 0],
      [0.92, 0.92, 0.92],
    );
  }
  add(
    'plant',
    'plant:front-corner',
    [-width / 2 + 0.42, 0, depth / 2 - 1.15],
    [0, 0.35, 0],
    [0.92, 0.92, 0.92],
  );

  add(
    'clock',
    'clock:pine-vignette',
    [
      width / 2 - 0.035,
      1.79,
      (firstSection?.centerZ ?? 0) + 1.16,
    ],
    [0, -Math.PI / 2, 0],
  );
  add(
    'jacket',
    'jacket:pine-vignette',
    [
      width / 2 - 0.045,
      1.14,
      (firstSection?.centerZ ?? 0) - 1.05,
    ],
    [0, -Math.PI / 2, 0],
    [0.96, 0.96, 0.96],
  );
  add(
    'extinguisher',
    'extinguisher:white-wall-cluster',
    [1.18, 0.06, depth / 2 - 0.045],
    [0, Math.PI, 0],
    [0.92, 0.92, 0.92],
  );

  const caseSections = [
    layout.sections[0],
    layout.sections[Math.min(2, layout.sections.length - 1)],
  ].filter((section, index, sections) =>
    Boolean(section) && sections.findIndex((item) => item?.key === section?.key) === index);
  caseSections.forEach((section, index) => {
    add(
      'displayCase',
      `display-case:${section.key}`,
      [
        index === 0 ? -1.85 : 2.0,
        0,
        section.zMin + 1.0,
      ],
      [0, (index === 0 ? -1 : 1) * Math.PI / 90, 0],
      [0.88, 0.88, 0.88],
    );
  });
  const cornerAnchor: Point3 = [
    -width / 2 + 3.0,
    0,
    depth / 2 - 3.25,
  ];
  [0, 1].forEach((index) => {
    addHero(
      'luggable',
      `luggable-stack:${index}`,
      [
        cornerAnchor[0] + (index === 1 ? 0.025 : 0),
        0.705 + index * 0.235,
        cornerAnchor[2] + (index === 1 ? -0.012 : 0),
      ],
      [
        0,
        stableVariation(`luggable-stack:${index}`, 701) * Math.PI / 45,
        stableVariation(`luggable-stack:${index}`, 709) * Math.PI / 90,
      ],
      [0.84, 0.84, 0.84],
    );
  });

  const middleSection = layout.sections[Math.floor(layout.sections.length / 2)];
  addHero(
    'aisleChair',
    'aisle-chair:mid-hall',
    [
      -width / 2 + 1.18,
      0,
      (middleSection?.centerZ ?? 0) + 0.18,
    ],
    [0, Math.PI * 0.68, 0],
  );

  return {
    byAsset,
    byHero,
  };
}

function PosterFrame({
  emissive = false,
  height,
  position,
  rotation,
  texture,
  width,
}: {
  emissive?: boolean;
  height: number;
  position: Point3;
  rotation: Point3;
  texture: Texture;
  width: number;
}) {
  const rail = Math.min(width, height) * 0.065;
  return (
    <group position={position} rotation={rotation}>
      <mesh position={[0, 0, -0.008]}>
        <boxGeometry args={[width + rail * 1.7, height + rail * 1.7, 0.035]} />
        <meshStandardMaterial color="#65462f" roughness={0.72} />
      </mesh>
      <mesh position={[0, 0, 0.014]}>
        <planeGeometry args={[width, height]} />
        <meshStandardMaterial
          emissive={emissive ? '#d8c7a6' : '#000000'}
          emissiveIntensity={emissive ? 0.42 : 0}
          emissiveMap={emissive ? texture : null}
          map={texture}
          roughness={emissive ? 0.52 : 0.82}
        />
      </mesh>
    </group>
  );
}

function PosterIdentity({ layout }: { layout: HallLayout }) {
  const textures = useTexture([...POSTER_URLS]);
  useEffect(() => {
    textures.forEach((texture) => {
      texture.colorSpace = SRGBColorSpace;
      texture.anisotropy = 8;
      texture.needsUpdate = true;
    });
  }, [textures]);
  const { width, depth } = layout.dims;
  const first = layout.sections[0];
  const second = layout.sections[1] ?? first;
  const middle = layout.sections[Math.floor(layout.sections.length / 2)] ?? first;
  const windowPosters = [
    { texture: 0, z: -depth * 0.27, width: 0.48, height: 0.64 },
    { texture: 4, z: 0.02, width: 0.48, height: 0.64 },
    { texture: 5, z: depth * 0.28, width: 0.48, height: 0.64 },
  ];
  return (
    <group>
      {windowPosters.map((poster, index) => (
        <PosterFrame
          key={`window-poster:${poster.texture}`}
          height={poster.height}
          position={[
            -width / 2 + 0.026,
            2.47 + (index % 2) * 0.02,
            poster.z,
          ]}
          rotation={[0, Math.PI / 2, index % 2 === 0 ? -0.018 : 0.012]}
          texture={textures[poster.texture]}
          width={poster.width}
        />
      ))}
      <PosterFrame
        height={0.72}
        position={[width / 2 - 0.028, 1.73, (first?.centerZ ?? 0) + 0.35]}
        rotation={[0, -Math.PI / 2, 0]}
        texture={textures[2]}
        width={0.54}
      />
      <PosterFrame
        height={0.68}
        position={[width / 2 - 0.029, 1.64, (first?.centerZ ?? 0) - 2.05]}
        rotation={[0, -Math.PI / 2, 0.064]}
        texture={textures[3]}
        width={0.51}
      />
      <PosterFrame
        emissive
        height={0.42}
        position={[width / 2 - 0.031, 2.05, (second?.centerZ ?? 0) + 0.42]}
        rotation={[0, -Math.PI / 2, 0]}
        texture={textures[6]}
        width={0.84}
      />
      <PosterFrame
        height={0.64}
        position={[-2.25, 2.17, depth / 2 - 0.028]}
        rotation={[0, Math.PI, 0]}
        texture={textures[7]}
        width={2.15}
      />
      <PosterFrame
        height={1.18}
        position={[2.55, 1.72, depth / 2 - 0.029]}
        rotation={[0, Math.PI, 0]}
        texture={textures[5]}
        width={0.88}
      />
      <group
        position={[
          width / 2 - 0.018,
          1.34,
          (middle?.centerZ ?? 0) + 1.10,
        ]}
        rotation={[0, -Math.PI / 2, 0]}
      >
        <mesh>
          <planeGeometry args={[0.78, 2.10]} />
          <meshStandardMaterial map={textures[8]} roughness={0.9} />
        </mesh>
        <mesh position={[0, -1.075, 0.02]}>
          <boxGeometry args={[0.84, 0.05, 0.045]} />
          <meshStandardMaterial color={PALETTE.pineDark} roughness={0.8} />
        </mesh>
      </group>
    </group>
  );
}

export default function DressingLayer({
  layout,
  onHoverInfo,
  onOpenInfo,
}: {
  layout: HallLayout;
  onHoverInfo?: (slot: HallDesk, pointerType: string | null) => void;
  onOpenInfo?: (tileId: string) => void;
}) {
  const placements = useMemo(() => buildPlacements(layout), [layout]);
  return (
    <group>
      <ExhibitPlacards
        layout={layout}
        onHoverInfo={onHoverInfo}
        onOpenInfo={onOpenInfo}
      />
      <DensityVignettes layout={layout} />
      <WhiteWallStorageCluster layout={layout} />
      <Suspense fallback={null}>
        {[...placements.byAsset].map(([asset, assetPlacements]) => (
          <InstancedDressingAsset
            key={asset}
            asset={asset}
            placements={assetPlacements}
          />
        ))}
        {[...placements.byHero].map(([modelKey, modelPlacements]) => (
          <InstancedHeroModel
            key={modelKey}
            modelKey={modelKey}
            placements={modelPlacements}
          />
        ))}
        <PosterIdentity layout={layout} />
      </Suspense>
    </group>
  );
}
