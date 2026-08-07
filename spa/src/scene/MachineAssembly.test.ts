import { createElement } from 'react';
import { act, create, type ReactTestRenderer } from 'react-test-renderer';
import { afterEach, describe, expect, it, vi } from 'vitest';
import MachineAssembly from './MachineAssembly';
import {
  machineCableEndpoints,
  machineCableRoutes,
} from './machineCable';
import { MODELS, type Assembly } from './machines';

const { missingModelUrl } = vi.hoisted(() => ({
  missingModelUrl: '/assets/models/v2/param/404.glb',
}));

vi.mock('@react-three/drei', () => ({
  useGLTF: (url: string) => {
    if (url === missingModelUrl) throw new Error(`404 Not Found: ${url}`);
    throw new Error(`unexpected model request: ${url}`);
  },
}));

afterEach(() => {
  vi.restoreAllMocks();
});

describe('per-exhibit model resilience', () => {
  it('terminates wired mouse cables at the actual jittered machine transform', () => {
    const assembly = {
      kind: 'homeMicro',
      body: 'amigaA',
      monitor: 'homeCrtA',
      mouse: 'paramMouseA',
    } satisfies Assembly;
    const baseline = machineCableEndpoints(assembly)!;
    const varied = machineCableEndpoints(assembly, {
      machine: { offset: [0.05, 0, -0.04], yaw: 0.08 },
      keyboard: { offset: [0, 0, 0], yaw: 0 },
      mouse: { offset: [-0.03, 0, 0.05], yaw: -0.12 },
      placard: { offset: [0, 0, 0], yaw: 0, lean: 0 },
      aging: { yellowing: 0, valueOffset: 0, roughnessOffset: 0 },
    });

    expect(varied).not.toBeNull();
    expect(varied!.start).not.toEqual(baseline.start);
    expect(varied!.end).not.toEqual(baseline.end);
    expect(varied!.end[0]).toBeGreaterThan(baseline.end[0]);
    expect(varied!.end[2]).toBeLessThan(baseline.end[2]);
  });

  it('extends keyboardF molded plugs to the jittered host connection', () => {
    const assembly = {
      kind: 'towerSetup',
      body: 'towerE',
      monitor: 'lcdC',
      keyboard: 'keyboardF',
      mouse: 'paramMouseE',
    } satisfies Assembly;
    const baseline = machineCableRoutes(assembly);
    const varied = machineCableRoutes(assembly, {
      machine: { offset: [0.04, 0, -0.03], yaw: 0.06 },
      keyboard: { offset: [-0.05, 0, 0.04], yaw: -0.08 },
      mouse: { offset: [0, 0, 0], yaw: 0 },
      placard: { offset: [0, 0, 0], yaw: 0, lean: 0 },
      aging: { yellowing: 0, valueOffset: 0, roughnessOffset: 0 },
    });
    const keyboard = varied.find((route) => route.kind === 'keyboard');

    expect(baseline.map((route) => route.kind)).toEqual(['mouse', 'keyboard']);
    expect(keyboard).toBeDefined();
    expect(keyboard!.start).not.toEqual(baseline[1].start);
    expect(keyboard!.end).not.toEqual(baseline[1].end);
    expect(keyboard!.end[0]).toBeGreaterThan(baseline[1].end[0]);
  });

  it('contains a 404 GLB at its desk and leaves the rest of the scene mounted', async () => {
    const model = MODELS.crtA as { url: string };
    const originalUrl = model.url;
    model.url = missingModelUrl;
    const onError = vi.fn();
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
    (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
    let renderer: ReactTestRenderer | undefined;

    try {
      await act(async () => {
        renderer = create(createElement(
          'group',
          { name: 'scene-root' },
          createElement(MachineAssembly, {
            assembly: { kind: 'terminal', body: 'crtA' } satisfies Assembly,
            tileId: 'missing-model',
            onError,
          }),
          createElement('group', { name: 'healthy-exhibit' }),
        ));
      });

      expect(onError).toHaveBeenCalledWith(expect.objectContaining({
        message: expect.stringContaining('404 Not Found'),
      }));
      expect(renderer!.root.findByProps({ name: 'dust-cover-placeholder' })).toBeDefined();
      expect(renderer!.root.findByProps({ name: 'healthy-exhibit' })).toBeDefined();
    } finally {
      model.url = originalUrl;
      renderer?.unmount();
    }
  });
});
