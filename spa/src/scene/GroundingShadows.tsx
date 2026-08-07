import { useEffect, useMemo } from 'react';
import {
  CanvasTexture,
  Euler,
  LinearFilter,
  Matrix4,
  Quaternion,
  Vector3,
} from 'three';
import type { HallDesk, HallLayout, Point3 } from './hallLayout';
import { DESK_MODULE } from './hallSpec';
import { Instances } from './InstancedHallGeometry';
import { assemblyForTile } from './machines';

const SHADOW_SIZE = 64;
const FLOOR_Y = 0.006;

function stableVariation(id: string, salt: number) {
  let hash = 2166136261 ^ salt;
  for (let index = 0; index < id.length; index += 1) {
    hash = Math.imul(hash ^ id.charCodeAt(index), 16777619);
  }
  return (hash >>> 0) / 0xffffffff * 2 - 1;
}

function createShadowTexture(shape: 'blob' | 'rect') {
  const canvas = document.createElement('canvas');
  canvas.width = SHADOW_SIZE;
  canvas.height = SHADOW_SIZE;
  const context = canvas.getContext('2d');
  if (!context) throw new Error('2D canvas is required for exhibit shadows');
  if (shape === 'blob') {
    const gradient = context.createRadialGradient(
      SHADOW_SIZE / 2,
      SHADOW_SIZE / 2,
      SHADOW_SIZE * 0.08,
      SHADOW_SIZE / 2,
      SHADOW_SIZE / 2,
      SHADOW_SIZE / 2,
    );
    gradient.addColorStop(0, 'rgba(255, 255, 255, 0.96)');
    gradient.addColorStop(0.55, 'rgba(255, 255, 255, 0.58)');
    gradient.addColorStop(1, 'rgba(255, 255, 255, 0)');
    context.fillStyle = gradient;
    context.fillRect(0, 0, SHADOW_SIZE, SHADOW_SIZE);
  } else {
    const image = context.createImageData(SHADOW_SIZE, SHADOW_SIZE);
    for (let y = 0; y < SHADOW_SIZE; y += 1) {
      for (let x = 0; x < SHADOW_SIZE; x += 1) {
        const u = Math.abs(x / (SHADOW_SIZE - 1) * 2 - 1);
        const v = Math.abs(y / (SHADOW_SIZE - 1) * 2 - 1);
        const edge = Math.max(u, v);
        const alpha = Math.max(0, Math.min(1, (1 - edge) / 0.28));
        const index = (y * SHADOW_SIZE + x) * 4;
        image.data[index] = 255;
        image.data[index + 1] = 255;
        image.data[index + 2] = 255;
        image.data[index + 3] = Math.round(alpha * 255);
      }
    }
    context.putImageData(image, 0, 0);
  }
  const texture = new CanvasTexture(canvas);
  texture.minFilter = LinearFilter;
  texture.magFilter = LinearFilter;
  return texture;
}

function floorShadow(
  position: Point3,
  rotationY: number,
  size: readonly [number, number],
) {
  const rotation = new Quaternion()
    .setFromAxisAngle(new Vector3(0, 1, 0), rotationY)
    .multiply(new Quaternion().setFromEuler(new Euler(-Math.PI / 2, 0, 0)));
  return new Matrix4().compose(
    new Vector3(...position),
    rotation,
    new Vector3(size[0], size[1], 1),
  );
}

function localFloorPoint(
  origin: Point3,
  rotationY: number,
  x: number,
  z: number,
  y = FLOOR_Y,
): Point3 {
  const sin = Math.sin(rotationY);
  const cos = Math.cos(rotationY);
  return [
    origin[0] + x * cos + z * sin,
    y,
    origin[2] - x * sin + z * cos,
  ];
}

function ShadowInstances({
  matrices,
  opacity,
  texture,
}: {
  matrices: Matrix4[];
  opacity: number;
  texture: CanvasTexture;
}) {
  return (
    <Instances matrices={matrices}>
      <planeGeometry />
      <meshBasicMaterial
        color="#182028"
        depthWrite={false}
        map={texture}
        opacity={opacity}
        polygonOffset
        polygonOffsetFactor={-1}
        transparent
      />
    </Instances>
  );
}

export default function GroundingShadows({ layout }: { layout: HallLayout }) {
  const blobTexture = useMemo(() => createShadowTexture('blob'), []);
  const rectTexture = useMemo(() => createShadowTexture('rect'), []);
  useEffect(() => () => {
    blobTexture.dispose();
    rectTexture.dispose();
  }, [blobTexture, rectTexture]);

  const shadows = useMemo(() => {
    const deskFootprints: Matrix4[] = [];
    const deskLegs: Matrix4[] = [];
    const machines: Matrix4[] = [];
    const machineContacts: Matrix4[] = [];
    const keyboardContacts: Matrix4[] = [];
    const towerFeet: Matrix4[] = [];
    const chairs: Matrix4[] = [];
    const chairCasters: Matrix4[] = [];
    const shelfBays: Matrix4[] = [];
    const dressingBlobs: Matrix4[] = [];
    const dressingRects: Matrix4[] = [];
    const legX = DESK_MODULE.width / 2 - 0.06;
    const legZ = DESK_MODULE.depth / 2 - 0.06;

    for (const desk of layout.desks) {
      deskFootprints.push(floorShadow(
        [desk.pos[0], FLOOR_Y, desk.pos[2]],
        desk.rotY,
        [DESK_MODULE.width * 0.9, DESK_MODULE.depth * 0.82],
      ));
      for (const [x, z] of [
        [-legX, -legZ],
        [legX, -legZ],
        [-legX, legZ],
        [legX, legZ],
      ]) {
        deskLegs.push(floorShadow(
          localFloorPoint(desk.pos, desk.rotY, x, z, FLOOR_Y + 0.001),
          desk.rotY,
          [0.224, 0.192],
        ));
      }
      machines.push(floorShadow(
        localFloorPoint(
          desk.pos,
          desk.rotY,
          desk.variation.machine.offset[0],
          -0.04 + desk.variation.machine.offset[2],
          DESK_MODULE.height + 0.003,
        ),
        desk.rotY + desk.variation.machine.yaw,
        [0.92, 0.7],
      ));
      machineContacts.push(floorShadow(
        localFloorPoint(
          desk.pos,
          desk.rotY,
          desk.variation.machine.offset[0],
          -0.04 + desk.variation.machine.offset[2],
          DESK_MODULE.height + 0.004,
        ),
        desk.rotY + desk.variation.machine.yaw,
        [0.48, 0.368],
      ));
      const assembly = assemblyForTile(desk.entry.assemblyId ?? desk.entry.id);
      if (assembly.keyboard) {
        const keyboardX = assembly.kind === 'industrial' || assembly.kind === 'towerSetup'
          ? -0.1
          : 0;
        keyboardContacts.push(floorShadow(
          localFloorPoint(
            desk.pos,
            desk.rotY,
            keyboardX + desk.variation.keyboard.offset[0],
            0.23 + desk.variation.keyboard.offset[2],
            DESK_MODULE.height + 0.005,
          ),
          desk.rotY + desk.variation.keyboard.yaw,
          [0.52, 0.22],
        ));
      }
      if (assembly.kind === 'towerSetup') {
        const machineCos = Math.cos(desk.variation.machine.yaw);
        const machineSin = Math.sin(desk.variation.machine.yaw);
        towerFeet.push(floorShadow(
          localFloorPoint(
            desk.pos,
            desk.rotY,
            desk.variation.machine.offset[0]
              + 0.62 * machineCos
              - 0.03 * machineSin,
            desk.variation.machine.offset[2]
              - 0.62 * machineSin
              - 0.03 * machineCos,
            FLOOR_Y + 0.002,
          ),
          desk.rotY + desk.variation.machine.yaw,
          [0.26, 0.32],
        ));
      }
    }

    for (const prop of layout.props) {
      const chairModel = prop.model === 'officeChairA'
        || prop.model === 'officeChairB'
        || prop.model === 'chairTubularRed'
        || prop.model === 'chairPlywoodOrange'
        || prop.model === 'chairTaskBlue';
      if (!chairModel) continue;
      chairs.push(floorShadow(
        [prop.pos[0], FLOOR_Y + 0.0015, prop.pos[2]],
        prop.rotY,
        prop.model === 'chairTubularRed' || prop.model === 'chairPlywoodOrange'
          ? [0.54, 0.58]
          : [0.72, 0.72],
      ));
      if (prop.model === 'chairTubularRed' || prop.model === 'chairPlywoodOrange') continue;
      for (let caster = 0; caster < 5; caster += 1) {
        const angle = caster / 5 * Math.PI * 2 + Math.PI / 2;
        chairCasters.push(floorShadow(
          localFloorPoint(
            prop.pos,
            prop.rotY,
            Math.cos(angle) * 0.29,
            Math.sin(angle) * 0.29,
            FLOOR_Y + 0.002,
          ),
          prop.rotY + angle,
          [0.136, 0.104],
        ));
      }
    }

    const pitch = 0.97;
    const bayCount = Math.max(6, Math.floor((layout.dims.width - 0.9) / pitch));
    const runWidth = (bayCount - 1) * pitch;
    const shelfZ = -layout.dims.depth / 2 + 0.25;
    for (let bay = 0; bay < bayCount; bay += 1) {
      shelfBays.push(floorShadow(
        [-runWidth / 2 + bay * pitch, FLOOR_Y + 0.001, shelfZ],
        0,
        [0.696, 0.368],
      ));
    }

    const firstDesk = layout.desks[0];
    const firstSection = layout.sections[0];
    const pineDesk = layout.desks
      .filter((desk) => desk.sectionKey === firstSection?.key)
      .sort((a, b) => b.pos[0] - a.pos[0])[0] ?? firstDesk;
    const preferred = layout.desks.filter(
      (desk) => desk.sectionKey === firstSection?.key,
    );
    const overflow = layout.desks.filter(
      (desk) => desk.sectionKey !== firstSection?.key,
    );
    const lampCount = Math.max(1, Math.round(layout.desks.length * 0.2));
    const lampDesks: HallDesk[] = [];
    for (const desk of [
      firstDesk,
      pineDesk,
      ...[...preferred, ...overflow].sort(
        (a, b) => stableVariation(b.id, 311) - stableVariation(a.id, 311),
      ),
    ]) {
      if (!desk || lampDesks.some((candidate) => candidate.id === desk.id)) continue;
      lampDesks.push(desk);
      if (lampDesks.length === lampCount) break;
    }
    for (const desk of lampDesks) {
      dressingBlobs.push(floorShadow(
        localFloorPoint(
          desk.pos,
          desk.rotY,
          -0.61,
          -0.23 + stableVariation(desk.id, 313) * 0.025,
          DESK_MODULE.height + 0.006,
        ),
        desk.rotY,
        [0.28, 0.24],
      ));
    }

    const clutterKeys = new Set(
      [layout.sections[0], layout.sections[1]]
        .filter(Boolean)
        .map((section) => section.key),
    );
    const clutterPreferred = layout.desks.filter(
      (desk) => clutterKeys.has(desk.sectionKey),
    );
    const clutterOverflow = layout.desks.filter(
      (desk) => !clutterKeys.has(desk.sectionKey),
    );
    const clutterCount = Math.max(1, Math.round(layout.desks.length * 0.3));
    const clutterDesks: HallDesk[] = [];
    for (const desk of [
      firstDesk,
      ...[...clutterPreferred, ...clutterOverflow].sort(
        (a, b) => stableVariation(b.id, 401) - stableVariation(a.id, 401),
      ),
    ]) {
      if (!desk || clutterDesks.some((candidate) => candidate.id === desk.id)) continue;
      clutterDesks.push(desk);
      if (clutterDesks.length === clutterCount) break;
    }
    clutterDesks.forEach((desk, index) => {
      const x = index % 3 === 2 ? 0.48 : 0.55;
      const z = index % 3 === 2 ? -0.12 : -0.23;
      dressingBlobs.push(floorShadow(
        localFloorPoint(
          desk.pos,
          desk.rotY,
          x,
          z,
          DESK_MODULE.height + 0.006,
        ),
        desk.rotY,
        index % 3 === 0 ? [0.28, 0.24] : [0.32, 0.22],
      ));
    });
    const plantDesks = pineDesk?.id === firstDesk?.id ? [firstDesk] : [firstDesk, pineDesk];
    for (const desk of plantDesks) {
      if (!desk) continue;
      dressingBlobs.push(floorShadow(
        localFloorPoint(
          desk.pos,
          desk.rotY,
          -0.24,
          -0.30,
          DESK_MODULE.height + 0.006,
        ),
        desk.rotY,
        [0.23, 0.20],
      ));
    }
    dressingBlobs.push(floorShadow(
      [-layout.dims.width / 2 + 0.42, FLOOR_Y + 0.002, layout.dims.depth / 2 - 1.15],
      0.35,
      [0.48, 0.42],
    ));

    const caseSections = [
      layout.sections[0],
      layout.sections[Math.min(2, layout.sections.length - 1)],
    ].filter((section, index, sections) =>
      Boolean(section) && sections.findIndex((item) => item?.key === section?.key) === index);
    caseSections.forEach((section, index) => {
      dressingRects.push(floorShadow(
        [index === 0 ? -1.85 : 2.0, FLOOR_Y + 0.002, section.zMin + 1.0],
        (index === 0 ? -1 : 1) * Math.PI / 90,
        [1.42, 0.68],
      ));
    });
    for (const x of [-2.25, 2.20]) {
      dressingRects.push(floorShadow(
        [x, FLOOR_Y + 0.002, layout.dims.depth / 2 - 0.30],
        0,
        [1.0, 0.58],
      ));
    }
    dressingBlobs.push(floorShadow(
      [0.18, FLOOR_Y + 0.002, layout.dims.depth / 2 - 0.27],
      0,
      [0.68, 0.46],
    ));

    return {
      chairCasters,
      chairs,
      deskFootprints,
      deskLegs,
      dressingBlobs,
      dressingRects,
      keyboardContacts,
      machineContacts,
      machines,
      shelfBays,
      towerFeet,
    };
  }, [layout]);

  return (
    <>
      <ShadowInstances matrices={shadows.deskFootprints} opacity={0.225} texture={rectTexture} />
      <ShadowInstances matrices={shadows.deskLegs} opacity={0.485} texture={blobTexture} />
      <ShadowInstances matrices={shadows.chairs} opacity={0.215} texture={blobTexture} />
      <ShadowInstances matrices={shadows.chairCasters} opacity={0.485} texture={blobTexture} />
      <ShadowInstances matrices={shadows.shelfBays} opacity={0.41} texture={rectTexture} />
      <ShadowInstances matrices={shadows.machines} opacity={0.215} texture={rectTexture} />
      <ShadowInstances matrices={shadows.machineContacts} opacity={0.485} texture={rectTexture} />
      <ShadowInstances matrices={shadows.keyboardContacts} opacity={0.42} texture={rectTexture} />
      <ShadowInstances matrices={shadows.towerFeet} opacity={0.485} texture={blobTexture} />
      <ShadowInstances matrices={shadows.dressingBlobs} opacity={0.34} texture={blobTexture} />
      <ShadowInstances matrices={shadows.dressingRects} opacity={0.3} texture={rectTexture} />
    </>
  );
}
