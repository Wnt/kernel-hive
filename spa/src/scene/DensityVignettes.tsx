import { useMemo } from 'react';
import { Euler, Matrix4, Quaternion, Vector3 } from 'three';
import type { HallDesk, HallLayout, Point3 } from './hallLayout';
import { DESK_MODULE, PALETTE } from './hallSpec';
import { Instances } from './InstancedHallGeometry';
import { buildStationKitBindings } from './stationKitBindings';

function variation(id: string, salt: number) {
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

function matrix(
  position: Point3,
  rotation: Point3 = [0, 0, 0],
  scale: Point3 = [1, 1, 1],
) {
  return new Matrix4().compose(
    new Vector3(...position),
    new Quaternion().setFromEuler(new Euler(...rotation)),
    new Vector3(...scale),
  );
}

function evidenceDesks(layout: HallLayout, required?: HallDesk) {
  const sectionKeys = new Set(layout.sections.slice(0, 3).map(({ key }) => key));
  const ranked = [...layout.desks].sort((a, b) => {
    const preferred = Number(sectionKeys.has(b.sectionKey)) - Number(sectionKeys.has(a.sectionKey));
    return preferred || variation(b.id, 907) - variation(a.id, 907);
  });
  const selected: HallDesk[] = [];
  for (const desk of required ? [required, ...ranked] : ranked) {
    if (selected.some(({ id }) => id === desk.id)) continue;
    selected.push(desk);
    if (selected.length === Math.max(5, Math.round(layout.desks.length * 0.18))) break;
  }
  return selected;
}

export default function DensityVignettes({ layout }: { layout: HallLayout }) {
  const geometry = useMemo(() => {
    const { width, depth } = layout.dims;
    const corner: Point3 = [-width / 2 + 3, 0, depth / 2 - 3.25];
    const tableWood = [
      matrix([corner[0], 0.675, corner[2]], [0, -0.025, 0], [1.08, 0.055, 0.56]),
      matrix([corner[0], 0.31, corner[2]], [0, -0.025, 0], [0.9, 0.035, 0.41]),
    ];
    const tableSteel = [
      [-0.46, -0.21], [0.46, -0.21], [-0.46, 0.21], [0.46, 0.21],
    ].map(([x, z]) => matrix(
      [corner[0] + x, 0.33, corner[2] + z],
      [0, -0.025, 0],
      [0.045, 0.65, 0.045],
    ));

    const firstSection = layout.sections[0];
    const pineDesk = layout.desks
      .filter((desk) => desk.sectionKey === firstSection?.key)
      .sort((a, b) => b.pos[0] - a.pos[0])[0] ?? layout.desks[0];
    const wallX = width / 2;
    const shelfZ = (pineDesk?.pos[2] ?? firstSection?.centerZ ?? 0) - 0.42;
    const shelfLevels = [1.24, 1.59, 1.94];
    const pineShelves = shelfLevels.flatMap((level, index) => [
      matrix(
        [wallX - 0.19, level, shelfZ + index * 0.04],
        [0, 0, variation(`pine-shelf:${index}`, 811) * 0.012],
        [0.36, 0.045, 1.92],
      ),
      matrix([wallX - 0.035, level - 0.17, shelfZ - 0.73], [0, 0, -0.1], [0.055, 0.34, 0.045]),
      matrix([wallX - 0.035, level - 0.17, shelfZ + 0.73], [0, 0, 0.08], [0.055, 0.34, 0.045]),
    ]);
    const shelfBoxes = [[], [], []] as Matrix4[][];
    const shelfLabels: Matrix4[] = [];
    const shelfOffsets = [
      [-0.74, -0.49, -0.24, 0.02, 0.30, 0.58, 0.76],
      [-0.75, -0.52, -0.29, -0.03, 0.24, 0.49, 0.73],
      [-0.72, -0.45, -0.18, 0.08, 0.34, 0.57, 0.76],
    ];
    shelfLevels.forEach((level, levelIndex) => {
      shelfOffsets[levelIndex].forEach((offset, index) => {
        const id = `pine-box:${levelIndex}:${index}`;
        const boxHeight = 0.2 + (index % 3) * 0.035;
        const boxWidth = 0.16 + (index % 2) * 0.045;
        shelfBoxes[(index + levelIndex) % 3].push(matrix(
          [wallX - 0.225 + variation(id, 821) * 0.008, level + 0.024 + boxHeight / 2, shelfZ + offset],
          [0, variation(id, 823) * Math.PI / 90, variation(id, 827) * Math.PI / 55],
          [0.17, boxHeight, boxWidth],
        ));
      });
      shelfLabels.push(matrix(
        [wallX - 0.326, level + 0.15, shelfZ + [0.2, -0.28, 0.36][levelIndex]],
        [0, -Math.PI / 2, levelIndex === 0 ? -0.08 : 0.055],
        [0.19, 0.135, 1],
      ));
    });

    const cartX = wallX - 0.92;
    const cartZ = shelfZ - 1.35;
    const cartShelves = [
      matrix([cartX, 0.22, cartZ], [0, 0.04, 0], [0.68, 0.045, 0.88]),
      matrix([cartX, 0.62, cartZ], [0, 0.04, 0], [0.68, 0.045, 0.88]),
    ];
    const cartFrame = [
      [-0.29, -0.39], [0.29, -0.39], [-0.29, 0.39], [0.29, 0.39],
    ].map(([x, z]) => matrix(
      [cartX + x, 0.34, cartZ + z],
      [0, 0.04, 0],
      [0.032, 0.65, 0.032],
    ));
    cartFrame.push(
      matrix([cartX - 0.29, 0.84, cartZ], [0, 0.04, 0], [0.032, 0.43, 0.032]),
      matrix([cartX - 0.29, 0.84, cartZ - 0.39], [Math.PI / 2, 0.04, 0], [0.032, 0.78, 0.032]),
    );
    const cartWheels = [
      [-0.29, -0.39], [0.29, -0.39], [-0.29, 0.39], [0.29, 0.39],
    ].map(([x, z]) => matrix(
      [cartX + x, 0.06, cartZ + z],
      [Math.PI / 2, 0, 0],
      [0.07, 0.035, 0.07],
    ));
    const cartCargo = [
      matrix([cartX + 0.09, 0.715, cartZ - 0.12], [0, -0.04, 0.04], [0.28, 0.15, 0.34]),
      matrix([cartX - 0.13, 0.705, cartZ + 0.21], [0, 0.06, -0.025], [0.22, 0.13, 0.28]),
      matrix([cartX + 0.05, 0.315, cartZ + 0.05], [0, -0.035, 0], [0.42, 0.13, 0.52]),
    ];
    const cartCargoAccents = [
      matrix([cartX + 0.18, 0.76, cartZ + 0.08], [0, -0.08, 0.05], [0.18, 0.22, 0.25]),
      matrix([cartX - 0.17, 0.35, cartZ - 0.12], [0, 0.04, -0.04], [0.2, 0.17, 0.31]),
    ];

    const papers: Matrix4[] = [];
    const paperMarks: Matrix4[] = [];
    const manuals: Matrix4[] = [];
    evidenceDesks(layout, pineDesk).forEach((desk, index) => {
      const id = `desk-paper:${desk.id}`;
      const position = deskPoint(desk, [
        index % 2 === 0 ? -0.48 : 0.48,
        DESK_MODULE.height + 0.012 + (index % 3) * 0.002,
        0.12 + variation(id, 911) * 0.05,
      ]);
      const yaw = desk.rotY + variation(id, 919) * Math.PI / 18;
      papers.push(matrix(position, [0, yaw, 0], [0.27, 0.006, 0.2]));
      paperMarks.push(matrix(
        [position[0], position[1] + 0.004, position[2]],
        [-Math.PI / 2, 0, -yaw],
        [0.13, 0.055, 1],
      ));
      if (index % 2 === 0) {
        const center = deskPoint(desk, [0.48, DESK_MODULE.height + 0.017, -0.13]);
        manuals.push(
          matrix([center[0] - 0.085, center[1], center[2]], [0, desk.rotY - 0.07, -0.035], [0.17, 0.008, 0.24]),
          matrix([center[0] + 0.085, center[1], center[2]], [0, desk.rotY + 0.07, 0.035], [0.17, 0.008, 0.24]),
        );
      }
    });

    const coils = buildStationKitBindings(layout).cableCoils.map((binding) => (
      matrix(binding.position, binding.rotation, binding.scale)
    ));
    coils.push(
      matrix([corner[0] - 0.33, 0.715, corner[2] + 0.13], [-Math.PI / 2, -0.08, 0]),
      matrix([corner[0] - 0.3, 0.723, corner[2] + 0.11], [-Math.PI / 2, 0.04, 0], [0.72, 0.72, 0.72]),
    );
    papers.push(matrix(
      [corner[0] + 0.34, 0.712, corner[2] + 0.08],
      [0, -0.16, 0.025],
      [0.25, 0.008, 0.18],
    ));
    const cornerPlacards = [matrix(
      [corner[0] + 0.35, 0.86, corner[2] + 0.292],
      [0, 0, -0.075],
      [0.22, 0.16, 1],
    )];
    return {
      cartCargo,
      cartCargoAccents,
      cartFrame,
      cartShelves,
      cartWheels,
      coils,
      cornerPlacards,
      manuals,
      paperMarks,
      papers,
      pineShelves,
      shelfBoxes,
      shelfLabels,
      tableSteel,
      tableWood,
    };
  }, [layout]);

  return (
    <group>
      <Instances matrices={geometry.tableWood}>
        <boxGeometry />
        <meshStandardMaterial color="#77736b" roughness={0.82} />
      </Instances>
      <Instances matrices={geometry.tableSteel}>
        <boxGeometry />
        <meshStandardMaterial color="#555b5e" metalness={0.42} roughness={0.68} />
      </Instances>
      <Instances matrices={geometry.pineShelves}>
        <boxGeometry />
        <meshStandardMaterial color={PALETTE.pineDark} roughness={0.78} />
      </Instances>
      {geometry.shelfBoxes.map((matrices, index) => (
        <Instances key={`pine-shelf-box:${index}`} matrices={matrices}>
          <boxGeometry />
          <meshStandardMaterial color={['#9a6147', '#536d78', '#b28b4b'][index]} roughness={0.86} />
        </Instances>
      ))}
      <Instances matrices={geometry.shelfLabels}>
        <planeGeometry />
        <meshStandardMaterial color="#e4ddca" roughness={0.9} />
      </Instances>
      <Instances matrices={geometry.cartShelves}>
        <boxGeometry />
        <meshStandardMaterial color="#777b79" metalness={0.22} roughness={0.7} />
      </Instances>
      <Instances matrices={geometry.cartFrame}>
        <boxGeometry />
        <meshStandardMaterial color="#4d5354" metalness={0.62} roughness={0.58} />
      </Instances>
      <Instances matrices={geometry.cartWheels}>
        <cylinderGeometry args={[1, 1, 1, 12]} />
        <meshStandardMaterial color="#292d2e" roughness={0.8} />
      </Instances>
      <Instances matrices={geometry.cartCargo}>
        <boxGeometry />
        <meshStandardMaterial color="#9b8260" roughness={0.9} />
      </Instances>
      <Instances matrices={geometry.cartCargoAccents}>
        <boxGeometry />
        <meshStandardMaterial color="#637986" roughness={0.84} />
      </Instances>
      <Instances matrices={geometry.papers}>
        <boxGeometry />
        <meshStandardMaterial color="#d8d1c1" roughness={0.94} />
      </Instances>
      <Instances matrices={geometry.paperMarks}>
        <planeGeometry />
        <meshStandardMaterial color="#6f7774" roughness={0.9} />
      </Instances>
      <Instances matrices={geometry.manuals}>
        <boxGeometry />
        <meshStandardMaterial color="#c9b998" roughness={0.91} />
      </Instances>
      <Instances matrices={geometry.coils}>
        <torusGeometry args={[0.115, 0.009, 8, 32]} />
        <meshStandardMaterial color="#313638" roughness={0.76} />
      </Instances>
      <Instances matrices={geometry.cornerPlacards}>
        <planeGeometry />
        <meshStandardMaterial color="#ded6c2" roughness={0.9} />
      </Instances>
    </group>
  );
}

export function WhiteWallStorageCluster({ layout }: { layout: HallLayout }) {
  const wallZ = layout.dims.depth / 2 - 0.27;
  const boxes = [
    { color: '#aa8d63', position: [0.18, 0.16, wallZ] as Point3, size: [0.52, 0.42, 0.32] as Point3 },
    { color: '#b9a27d', position: [0.42, 0.47, wallZ + 0.02] as Point3, size: [0.38, 0.38, 0.28] as Point3 },
    { color: '#8e785c', position: [-0.17, 0.40, wallZ - 0.01] as Point3, size: [0.28, 0.34, 0.36] as Point3 },
  ];
  return (
    <group>
      {boxes.map((box, index) => (
        <group key={`white-wall-carton:${index}`}>
          <mesh position={box.position} rotation={[0, index * 0.035 - 0.02, 0]}>
            <boxGeometry args={box.size} />
            <meshStandardMaterial color={box.color} roughness={0.88} />
          </mesh>
          <mesh position={[
            box.position[0],
            box.position[1],
            box.position[2] - box.size[2] / 2 - 0.006,
          ]}
          >
            <planeGeometry args={[box.size[0] * 0.48, box.size[1] * 0.28]} />
            <meshStandardMaterial color="#ded5bd" roughness={0.9} />
          </mesh>
        </group>
      ))}
    </group>
  );
}
