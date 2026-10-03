// Read defensively: registry tools also import SPA modules under plain Node.
const RUNTIME_BASE: string = (import.meta as ImportMeta & { env?: { BASE_URL?: string } }).env?.BASE_URL ?? '/';

/** Public files belong to this build's base, including staged galleries. */
export function publicAssetUrl(src: string, base = RUNTIME_BASE): string {
  // Keep remote, protocol-relative, data/blob and fragment URLs intact.
  if (!src || /^[a-z][a-z\d+.-]*:/i.test(src) || src.startsWith('//') || src.startsWith('#')) return src;
  const prefix = base.endsWith('/') ? base : `${base}/`;
  if (prefix !== '/' && src.startsWith(prefix)) return src;
  return `${prefix}${src.replace(/^\//, '')}`;
}
