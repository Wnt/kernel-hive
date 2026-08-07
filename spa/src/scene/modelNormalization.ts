import {
  Box3,
  Color,
  MathUtils,
  Mesh,
  MeshStandardMaterial,
  Vector3,
  type Group,
  type Material,
} from 'three';
import type { ExhibitVariation } from './hallLayout';
import type { ExhibitIdentity } from './machineIdentity';
import type { MachineModel } from './machines';

export type MachineAging = ExhibitVariation['aging'];
export type MachineFinish = Pick<
  ExhibitIdentity,
  'accentTint' | 'caseTint' | 'tintMix'
>;

function finishedMaterial(
  material: Material,
  aging?: MachineAging,
  finish?: MachineFinish,
): Material {
  const clone = material.clone();
  if (!(clone instanceof MeshStandardMaterial)) return clone;
  const materialName = clone.name.toLowerCase();
  if (materialName.includes('glass') || materialName.includes('screen')) return clone;

  if (aging) {
    clone.roughness = MathUtils.clamp(
      clone.roughness + aging.roughnessOffset,
      0.08,
      1,
    );
    const hsl = { h: 0, s: 0, l: 0 };
    clone.color.getHSL(hsl);
    if (hsl.l >= 0.34 && hsl.s <= 0.32) {
      clone.color.setHSL(
        0.12,
        MathUtils.clamp(hsl.s + aging.yellowing, 0, 0.34),
        hsl.l,
      );
      clone.color.multiplyScalar(1 + aging.valueOffset);
    }
  }

  const isDetail = /chip|dark|decal|glass|key|led|recess|screen/.test(materialName);
  if (finish && !isDetail) {
    const isTrim = /accent|base|face|fascia|front|grey|panel|plinth|trim/.test(
      materialName,
    );
    clone.color.lerp(
      new Color(isTrim ? finish.accentTint : finish.caseTint),
      isTrim ? Math.min(0.34, finish.tintMix * 1.15) : finish.tintMix,
    );
  }

  clone.color.r = MathUtils.clamp(clone.color.r, 0, 1);
  clone.color.g = MathUtils.clamp(clone.color.g, 0, 1);
  clone.color.b = MathUtils.clamp(clone.color.b, 0, 1);
  return clone;
}

function applyMachineFinish(
  scene: Group,
  aging?: MachineAging,
  finish?: MachineFinish,
): void {
  scene.traverse((object) => {
    if (!(object instanceof Mesh)) return;
    object.material = Array.isArray(object.material)
      ? object.material.map((material) => finishedMaterial(material, aging, finish))
      : finishedMaterial(object.material, aging, finish);
  });
}

export function prepareModelScene(
  scene: Group,
  model: MachineModel,
  aging?: MachineAging,
  finish?: MachineFinish,
) {
  const clone = scene.clone(true);
  if (aging || finish) applyMachineFinish(clone, aging, finish);
  clone.rotation.set(0, model.yaw ?? 0, 0);
  clone.updateMatrixWorld(true);
  const box = new Box3().setFromObject(clone);
  const size = box.getSize(new Vector3());
  const scale = model.targetW
    ? model.targetW / ((model.sourceW ?? size.x) || 1)
    : model.targetH / (size.y || 1);
  clone.scale.setScalar(scale);
  clone.updateMatrixWorld(true);
  const scaled = new Box3().setFromObject(clone);
  const center = scaled.getCenter(new Vector3());
  clone.position.set(-center.x, -scaled.min.y, -center.z);
  return clone;
}
