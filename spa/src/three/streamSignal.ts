import type { OSBinding } from './archetypeRegistry';

/**
 * The streamhost signaling endpoint for a tile. Explicit `binding.signalEndpoint`
 * wins; otherwise it is served SAME-ORIGIN by the HTTPS SPA server
 * (scripts/serve/osgallery-https-server.py) at `/signal/<osId>.json`, returning
 * `{ host, udpPort, certHashB64 }` re-read per request so cert rotation needs no
 * SPA restart. The client turns that document into `https://host:udpPort/wt`.
 */
export function streamhostSignalFor(binding: OSBinding): string {
  if (binding.signalEndpoint) return binding.signalEndpoint;
  return `/signal/${binding.osId}.json`;
}
