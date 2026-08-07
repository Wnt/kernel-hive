import {
  Suspense,
  useLayoutEffect,
  useMemo,
  useRef,
  type ReactNode,
} from 'react';
import type { ThreeEvent } from '@react-three/fiber';
import {
  type BufferGeometry,
  Euler,
  InstancedMesh,
  type Material,
  Matrix4,
  Quaternion,
  Vector3,
} from 'three';
import type { HallDesk, HallLayout, Point3 } from './hallLayout';
import { DESK_MODULE, PALETTE } from './hallSpec';
import { requestRailApproach } from './railNavigation';
import {
  type RoomTextureSources,
  useRoomTextureSources,
  useTiledRoomTexture,
} from './roomMaterials';

const IDENTITY_ROTATION: Point3 = [0, 0, 0];

function matrix(
  position: Point3,
  rotation: Point3 = IDENTITY_ROTATION,
  scale: Point3 = [1, 1, 1],
) {
  return new Matrix4().compose(
    new Vector3(...position),
    new Quaternion().setFromEuler(new Euler(...rotation)),
    new Vector3(...scale),
  );
}

export function Instances({
  matrices,
  children,
  geometry,
  material,
  onClick,
  onPointerOver,
  onPointerOut,
}: {
  matrices: Matrix4[];
  children?: ReactNode;
  geometry?: BufferGeometry;
  material?: Material;
  onClick?: (event: ThreeEvent<MouseEvent>) => void;
  onPointerOver?: (event: ThreeEvent<PointerEvent>) => void;
  onPointerOut?: (event: ThreeEvent<PointerEvent>) => void;
}) {
  const ref = useRef<InstancedMesh>(null);
  useLayoutEffect(() => {
    const mesh = ref.current;
    if (!mesh) return;
    matrices.forEach((transform, index) => mesh.setMatrixAt(index, transform));
    mesh.instanceMatrix.needsUpdate = true;
  }, [matrices]);
  if (matrices.length === 0) return null;
  return (
    <instancedMesh
      ref={ref}
      args={[geometry, material, matrices.length]}
      frustumCulled={false}
      onClick={onClick}
      onPointerOver={onPointerOver}
      onPointerOut={onPointerOut}
    >
      {children}
    </instancedMesh>
  );
}

interface Props {
  layout: HallLayout;
  onOpenInfo?: (tileId: string) => void;
  onHoverInfo?: (slot: HallDesk, pointerType: string | null) => void;
}

interface InstanceEvents {
  onClick?: (event: ThreeEvent<MouseEvent>) => void;
  onPointerOver?: (event: ThreeEvent<PointerEvent>) => void;
  onPointerOut?: (event: ThreeEvent<PointerEvent>) => void;
}

function RoomSurfaceInstances({
  deskEdges,
  deskEdgeEvents,
  deskTopEvents,
  deskTops,
  sources,
}: {
  deskEdges: Matrix4[];
  deskEdgeEvents: InstanceEvents;
  deskTopEvents: InstanceEvents;
  deskTops: Matrix4[];
  sources?: RoomTextureSources;
}) {
  const deskMap = useTiledRoomTexture(
    sources?.deskAlbedo,
    [DESK_MODULE.width / 0.8, DESK_MODULE.depth / 0.8],
    true,
  );
  const deskRoughness = useTiledRoomTexture(
    sources?.deskRoughness,
    [DESK_MODULE.width / 0.8, DESK_MODULE.depth / 0.8],
  );
  return (
    <>
      <Instances matrices={deskTops} {...deskTopEvents}>
        <boxGeometry />
        <meshStandardMaterial
          color={PALETTE.deskTop}
          map={deskMap}
          roughness={sources ? 1 : 0.6}
          roughnessMap={deskRoughness}
        />
      </Instances>
      <Instances matrices={deskEdges} {...deskEdgeEvents}>
        <boxGeometry />
        <meshStandardMaterial
          color={sources ? '#b88d55' : PALETTE.deskTop}
          roughness={0.72}
        />
      </Instances>
    </>
  );
}

function TexturedRoomSurfaceInstances(
  props: Omit<Parameters<typeof RoomSurfaceInstances>[0], 'sources'>,
) {
  const sources = useRoomTextureSources();
  return <RoomSurfaceInstances {...props} sources={sources} />;
}

export default function InstancedHallGeometry({
  layout,
  onOpenInfo,
  onHoverInfo,
}: Props) {
  const transforms = useMemo(() => {
    const deskTops: Matrix4[] = [];
    const deskEdges: Matrix4[] = [];
    const deskLegs: Matrix4[] = [];
    const legX = DESK_MODULE.width / 2 - 0.06;
    const legZ = DESK_MODULE.depth / 2 - 0.06;

    for (const desk of layout.desks) {
      const parent = matrix(desk.pos, [0, desk.rotY, 0]);
      const standardDeskScale = desk.deskModel === 'schoolDesk' ? 1 : 0;
      deskTops.push(parent.clone().multiply(matrix(
        [0, DESK_MODULE.height - DESK_MODULE.top / 2, 0],
        IDENTITY_ROTATION,
        [
          DESK_MODULE.width * standardDeskScale,
          DESK_MODULE.top * standardDeskScale,
          DESK_MODULE.depth * standardDeskScale,
        ],
      )));
      for (const [position, scale] of [
        [
          [0, DESK_MODULE.height - DESK_MODULE.top / 2, -DESK_MODULE.depth / 2 - 0.003],
          [DESK_MODULE.width + 0.008, DESK_MODULE.top + 0.006, 0.008],
        ],
        [
          [0, DESK_MODULE.height - DESK_MODULE.top / 2, DESK_MODULE.depth / 2 + 0.003],
          [DESK_MODULE.width + 0.008, DESK_MODULE.top + 0.006, 0.008],
        ],
        [
          [-DESK_MODULE.width / 2 - 0.003, DESK_MODULE.height - DESK_MODULE.top / 2, 0],
          [0.008, DESK_MODULE.top + 0.006, DESK_MODULE.depth],
        ],
        [
          [DESK_MODULE.width / 2 + 0.003, DESK_MODULE.height - DESK_MODULE.top / 2, 0],
          [0.008, DESK_MODULE.top + 0.006, DESK_MODULE.depth],
        ],
      ] as Array<[Point3, Point3]>) {
        deskEdges.push(parent.clone().multiply(matrix(
          position,
          IDENTITY_ROTATION,
          scale.map((value) => value * standardDeskScale) as Point3,
        )));
      }
      for (const [x, z] of [
        [-legX, -legZ],
        [legX, -legZ],
        [-legX, legZ],
        [legX, legZ],
      ]) {
        deskLegs.push(parent.clone().multiply(matrix(
          [x, (DESK_MODULE.height - DESK_MODULE.top) / 2, z],
          IDENTITY_ROTATION,
          [
            0.04 * standardDeskScale,
            (DESK_MODULE.height - DESK_MODULE.top) * standardDeskScale,
            0.04 * standardDeskScale,
          ],
        )));
      }
    }

    return {
      deskTops,
      deskEdges,
      deskLegs,
    };
  }, [layout]);
  const deskEvents = (instancesPerDesk: number) => {
    const deskFor = (instanceId: number | undefined) => (
      instanceId === undefined
        ? undefined
        : layout.desks[Math.floor(instanceId / instancesPerDesk)]
    );
    return {
      onClick: onOpenInfo ? (event: ThreeEvent<MouseEvent>) => {
        const desk = deskFor(event.instanceId);
        if (!desk) return;
        event.stopPropagation();
        if (event.delta > 5) return;
        requestRailApproach([
          desk.pos[0],
          DESK_MODULE.height + 0.24,
          desk.pos[2],
        ]);
        onOpenInfo(desk.entry.id);
      } : undefined,
      onPointerOver: onHoverInfo ? (event: ThreeEvent<PointerEvent>) => {
        const desk = deskFor(event.instanceId);
        if (desk) onHoverInfo(desk, event.pointerType);
      } : undefined,
      onPointerOut: onHoverInfo ? (event: ThreeEvent<PointerEvent>) => {
        const desk = deskFor(event.instanceId);
        if (desk) onHoverInfo(desk, null);
      } : undefined,
    };
  };

  return (
    <group>
      <Suspense fallback={(
        <RoomSurfaceInstances
          deskEdges={transforms.deskEdges}
          deskEdgeEvents={deskEvents(4)}
          deskTopEvents={deskEvents(1)}
          deskTops={transforms.deskTops}
        />
      )}
      >
        <TexturedRoomSurfaceInstances
          deskEdges={transforms.deskEdges}
          deskEdgeEvents={deskEvents(4)}
          deskTopEvents={deskEvents(1)}
          deskTops={transforms.deskTops}
        />
      </Suspense>
      <Instances matrices={transforms.deskLegs} {...deskEvents(4)}>
        <boxGeometry />
        <meshStandardMaterial color={PALETTE.deskLeg} roughness={0.5} metalness={0.6} />
      </Instances>
    </group>
  );
}
