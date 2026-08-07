import { Suspense, useMemo } from 'react';
import { useGLTF } from '@react-three/drei';
import {
  Matrix4,
  Mesh,
  Quaternion,
  Vector3,
  type Group,
  type Material,
} from 'three';
import type { HallLayout, HallProp, SetDressingModel } from './hallLayout';
import { Instances } from './InstancedHallGeometry';
import {
  assemblyForTile,
  hasIntegratedKeyboard,
  MODELS,
  type MachineModel,
} from './machines';
import { prepareModelScene } from './modelNormalization';

const MODEL_KEYS = [
  'officeChairA',
  'officeChairB',
  'cableRun',
  'shelfUnit',
  'deskClutter',
] as const satisfies readonly SetDressingModel[];

function normalizedSource(scene: Group, model: MachineModel) {
  const prepared = prepareModelScene(scene, model);
  prepared.updateMatrixWorld(true);
  let source: Mesh | undefined;
  prepared.traverse((object) => {
    if (!source && object instanceof Mesh) source = object;
  });
  if (!source) throw new Error(`set-dressing GLB has no mesh: ${model.url}`);
  return {
    geometry: source.geometry,
    material: source.material as Material,
    matrix: source.matrixWorld.clone(),
  };
}

function InstancedProp({ model, props }: { model: MachineModel; props: HallProp[] }) {
  const { scene } = useGLTF(model.url);
  const source = useMemo(() => normalizedSource(scene, model), [scene, model]);
  const matrices = useMemo(() => props.map((prop) => {
    const placement = new Matrix4().compose(
      new Vector3(...prop.pos),
      new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), prop.rotY),
      new Vector3(1, 1, 1),
    );
    return placement.multiply(source.matrix);
  }), [props, source]);

  return (
    <Instances
      matrices={matrices}
      geometry={source.geometry}
      material={source.material}
    />
  );
}

export default function SetDressing({ layout }: { layout: HallLayout }) {
  return (
    <Suspense fallback={null}>
      {MODEL_KEYS.map((key) => {
        const props = layout.props.filter((prop) => {
          if (prop.model !== key) return false;
          if (key !== 'cableRun') return true;
          const desk = layout.desks.find((candidate) => candidate.id === prop.deskId);
          return !desk || !hasIntegratedKeyboard(assemblyForTile(
            desk.entry.assemblyId ?? desk.entry.id,
          ));
        });
        return props.length > 0 && (
          <InstancedProp
            key={`${key}:${props.length}`}
            model={MODELS[key]}
            props={props}
          />
        );
      })}
    </Suspense>
  );
}
