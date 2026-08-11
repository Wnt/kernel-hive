import { useEffect } from 'react';
import { loadGalleryManifest } from './galleryManifest';
import { useMuseum } from '../state/store';
import type { RuntimeVMManifestEntry, VMManifestEntry } from '../types';

// Boot-video index (BOOT-VIDEO-REPLAY-SPEC §4): a static WEBROOT/boot/index.json
// keyed by osId. Fetched best-effort and merged additively onto the catalog so
// durations/paths can change without an UI rebuild. Absent / 404 ⇒ no-op.
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

/** Which manifest rows the store gets to hold at all.
 *
 * `showcase` entries (posters with no live station behind them) are dropped here
 * and never enter the store: there is no station, so there is nothing for
 * /os/<id> to resolve to either. That is exactly the DIFFERENCE from a soft
 * hide — a soft-hidden station (registry `listing`, manifest `listed: false`) is
 * fully alive and must stay resolvable, so it is carried through here and
 * filtered only out of the store's `listedVms`. Do not filter `listed` here:
 * removing the row is what breaks the direct URL. The hardcoded HIDDEN_IDS set
 * that used to live in this file (sailfishos / postmarketos / android) is now
 * the registry `listing` block on those three entries — the same hide,
 * declared where the rest of the station is declared.
 */
export function storedLineup(
  entries: readonly RuntimeVMManifestEntry[],
): RuntimeVMManifestEntry[] {
  return entries.filter((vm) => vm.transport !== 'showcase');
}

// Fetch the public lineup at runtime so registry-only additions using an existing
// archetype appear without rebuilding the Vite bundle. There is no bundled copy:
// a failed fetch leaves the museum empty and says so in the console (see
// galleryManifest.ts). Boot metadata remains a separately published,
// best-effort overlay.
export function useManifest() {
  const setVMs = useMuseum((s) => s.setVMs);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [manifest, boot] = await Promise.all([loadGalleryManifest(), fetchBootIndex()]);
      if (cancelled) return;
      setVMs(storedLineup(manifest).map((vm) => withBoot(vm, boot)));
    })();
    return () => { cancelled = true; };
  }, [setVMs]);
}
