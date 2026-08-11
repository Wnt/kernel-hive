import { create } from 'zustand';
import type { EnrichedVM } from '../types';

// The lineup is kept TWICE on purpose, and which one a caller reads is the
// whole of the soft-hide feature (registry `listing`, manifest `listed`):
//
//   vms        every row the manifest carried — what an ID RESOLVES against.
//              /os/:osId, the poster modal and the per-station boot lookup read
//              this, so a hidden station stays deep-linkable and streams as before.
//   listedVms  the announced lineup — what a LISTING renders. The grid and the
//              3D hall (and therefore every era/total count) read this.
//
// Deriving both here, once, is why the filter is not sprinkled across render
// sites: setVMs is the only place the rule lives, and the two field names make a
// wrong read obvious at the call site. Doing it the other way round — filtering
// hidden rows out of `vms` before they reach the store — is precisely what
// breaks the direct URL, because there is then no row left to resolve.
//
// This is DISCOVERABILITY, NOT ACCESS CONTROL: the hidden row ships in the
// public manifest, so anyone holding (or guessing) the URL gets in.
function isListed(vm: EnrichedVM): boolean {
  return vm.listed !== false;
}

interface MuseumState {
  /** Every manifest row, hidden ones included — the id-resolution source. */
  vms: EnrichedVM[];
  /** The announced lineup: `vms` minus soft-hidden rows — the listing source. */
  listedVms: EnrichedVM[];
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
  listedVms: [],
  setVMs: (vms) => set({ vms, listedVms: vms.filter(isListed) }),

  jitterMs: 50,
  setJitterMs: (jitterMs) => set({ jitterMs }),
  jitterAuto: true,
  setJitterAuto: (jitterAuto) => set({ jitterAuto }),
}));
