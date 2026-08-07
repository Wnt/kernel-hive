import type { RuntimeVMManifestEntry } from '../types';
import type { HallEntry } from './hallLayout';

export function entriesForHall(
  registryEntries: readonly RuntimeVMManifestEntry[],
  search: string,
): HallEntry[] {
  const entries: HallEntry[] = [...registryEntries]
    .sort((a, b) => a.order - b.order)
    .map((entry) => ({
      id: entry.id,
      displayName: entry.displayName,
      era_year: entry.era_year,
      order: entry.order,
      bootVideo: entry.bootVideo,
    }));
  if (entries.length === 0) return entries;
  const requested = Number(new URLSearchParams(search).get('hallTest'));
  if (Number.isInteger(requested) && requested > 0 && requested < entries.length) {
    return entries.slice(0, requested);
  }
  if (requested !== 50 || entries.length >= 50) {
    return entries;
  }
  const originals = [...entries];
  let sourceIndex = 0;
  while (entries.length < 50) {
    const source = originals[sourceIndex % originals.length];
    entries.push({
      ...source,
      id: `hall-test-${String(entries.length + 1).padStart(2, '0')}-${source.id}`,
      order: 1000 + entries.length,
      assemblyId: source.assemblyId ?? source.id,
      bootVideo: undefined,
    });
    sourceIndex += 1;
  }
  return entries;
}
