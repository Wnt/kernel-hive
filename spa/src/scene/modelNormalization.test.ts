import {
  BoxGeometry,
  Group,
  Mesh,
  MeshStandardMaterial,
} from 'three';
import { describe, expect, it } from 'vitest';
import { prepareModelScene, type MachineAging } from './modelNormalization';

const MODEL = {
  url: '/test.glb',
  targetH: 1,
};

function sourceScene() {
  const scene = new Group();
  const material = new MeshStandardMaterial({
    color: '#d6cbb2',
    roughness: 0.58,
  });
  scene.add(new Mesh(new BoxGeometry(1, 1, 1), material));
  return { material, scene };
}

function preparedMaterial(scene: Group) {
  let material: MeshStandardMaterial | undefined;
  scene.traverse((object) => {
    if (object instanceof Mesh && object.material instanceof MeshStandardMaterial) {
      material = object.material;
    }
  });
  return material!;
}

describe('machine material aging', () => {
  it('clones materials once per prepared instance and leaves the GLTF cache untouched', () => {
    const { material, scene } = sourceScene();
    const aging: MachineAging = {
      yellowing: 0.05,
      valueOffset: -0.04,
      roughnessOffset: 0.07,
    };
    const prepared = prepareModelScene(scene, MODEL, aging);
    const aged = preparedMaterial(prepared);

    expect(aged).not.toBe(material);
    expect(material.roughness).toBe(0.58);
    expect(aged.roughness).toBeCloseTo(0.65);
    expect(aged.color.getHex()).not.toBe(material.color.getHex());
  });

  it('produces stable but distinct material groups for different aging values', () => {
    const { scene } = sourceScene();
    const clean = preparedMaterial(prepareModelScene(scene, MODEL, {
      yellowing: 0.005,
      valueOffset: 0.04,
      roughnessOffset: -0.05,
    }));
    const aged = preparedMaterial(prepareModelScene(scene, MODEL, {
      yellowing: 0.055,
      valueOffset: -0.04,
      roughnessOffset: 0.07,
    }));

    expect(clean).not.toBe(aged);
    expect(clean.color.getHex()).not.toBe(aged.color.getHex());
    expect(clean.roughness).not.toBe(aged.roughness);
  });
});
