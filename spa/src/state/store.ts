import { create } from 'zustand';
import type { EnrichedVM } from '../types';

interface MuseumState {
  vms: EnrichedVM[];
  setVMs: (vms: EnrichedVM[]) => void;

  /** GeForce-Now latency lever: receiver jitter-buffer target (ms) — manual override value. */
  jitterMs: number;
  setJitterMs: (ms: number) => void;
  /** Self-tuning jitter buffer is the primary path; false once the HUD slider overrides it. */
  jitterAuto: boolean;
  setJitterAuto: (v: boolean) => void;
}

export const useMuseum = create<MuseumState>((set) => ({
  vms: [],
  setVMs: (vms) => set({ vms }),

  jitterMs: 50,
  setJitterMs: (jitterMs) => set({ jitterMs }),
  jitterAuto: true,
  setJitterAuto: (jitterAuto) => set({ jitterAuto }),
}));
