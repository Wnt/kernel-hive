// ============================================================================
//  softwareDecodeLatch — a PAGE-LIFETIME "stop asking for the hardware decoder"
//  flag, shared by every StreamClient this page builds.
//  ---------------------------------------------------------------------------
//  `hwDecodeOk` / `hwFellBack` are per-StreamClient, and a reconnect always
//  builds a fresh one — so a client that learned the hard way that the hardware
//  decoder is poisoned threw that knowledge away the moment it retried, probed
//  'prefer-hardware' again, and reproduced the identical silent stall. That is
//  the loop behind a resume that stays black through attempt after attempt.
//
//  The demotion is deliberately page-lifetime and one-way: a GPU context lost to
//  a tab discard or a mobile app-switch does not come back within the page, and
//  software decode at these geometries costs CPU but always produces pixels.
//  A reload starts clean and re-probes the hardware path.
// ============================================================================

let softwareOnly = false;

/** Called when a decoder failed with NO error callback (silent stall). */
export function latchSoftwareDecode() { softwareOnly = true; }

/** True once any client on this page proved the hardware decoder unusable. */
export function isSoftwareDecodeLatched() { return softwareOnly; }

/** Tests only — the latch is module state shared across the whole page. */
export function resetSoftwareDecodeLatch() { softwareOnly = false; }
