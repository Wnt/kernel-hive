import { describe, expect, it } from 'vitest';
import manifest from '../../../scripts/serve/webroot/gallery-manifest.json' with { type: 'json' };
import {
  ASSEMBLIES_BY_TILE,
  MODELS,
  MONITOR_MODEL_KEYS,
  PHONE_DOCK_DISPLAY_SCALE,
  type Assembly,
  type MachineModel,
  type ModelKey,
} from './machines';
import { lampScaleForDesk } from './lampScale';
import type { HallDesk } from './hallLayout';
import { identityBadgeSurface } from './machineBadge';

const registryIds = [...manifest.entries]
  .sort((a, b) => a.order - b.order)
  .map((entry) => entry.id);

describe('scene-v2 registry hardware bindings', () => {
  it('maps every registry lineup entry exactly once', () => {
    expect(Object.keys(ASSEMBLIES_BY_TILE)).toEqual(registryIds);
  });

  it('only references declared model keys', () => {
    for (const assembly of Object.values(ASSEMBLIES_BY_TILE) as Assembly[]) {
      for (const key of ['combo', 'body', 'monitor', 'keyboard', 'mouse'] as const) {
        if (assembly[key]) expect(MODELS).toHaveProperty(assembly[key]);
      }
    }
  });

  it('gives every entry a distinct complete hardware signature', () => {
    const parts = ['body', 'monitor', 'keyboard', 'mouse'] as const;
    const signatures = Object.entries(ASSEMBLIES_BY_TILE).map(([tileId, entry]) => {
      const assembly: Assembly = entry;
      return {
        tileId,
        signature: parts.map((part) => assembly[part] ?? 'none').join('|'),
      };
    });
    expect(new Set(signatures.map(({ signature }) => signature)).size)
      .toBe(signatures.length);
  });

  it('conforms representative rows to the hardware matrix', () => {
    expect(ASSEMBLIES_BY_TILE.freedos).toEqual({
      kind: 'pizzaBox',
      body: 'pizzaBoxB',
      monitor: 'crtA',
      keyboard: 'keyboardA',
      mouse: 'paramMouseA',
    });
    expect(ASSEMBLIES_BY_TILE.solaris).toEqual({
      kind: 'pizzaBox',
      body: 'pizzaBoxC',
      monitor: 'crtE',
      keyboard: 'keyboardH',
      mouse: 'paramMouseG',
    });
    expect(ASSEMBLIES_BY_TILE.msdoswin1).toEqual({
      kind: 'pizzaBox',
      body: 'pizzaBoxA',
      monitor: 'crtD',
      keyboard: 'keyboardD',
      mouse: 'paramMouseA',
    });
    expect(ASSEMBLIES_BY_TILE.macos).toEqual({
      kind: 'pizzaBox',
      body: 'modernMini',
      monitor: 'lcdB',
      keyboard: 'keyboardG',
      mouse: 'paramMouseF',
    });
    expect(ASSEMBLIES_BY_TILE.nt4).toEqual({
      kind: 'pizzaBox',
      body: 'pizzaBoxF',
      monitor: 'paramCrt',
      keyboard: 'keyboardB',
      mouse: 'paramMouseB',
    });
  });

  it('ships every museum model from the project-original parametric set', () => {
    for (const [key, model] of Object.entries(MODELS)) {
      expect(model.url, key).toMatch(/^\/assets\/models\/v2\/param\//);
    }
  });

  it('gives every monitor model a sane measured screen rectangle', () => {
    for (const key of MONITOR_MODEL_KEYS) {
      const screen = (MODELS[key] as MachineModel).screen;
      expect(screen, key).toBeDefined();
      for (const dimension of screen!.size) {
        expect(dimension, `${key} screen dimension`).toBeGreaterThanOrEqual(0.1);
        expect(dimension, `${key} screen dimension`).toBeLessThanOrEqual(0.6);
      }
      expect(screen!.center.every(Number.isFinite), `${key} screen center`).toBe(true);
    }
  });

  it('has one screen-bearing model for every registry tile', () => {
    for (const tileId of registryIds) {
      const assembly = ASSEMBLIES_BY_TILE[tileId as keyof typeof ASSEMBLIES_BY_TILE] as Assembly;
      const screenModels = (['combo', 'body', 'monitor'] as const)
        .map((part) => assembly[part])
        .filter((key): key is ModelKey => (
          !!key && !!(MODELS[key] as MachineModel).screen
        ));
      expect(screenModels, tileId).toHaveLength(1);
    }
  });

  it('selects one identity-badge surface for every registry station', () => {
    for (const [tileId, assembly] of Object.entries(ASSEMBLIES_BY_TILE)) {
      expect(identityBadgeSurface(assembly), tileId).not.toBeNull();
    }
    expect(identityBadgeSurface(ASSEMBLIES_BY_TILE.freedos)).toBe('case');
  });

  it('registers the Amiga CRT content in front of the authored glass apex', () => {
    expect(MODELS.homeCrtA.screen.surfaceOffset).toBeGreaterThan(0.014);
  });

  it('keeps handheld screen rectangles physically plausible', () => {
    for (const key of ['phoneA', 'phoneB', 'phoneC'] as const) {
      const [width, height] = MODELS[key].screen.size;
      expect(width).toBeGreaterThan(0.035);
      expect(height).toBeLessThanOrEqual(0.12);
    }
  });

  it('gives only the underscaled repairable-phone dock a display boost', () => {
    expect(PHONE_DOCK_DISPLAY_SCALE).toEqual({ phoneC: 1.65 });
  });

  it.each(['c64', 'amstradcpc'] as const)(
    'clamps the %s desk lamp below the station display envelope',
    (tileId) => {
      const entry = manifest.entries.find((candidate) => candidate.id === tileId)!;
      const desk = {
        entry,
      } as unknown as HallDesk;
      const scale = lampScaleForDesk(desk);
      const assembly = ASSEMBLIES_BY_TILE[tileId] as Assembly;
      const display = MODELS[assembly.monitor!] as MachineModel;
      expect(0.65 * scale).toBeLessThanOrEqual(display.targetH * 0.65);
      expect(0.19 * scale).toBeLessThanOrEqual(display.screen!.size[0] * 0.5);
    },
  );
});
