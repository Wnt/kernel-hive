import { useEffect } from 'react';
import { loadGalleryManifest } from './galleryManifest';
import { useMuseum } from '../state/store';
import type { RuntimeVMManifestEntry, VMManifestEntry } from '../types';

// Boot-video index (BOOT-VIDEO-REPLAY-SPEC §4): a static WEBROOT/boot/index.json
// keyed by osId. Fetched best-effort and merged additively onto the catalog so
// durations/paths can change without an SPA rebuild. Absent / 404 ⇒ no-op.
type BootIndexEntry = NonNullable<VMManifestEntry['bootVideo']>;
async function fetchBootIndex(): Promise<Record<string, BootIndexEntry>> {
  try {
    const r = await fetch('/boot/index.json', { cache: 'no-cache' });
    if (!r.ok) return {};
    const raw = (await r.json()) as Record<string, Record<string, unknown>>;
    const out: Record<string, BootIndexEntry> = {};
    for (const [id, e] of Object.entries(raw)) {
      const mp4 = typeof e.mp4 === 'string' ? e.mp4 : undefined;
      if (!mp4) continue;
      out[id] = {
        mp4,
        poster: typeof e.poster === 'string' ? e.poster : undefined,
        sprite: typeof e.sprite === 'string' ? e.sprite : undefined,
        vtt: typeof e.vtt === 'string' ? e.vtt : undefined,
        durationMs: typeof e.durationMs === 'number' ? e.durationMs : undefined,
        width: typeof e.width === 'number' ? e.width : undefined,
        height: typeof e.height === 'number' ? e.height : undefined,
        hasAudio: typeof e.hasAudio === 'boolean' ? e.hasAudio : undefined,
      };
    }
    return out;
  } catch {
    return {};
  }
}

function withBoot(vm: RuntimeVMManifestEntry, boot: Record<string, BootIndexEntry>): RuntimeVMManifestEntry {
  const b = boot[vm.id];
  return b ? { ...vm, bootVideo: { ...b, ...vm.bootVideo } } : vm;
}

// Fetch the public lineup at runtime so registry-only additions using an existing
// archetype appear without rebuilding the Vite bundle. Network/validation errors
// use the generated embedded last-known-good copy; boot metadata remains a
// separately published, best-effort overlay.
//
// `showcase` entries (posters with no live tile behind them) are dropped here,
// at the single point every SPA surface reads from: the grid, the 3D museum
// hall, deep links, and the era/total counts all derive from this store, so
// excluding them here hides them everywhere and keeps them out of every sum.
//
// HIDDEN_IDS is the same kind of hide for a different reason: these tiles
// still stream fine (transport stays 'streamhost', their services keep
// running), they're just not fit for this display yet — e.g. the phone-dock
// archetype the mobile OSes render as. Not a registry/lifecycle change.
const HIDDEN_IDS = new Set(['sailfishos', 'postmarketos', 'android']);

export function useManifest() {
  const setVMs = useMuseum((s) => s.setVMs);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [manifest, boot] = await Promise.all([loadGalleryManifest(), fetchBootIndex()]);
      if (cancelled) return;
      const streamhostOnly = manifest.filter((vm) => vm.transport !== 'showcase' && !HIDDEN_IDS.has(vm.id));
      setVMs(streamhostOnly.map((vm) => withBoot(vm, boot)));
    })();
    return () => { cancelled = true; };
  }, [setVMs]);
}
