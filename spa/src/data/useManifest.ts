import { useEffect } from 'react';
import { loadGalleryManifest } from './galleryManifest';
import { useMuseum } from '../state/store';
import { useSession } from './SessionContext';
import { exhibitVm, loadWalkinExhibits } from '../walkin/manifest';
import { walkinShape } from '../walkin/route';
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
  const { role } = useSession();
  // The signed-out stranger on /walkin has no role yet and must not fire the
  // gallery's gated fetches either — see walkin/route.ts.
  const walkin = walkinShape(role, window.location.pathname, import.meta.env.BASE_URL);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      // A walk-in reads the SAME store through a different door. Their lineup
      // is `/walkin/manifest.json` — the server-side allowlist projection of
      // the very same fleet (gate.py `walkin_manifest`) — and the two gallery
      // overlays are skipped outright rather than fetched and refused:
      // `/gallery-manifest.json` and `/boot/index.json` are both gated, and
      // asking anyway is what used to leave the grid empty with a 401 in the
      // console. Placard rows keep `transport: 'showcase'` and so must NOT go
      // through `storedLineup`, which drops showcase entries — for a walk-in a
      // placard is the point of the row, not a poster with no station behind it.
      if (walkin) {
        const exhibits = await loadWalkinExhibits();
        if (cancelled) return;
        setVMs(exhibits.map(exhibitVm));
        return;
      }
      const [manifest, boot] = await Promise.all([loadGalleryManifest(), fetchBootIndex()]);
      if (cancelled) return;
      setVMs(storedLineup(manifest).map((vm) => withBoot(vm, boot)));
    })();
    return () => { cancelled = true; };
  }, [setVMs, walkin]);
}
