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
import type { HallLayout, HallProp } from './hallLayout';
import { Instances } from './InstancedHallGeometry';
import { MODELS, type MachineModel } from './machines';
import { prepareModelScene } from './modelNormalization';
import { VARIED_FURNITURE_MODELS } from './furnitureVariants';

function normalizedSource(scene: Group, model: MachineModel) {
  const prepared = prepareModelScene(scene, model);
  prepared.updateMatrixWorld(true);
  let source: Mesh | undefined;
  prepared.traverse((object) => {
    if (!source && object instanceof Mesh) source = object;
  });
  if (!source) throw new Error(`furniture GLB has no mesh: ${model.url}`);
  return {
    geometry: source.geometry,
    material: source.material as Material,
    matrix: source.matrixWorld.clone(),
  };
}

function InstancedFurniture({ model, props }: { model: MachineModel; props: HallProp[] }) {
  const { scene } = useGLTF(model.url);
  const source = useMemo(() => normalizedSource(scene, model), [scene, model]);
  const matrices = useMemo(() => props.map((prop) => {
    const placement = new Matrix4().compose(
      new Vector3(...prop.pos),
      new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), prop.rotY),
      new Vector3(...(prop.scale ?? [1, 1, 1])),
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

export default function FurnitureVariants({ layout }: { layout: HallLayout }) {
  return (
    <Suspense fallback={null}>
      {VARIED_FURNITURE_MODELS.map((key) => {
        const props = layout.props.filter((prop) => prop.model === key);
        return props.length > 0 && (
          <InstancedFurniture
            key={`${key}:${props.length}`}
            model={MODELS[key]}
            props={props}
          />
        );
      })}
    </Suspense>
  );
}
