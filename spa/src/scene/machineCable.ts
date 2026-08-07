import type {
  ExhibitVariation,
  LocalPlacementVariation,
  Point3,
} from './hallLayout';
import {
  MODELS,
  type Assembly,
  type MachineModel,
  type ModelKey,
} from './machines';

const DISPLAY_Z = -0.17;
const KEYBOARD_Z = 0.23;
const MOUSE_X = 0.43;

export interface MachineCableRoute {
  kind: 'keyboard' | 'mouse';
  start: Point3;
  end: Point3;
}

const MOUSE_CABLE_END: Partial<Record<ModelKey, Point3>> = {
  paramMouseA: [-0.068, 0.005, -0.032],
  paramMouseB: [-0.068, 0.005, -0.035],
  paramMouseC: [-0.065, 0.005, -0.033],
  paramMouseD: [-0.068, 0.005, -0.036],
  paramMouseE: [-0.068, 0.005, -0.034],
  paramMouseG: [0.072, 0.005, -0.065],
};

// keyboard-f.glb is one baked mesh containing the reviewed USB lead and molded
// plug. The generator's plug tip is x=.285, rear y=.146 in Blender space.
// Applying the production GLB bounds normalization yields this local endpoint.
const KEYBOARD_F_PLUG_TIP: Point3 = [0.2083, 0.0035, -0.0876];

const ZERO_PLACEMENT: LocalPlacementVariation = {
  offset: [0, 0, 0],
  yaw: 0,
};

const ZERO_VARIATION: ExhibitVariation = {
  machine: ZERO_PLACEMENT,
  keyboard: ZERO_PLACEMENT,
  mouse: ZERO_PLACEMENT,
  placard: { ...ZERO_PLACEMENT, lean: 0 },
  aging: { yellowing: 0, valueOffset: 0, roughnessOffset: 0 },
};

function placedPoint(
  base: Point3,
  local: Point3,
  placement: LocalPlacementVariation,
): Point3 {
  const cos = Math.cos(placement.yaw);
  const sin = Math.sin(placement.yaw);
  return [
    base[0] + placement.offset[0] + local[0] * cos + local[2] * sin,
    base[1] + placement.offset[1] + local[1],
    base[2] + placement.offset[2] - local[0] * sin + local[2] * cos,
  ];
}

function mouseBase(assembly: Assembly): Point3 {
  if (assembly.kind === 'homeMicro') return [MOUSE_X, 0, 0.16];
  if (assembly.kind === 'industrial') return [MOUSE_X - 0.08, 0, KEYBOARD_Z];
  if (assembly.kind === 'towerSetup') return [MOUSE_X - 0.06, 0, KEYBOARD_Z];
  return [MOUSE_X, 0, KEYBOARD_Z];
}

function keyboardBase(assembly: Assembly): Point3 {
  if (assembly.kind === 'industrial') return [-0.08, 0, KEYBOARD_Z];
  if (assembly.kind === 'towerSetup') return [-0.12, 0, KEYBOARD_Z];
  return [0, 0, KEYBOARD_Z];
}

function machineCableAnchor(assembly: Assembly): Point3 | null {
  if (assembly.kind === 'homeMicro' && assembly.body) {
    const body = MODELS[assembly.body] as MachineModel;
    return [(body.targetW ?? 0.4) / 2 - 0.012, 0.018, 0.13];
  }
  if (assembly.kind === 'pizzaBox' && assembly.body) {
    const body = MODELS[assembly.body] as MachineModel;
    return [(body.targetW ?? 0.4) / 2 - 0.012, 0.025, 0.04];
  }
  if (assembly.kind === 'towerSetup' && assembly.body) {
    return [0.62, -0.72 + MODELS[assembly.body].targetH * 0.72, 0.1];
  }
  if (assembly.kind === 'allInOne' && assembly.body) {
    const body = MODELS[assembly.body] as MachineModel;
    return [(body.targetW ?? 0.4) / 2 - 0.012, 0.025, DISPLAY_Z + 0.06];
  }
  if (assembly.kind === 'industrial' && assembly.body) {
    const body = MODELS[assembly.body] as MachineModel;
    return [0.42 - (body.targetW ?? 0.22) / 2, 0.022, DISPLAY_Z + 0.08];
  }
  return null;
}

export function machineCableEndpoints(
  assembly: Assembly,
  variation: ExhibitVariation = ZERO_VARIATION,
): { start: Point3; end: Point3 } | null {
  if (!assembly.mouse) return null;
  const looseEnd = MOUSE_CABLE_END[assembly.mouse];
  const anchor = machineCableAnchor(assembly);
  if (!looseEnd || !anchor) return null;
  return {
    start: placedPoint(mouseBase(assembly), looseEnd, variation.mouse),
    end: placedPoint([0, 0, 0], anchor, variation.machine),
  };
}

export function machineCableRoutes(
  assembly: Assembly,
  variation: ExhibitVariation = ZERO_VARIATION,
): MachineCableRoute[] {
  const routes: MachineCableRoute[] = [];
  const mouse = machineCableEndpoints(assembly, variation);
  if (mouse) routes.push({ kind: 'mouse', ...mouse });

  const anchor = machineCableAnchor(assembly);
  if (assembly.keyboard === 'keyboardF' && anchor) {
    routes.push({
      kind: 'keyboard',
      start: placedPoint(
        keyboardBase(assembly),
        KEYBOARD_F_PLUG_TIP,
        variation.keyboard,
      ),
      end: placedPoint([0, 0, 0], anchor, variation.machine),
    });
  }
  return routes;
}
