// ============================================================================
//  streamhostInput.spec.ts — parameterized per-title input regression suite.
//  ---------------------------------------------------------------------------
//  One Playwright test per streamhost tile (24), each proving decode + control +
//  a pixel-verified mouse AND keyboard reaction on the guest's own framebuffer.
//  See streamhostInput.harness.ts for the runner and streamhostInput.group.ts for
//  the tile table. Run with streamhostInput.config.ts (on the host).
// ============================================================================

import { runInputTest } from './streamhostInput.harness';
import { STREAMHOST_INPUT_TILES } from './streamhostInput.group';

for (const spec of STREAMHOST_INPUT_TILES) {
  runInputTest(spec);
}
