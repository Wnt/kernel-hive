import { Suspense, useEffect, useMemo } from 'react';
import { useGLTF } from '@react-three/drei';
import {
  CanvasTexture,
  Euler,
  LinearFilter,
  Matrix4,
  Mesh,
  Quaternion,
  Vector3,
  type BufferGeometry,
  type Group,
  type Material,
} from 'three';
import type { HallLayout, Point3 } from './hallLayout';
import { Instances } from './InstancedHallGeometry';
import { MODELS, type MachineModel, type ModelKey } from './machines';
import { prepareModelScene } from './modelNormalization';

const PARAM = '/assets/models/v2/param';

const ARCHIVE_DISPLAY_MODELS = [
  'compactA',
  'homeCrtA',
  'homeCrtC',
  'crtD',
  'terminalB',
] as const satisfies readonly ModelKey[];

const ARCHIVE_LOW_MODELS = [
  'c64A',
  'amigaA',
  'eightBitWedgeA',
  'keyboardA',
  'pizzaBoxC',
  'acornA3000',
] as const satisfies readonly ModelKey[];

const DRESSING_MODELS = {
  shelfBayA: { url: `${PARAM}/shelfwall-bay-a.glb`, targetH: 2.1025 },
  shelfBayB: { url: `${PARAM}/shelfwall-bay-b.glb`, targetH: 2.1425 },
  boxStackA: { url: `${PARAM}/shelfwall-boxstack-a.glb`, targetH: 0.454 },
  boxStackB: { url: `${PARAM}/shelfwall-boxstack-b.glb`, targetH: 0.495 },
  boxStackC: { url: `${PARAM}/shelfwall-boxstack-c.glb`, targetH: 0.46 },
  shelfClutterA: { url: `${PARAM}/shelfwall-clutter-a.glb`, targetH: 0.36 },
  shelfClutterB: { url: `${PARAM}/shelfwall-clutter-b.glb`, targetH: 0.45 },
} as const satisfies Record<string, MachineModel>;

type DressingKey = keyof typeof DRESSING_MODELS;
type ArchiveModelKey = ModelKey | DressingKey;

interface Placement {
  key: ArchiveModelKey;
  position: Point3;
  rotation: Point3;
  scale: Point3;
}

interface MeshSource {
  geometry: BufferGeometry;
  material: Material | undefined;
  matrix: Matrix4;
}

function stableVariation(id: string, salt: number): number {
  let hash = 2166136261 ^ salt;
  for (let index = 0; index < id.length; index += 1) {
    hash = Math.imul(hash ^ id.charCodeAt(index), 16777619);
  }
  return (hash >>> 0) / 0xffffffff * 2 - 1;
}

function archiveModel(key: ArchiveModelKey): MachineModel {
  return key in DRESSING_MODELS
    ? DRESSING_MODELS[key as DressingKey]
    : MODELS[key as ModelKey];
}

function sourceMeshes(scene: Group, model: MachineModel): MeshSource[] {
  const prepared = prepareModelScene(scene, model);
  prepared.updateMatrixWorld(true);
  const sources: MeshSource[] = [];
  prepared.traverse((object) => {
    if (!(object instanceof Mesh)) return;
    sources.push({
      geometry: object.geometry,
      material: Array.isArray(object.material) ? object.material[0] : object.material,
      matrix: object.matrixWorld.clone(),
    });
  });
  if (sources.length === 0) throw new Error(`archive-wall GLB has no mesh: ${model.url}`);
  return sources;
}

function modelMatrices(source: MeshSource, placements: Placement[]) {
  return placements.map((placement) => new Matrix4().compose(
    new Vector3(...placement.position),
    new Quaternion().setFromEuler(new Euler(...placement.rotation)),
    new Vector3(...placement.scale),
  ).multiply(source.matrix));
}

function InstancedArchiveModel({
  model,
  placements,
}: {
  model: MachineModel;
  placements: Placement[];
}) {
  const { scene } = useGLTF(model.url);
  const sources = useMemo(() => sourceMeshes(scene, model), [scene, model]);
  return sources.map((source, index) => (
    <Instances
      key={`${model.url}:${index}`}
      matrices={modelMatrices(source, placements)}
      geometry={source.geometry}
      material={source.material}
    />
  ));
}

function buildPlacements(layout: HallLayout) {
  const { width, depth } = layout.dims;
  const pitch = 0.97;
  const bayCount = Math.max(6, Math.floor((width - 0.9) / pitch));
  const runWidth = (bayCount - 1) * pitch;
  const wallZ = -depth / 2;
  const shelfZ = wallZ + 0.25;
  const byModel = new Map<ArchiveModelKey, Placement[]>();
  const cavities: Matrix4[] = [];
  const placards: Matrix4[] = [];
  const shelfContacts: Matrix4[] = [];
  const softwareBoxes = [[], [], []] as Matrix4[][];
  const softwareLabels: Matrix4[] = [];
  const manualSpines = [[], [], []] as Matrix4[][];

  const add = (
    key: ArchiveModelKey,
    position: Point3,
    rotation: Point3 = [0, 0, 0],
    scale: Point3 = [1, 1, 1],
  ) => {
    const placements = byModel.get(key) ?? [];
    placements.push({ key, position, rotation, scale });
    byModel.set(key, placements);
  };

  for (let bay = 0; bay < bayCount; bay += 1) {
    const isA = bay % 2 === 0;
    const bayId = `archive-bay-${bay}`;
    const x = -runWidth / 2 + bay * pitch
      + stableVariation(bayId, 13) * 0.012;
    const bayYaw = stableVariation(bayId, 17) * Math.PI / 600;
    const levels = isA
      ? [0.103, 0.548, 1.008, 1.468]
      : [0.113, 0.508, 0.938, 1.408];
    const top = isA ? 2.108 : 2.148;
    add(
      isA ? 'shelfBayA' : 'shelfBayB',
      [x, 0, shelfZ],
      [0, bayYaw, 0],
    );

    for (let level = 0; level < levels.length; level += 1) {
      const cavityBottom = levels[level] + 0.025;
      const cavityTop = (levels[level + 1] ?? top) - 0.055;
      cavities.push(new Matrix4().compose(
        new Vector3(x, (cavityBottom + cavityTop) / 2, shelfZ + 0.025),
        new Quaternion(),
        new Vector3(0.82, cavityTop - cavityBottom, 1),
      ));
      shelfContacts.push(new Matrix4().compose(
        new Vector3(x, levels[level] + 0.009, shelfZ + 0.07),
        new Quaternion().setFromEuler(new Euler(-Math.PI / 2, 0, 0)),
        new Vector3(0.624, 0.336, 1),
      ));
      const rowId = `${bayId}-level-${level}`;
      const clutterRow = level === (bay + 1) % levels.length && bay % 3 === 0;
      const displayOnLeft = stableVariation(rowId, 73) < 0;
      const displayX = x + (displayOnLeft ? -0.19 : 0.19);
      const lowX = x + (displayOnLeft ? 0.19 : -0.19);
      const displayKey = ARCHIVE_DISPLAY_MODELS[
        (bay * 5 + level * 3) % ARCHIVE_DISPLAY_MODELS.length
      ];
      const lowKey = ARCHIVE_LOW_MODELS[
        (bay * 3 + level * 5) % ARCHIVE_LOW_MODELS.length
      ];
      const displayScale = 0.88 + stableVariation(rowId, 79) * 0.025;
      add(
        displayKey,
        [
          displayX + stableVariation(rowId, 83) * 0.012,
          levels[level],
          shelfZ + 0.052 + stableVariation(rowId, 89) * 0.015,
        ],
        [0, stableVariation(rowId, 97) * Math.PI / 42, 0],
        [displayScale, displayScale, displayScale],
      );

      if (clutterRow) {
        add(
          bay % 2 === 0 ? 'shelfClutterA' : 'shelfClutterB',
          [
            lowX + stableVariation(rowId, 19) * 0.014,
            levels[level],
            shelfZ + 0.055 + stableVariation(rowId, 23) * 0.012,
          ],
          [0, stableVariation(rowId, 29) * Math.PI / 45, 0],
          [0.78, 0.78, 0.78],
        );
      } else {
        const lowScale = 0.84 + stableVariation(rowId, 101) * 0.025;
        add(
          lowKey,
          [
            lowX + stableVariation(rowId, 103) * 0.012,
            levels[level] + Math.max(0, stableVariation(rowId, 107)) * 0.006,
            shelfZ + 0.07 + stableVariation(rowId, 109) * 0.016,
          ],
          [0, stableVariation(rowId, 113) * Math.PI / 40, 0],
          [lowScale, lowScale, lowScale],
        );
      }

      const boxCount = 2 + Number((bay + level) % 3 === 0);
      for (let box = 0; box < boxCount; box += 1) {
        const boxId = `${rowId}-software-${box}`;
        const boxWidth = 0.105 + (stableVariation(boxId, 127) + 1) * 0.02;
        const boxHeight = Math.min(
          cavityTop - cavityBottom - 0.035,
          0.19 + (stableVariation(boxId, 131) + 1) * 0.045,
        );
        const boxX = x
          + (displayOnLeft ? 1 : -1) * (0.35 - box * (boxWidth + 0.008));
        const boxZ = shelfZ + 0.055 + stableVariation(boxId, 137) * 0.012;
        softwareBoxes[(bay + level + box) % softwareBoxes.length].push(
          new Matrix4().compose(
            new Vector3(boxX, levels[level] + boxHeight / 2, boxZ),
            new Quaternion().setFromEuler(new Euler(
              0,
              stableVariation(boxId, 139) * Math.PI / 48,
              stableVariation(boxId, 149) * Math.PI / 90,
            )),
            new Vector3(boxWidth, boxHeight, 0.24),
          ),
        );
        softwareLabels.push(new Matrix4().compose(
          new Vector3(boxX, levels[level] + boxHeight * 0.55, wallZ + 0.487),
          new Quaternion().setFromEuler(new Euler(0, 0, stableVariation(boxId, 151) * 0.03)),
          new Vector3(boxWidth * 0.58, boxHeight * 0.22, 1),
        ));
      }

      if ((bay + level) % 3 === 1) {
        const manualSide = displayOnLeft ? 1 : -1;
        for (let manual = 0; manual < 3; manual += 1) {
          const manualId = `${rowId}-manual-${manual}`;
          const manualHeight = 0.17 + (manual % 2) * 0.035;
          manualSpines[(bay + manual) % manualSpines.length].push(
            new Matrix4().compose(
              new Vector3(
                x + manualSide * (0.30 - manual * 0.038),
                levels[level] + manualHeight / 2,
                wallZ + 0.435 + stableVariation(manualId, 157) * 0.008,
              ),
              new Quaternion().setFromEuler(new Euler(
                0,
                0,
                stableVariation(manualId, 163) * Math.PI / 40,
              )),
              new Vector3(0.032, manualHeight, 0.19),
            ),
          );
        }
      }

      if ((bay + level) % 2 === 0) {
        const placardX = x + ((bay + level) % 4 < 2 ? 0.29 : -0.29);
        placards.push(new Matrix4().compose(
          new Vector3(placardX, levels[level] + 0.085, wallZ + 0.478),
          new Quaternion().setFromEuler(new Euler(
            -0.18,
            stableVariation(rowId, 53) * Math.PI / 45,
            0,
          )),
          new Vector3(0.105, 0.148, 1),
        ));
      }
    }

    const boxKey = (['boxStackA', 'boxStackB', 'boxStackC'] as const)[bay % 3];
    const boxScale = 0.88 + (stableVariation(bayId, 59) + 1) * 0.065;
    add(
      boxKey,
      [
        x + stableVariation(bayId, 61) * 0.035,
        top,
        shelfZ + 0.025 + stableVariation(bayId, 67) * 0.018,
      ],
      [0, stableVariation(bayId, 71) * Math.PI / 36, 0],
      [boxScale, boxScale, boxScale],
    );
  }

  return {
    byModel,
    cavities,
    manualSpines,
    placards,
    shelfContacts,
    softwareBoxes,
    softwareLabels,
  };
}

function createCavityAoTexture() {
  const canvas = document.createElement('canvas');
  canvas.width = 64;
  canvas.height = 64;
  const context = canvas.getContext('2d');
  if (!context) throw new Error('2D canvas is required for archive cavity AO');
  const gradient = context.createLinearGradient(0, 0, 0, canvas.height);
  gradient.addColorStop(0, 'rgba(255, 255, 255, 0.72)');
  gradient.addColorStop(0.22, 'rgba(255, 255, 255, 0.18)');
  gradient.addColorStop(0.72, 'rgba(255, 255, 255, 0.08)');
  gradient.addColorStop(1, 'rgba(255, 255, 255, 0.48)');
  context.fillStyle = gradient;
  context.fillRect(0, 0, canvas.width, canvas.height);
  const texture = new CanvasTexture(canvas);
  texture.minFilter = LinearFilter;
  texture.magFilter = LinearFilter;
  return texture;
}

function createShelfContactTexture() {
  const canvas = document.createElement('canvas');
  canvas.width = 64;
  canvas.height = 64;
  const context = canvas.getContext('2d');
  if (!context) throw new Error('2D canvas is required for archive shelf contacts');
  const gradient = context.createRadialGradient(32, 32, 5, 32, 32, 32);
  gradient.addColorStop(0, 'rgba(255, 255, 255, 0.9)');
  gradient.addColorStop(0.58, 'rgba(255, 255, 255, 0.42)');
  gradient.addColorStop(1, 'rgba(255, 255, 255, 0)');
  context.fillStyle = gradient;
  context.fillRect(0, 0, canvas.width, canvas.height);
  const texture = new CanvasTexture(canvas);
  texture.minFilter = LinearFilter;
  texture.magFilter = LinearFilter;
  return texture;
}

export default function ArchiveWall({ layout }: { layout: HallLayout }) {
  const {
    byModel,
    cavities,
    manualSpines,
    placards,
    shelfContacts,
    softwareBoxes,
    softwareLabels,
  } = useMemo(() => buildPlacements(layout), [layout]);
  const cavityAo = useMemo(createCavityAoTexture, []);
  const shelfContact = useMemo(createShelfContactTexture, []);
  useEffect(() => () => {
    cavityAo.dispose();
    shelfContact.dispose();
  }, [cavityAo, shelfContact]);
  return (
    <Suspense fallback={null}>
      <Instances matrices={cavities}>
        <planeGeometry />
        <meshBasicMaterial
          color="#392f29"
          depthWrite={false}
          map={cavityAo}
          opacity={0.24}
          polygonOffset
          polygonOffsetFactor={-1}
          transparent
        />
      </Instances>
      <Instances matrices={shelfContacts}>
        <planeGeometry />
        <meshBasicMaterial
          color="#2b2926"
          depthWrite={false}
          map={shelfContact}
          opacity={0.33}
          polygonOffset
          polygonOffsetFactor={-1}
          transparent
        />
      </Instances>
      {softwareBoxes.map((matrices, index) => (
        <Instances key={`archive-software-box:${index}`} matrices={matrices}>
          <boxGeometry />
          <meshStandardMaterial
            color={['#8f5b45', '#627887', '#a07b43'][index]}
            roughness={0.86}
          />
        </Instances>
      ))}
      <Instances matrices={softwareLabels}>
        <planeGeometry />
        <meshStandardMaterial color="#d8cfb7" roughness={0.9} />
      </Instances>
      {manualSpines.map((matrices, index) => (
        <Instances key={`archive-manual:${index}`} matrices={matrices}>
          <boxGeometry />
          <meshStandardMaterial
            color={['#77594b', '#d0c4a9', '#536d72'][index]}
            roughness={0.88}
          />
        </Instances>
      ))}
      {[...byModel].map(([key, placements]) => (
        <InstancedArchiveModel
          key={key}
          model={archiveModel(key)}
          placements={placements}
        />
      ))}
      <Instances matrices={placards}>
        <planeGeometry />
        <meshStandardMaterial color="#e8e2d4" roughness={0.82} />
      </Instances>
    </Suspense>
  );
}
