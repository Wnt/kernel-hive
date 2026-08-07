import type { HallDesk } from './hallLayout';
import {
  MODELS,
  assemblyForTile,
  type Assembly,
  type MachineModel,
  type ModelKey,
} from './machines';

const LAMP_HEIGHT = 0.65;
const LAMP_SHADE_WIDTH = 0.19;
const DEFAULT_LAMP_SCALE = 0.86;

function displayModelKey(assembly: Assembly): ModelKey | undefined {
  if (assembly.monitor) return assembly.monitor;
  if (assembly.combo) return assembly.combo;
  return assembly.body;
}

export function lampScaleForDesk(desk: HallDesk): number {
  const assembly = assemblyForTile(desk.entry.assemblyId ?? desk.entry.id);
  const displayKey = displayModelKey(assembly);
  const display = displayKey ? MODELS[displayKey] as MachineModel : undefined;
  if (!display?.screen) return DEFAULT_LAMP_SCALE;
  return Math.min(
    DEFAULT_LAMP_SCALE,
    display.targetH * 0.65 / LAMP_HEIGHT,
    display.screen.size[0] * 0.5 / LAMP_SHADE_WIDTH,
  );
}
