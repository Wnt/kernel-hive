import { useEffect } from 'react';
import { loadGalleryManifest } from './galleryManifest';
import { useMuseum } from '../state/store';
import { useSession } from './SessionContext';
import { exhibitVm, loadWalkinExhibits } from '../walkin/manifest';
import { walkinShape } from '../walkin/route';
import type { RuntimeVMManifestEntry, VMManifestEntry } from '../types';
import { reach } from '../analytics';

// Boot-video index (BOOT-VIDEO-REPLAY-SPEC §4): a static WEBROOT/boot/index.json
// keyed by osId. Fetched best-effort and merged additively onto the catalog so
// durations/paths can change without an UI rebuild. Absent / 404 ⇒ no-op.
type BootIndexEntry = NonNullable<VMManifestEntry['bootVideo']>;
async function fetchBootIndex(): Promise<Record<string, BootIndexEntry>> {
  try {
    // Fetched on every SUCCESSFUL manifest load (a non-empty gallery lineup —
    // see the one call site, below); the videos it indexes only ever play on a
    // station from that lineup, never on a walk-in exhibit placard, so a load
    // that fell through to the walk-in door never had a use for this and no
    // longer asks. boot.video.played is the consumer, and the gap between the
    // two is the question.
    reach('boot.index.fetch', 'auto');
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
      const manifest = await loadGalleryManifest();
      if (cancelled) return;
      const lineup = storedLineup(manifest);
      if (lineup.length > 0) {
        // Boot-video enrichment is fetched ONLY here, once there is a lineup to
        // enrich — `boot` is used nowhere but the `withBoot` merge below, so
        // firing it alongside the manifest (as `Promise.all`, until this fix)
        // spent a request whenever the manifest fell through instead. That was
        // not a hypothetical: on the public listener an anonymous visitor's
        // `/gallery-manifest.json` is refused (`walkinShape` cannot know that in
        // advance — see the comment below), so this fetch used to fire and 401
        // on every anonymous landing too, adding noise beside the manifest's
        // own refusal for no gain — its result was always discarded a few lines
        // down. Sequencing it after a non-empty lineup costs the ordinary
        // invited visitor one extra same-origin round trip; the alternative
        // was a fetch nobody used, addressed to a role that cannot use it.
        const boot = await fetchBootIndex();
        if (cancelled) return;
        setVMs(lineup.map((vm) => withBoot(vm, boot)));
        return;
      }
      // Nothing came back, so ask through the walk-in door before giving up.
      //
      // `walkinShape` cannot answer this one from the role: a STRANGER is
      // `role: 'anon'` on both planes, and the two planes disagree about what
      // that means. On the public listener `/gallery-manifest.json` is gated
      // and 401s — the landing page is open to strangers now, so this is the
      // ordinary case, not an edge one. On the unauthenticated LAN origin the
      // very same role reads the fleet manifest perfectly well. Testing the
      // role would fix the museum's front door and empty the LAN grid.
      //
      // Refusal is the signal, so we let the fetch answer instead: an empty
      // lineup falls through to `/walkin/manifest.json`, the server's own
      // allowlist projection, which is public and carries every exhibition row.
      const exhibits = await loadWalkinExhibits();
      if (cancelled) return;
      if (exhibits.length === 0) {
        // BOTH doors came back empty. That is no longer an expected refusal
        // recovered a line later — it is the museum showing nothing to
        // anybody, gallery visitor or walk-in, and `loadGalleryManifest`
        // deliberately does not log for exactly this reason: it cannot tell
        // "refused, and about to recover" from "genuinely broken" by itself.
        // This is the one place that knows both outcomes, so this is where
        // the loud log belongs.
        console.error(
          "[gallery-manifest] no lineup from the gallery manifest or the walk-in projection — publish it with 'serve-https-spa.sh manifests'",
        );
      }
      setVMs(exhibits.map(exhibitVm));
    })();
    return () => { cancelled = true; };
  }, [setVMs, walkin]);
}
