// ============================================================================
//  analytics/stationAttrs — the grouping dimensions that make a station-scoped
//  span or metric sliceable by station TYPE, not merely by id.
//  ---------------------------------------------------------------------------
//  The operator's ask: latency for wakeup, golden reset and friends should be
//  groupable per station type in both Instana and our own trace store. Every
//  span already carries free-text attributes (analytics/trace.ts); what was
//  missing was a CONSISTENT set of names for the dimensions worth grouping by,
//  computed once from data the registry already publishes rather than
//  hand-maintained a second time in the SPA.
//
//  WHERE THE VALUES COME FROM. `registry/stations/*.json` is the single
//  source (AGENTS.md, `scripts/stations-registry.py`); `emulator.family`,
//  `ui` and `reset.resetMode` reach the browser via `gallery-manifest.json`
//  (`scripts/stations_registry/render.py`'s `emit_gallery_manifest`, and
//  `spa/src/data/galleryManifest.ts`'s validator) — the SAME manifest fetch
//  that already carries `archetypeId`/`transport`/etc. Nothing here reaches
//  into the registry a second time.
//
//  WHY THESE FOUR AND NOT MORE. `emulatorFamily` (QEMU/MAME/VICE/UAE/SIMH/
//  es40/Previous/…), `ui` (desktop/home-computer/text-console/mobile/other)
//  and `resetMode` (loadvm/relaunch/restart) are each a handful of values —
//  the report's own section list in miniature. `transport` (streamhost vs the
//  rare webrtc-fallback a WebCodecs-less browser takes) is the one dimension
//  this file does NOT get from the registry, because it is not a station
//  fact — it is a property of the SESSION, decided by feature detection in
//  useStreamhostSession. Callers merge it in themselves (see that file).
//
//  `kh.station.id` stays a SEPARATE attribute from the three above on
//  purpose. It is the higher-cardinality one (63 values against a handful),
//  so a query that wants "every QEMU station" groups by `emulatorFamily`
//  alone; a query that wants one machine's own history still has `id` to
//  drill into. Baking id into the others (or into a span/metric NAME) would
//  make the low-cardinality dimensions unusable for exactly the grouping they
//  exist for.
//
//  SAME NAMES ON BOTH SIDES OF THE WIRE. These are the identical keys
//  `instana.ts`'s station tagging uses via `ineum('meta', k, v)` — see that
//  file's header — so a query means the same thing in our own trace store and
//  in Instana's Unbounded Analytics. No content-rule exception: every value
//  here is registry METADATA, never anything a visitor typed or a station
//  identity a visitor doesn't already see on the grid card.
// ============================================================================

import type { Attrs } from './trace';

/** The subset of a manifest/binding row this module reads. Structurally
 *  typed rather than importing `OSBinding`/`RuntimeVMManifestEntry` — both
 *  carry these fields, and either can be passed here without a coupling. */
export interface StationTypeSource {
  osId?: string;
  emulatorFamily?: string;
  uiKind?: string;
  resetMode?: string;
}

/** Build the grouping attrs for one station. Missing fields are simply
 *  omitted — a poster row has no `resetMode`, and a call site that only has
 *  a bare osId (no manifest row resolved yet) still gets `kh.station.id`. */
export function stationAttrs(source: StationTypeSource | null | undefined): Attrs {
  if (!source) return {};
  const out: Attrs = {};
  if (source.osId) out['kh.station.id'] = source.osId;
  if (source.emulatorFamily) out['kh.station.emulatorFamily'] = source.emulatorFamily;
  if (source.uiKind) out['kh.station.ui'] = source.uiKind;
  if (source.resetMode) out['kh.station.resetMode'] = source.resetMode;
  return out;
}
