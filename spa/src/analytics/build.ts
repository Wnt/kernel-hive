// ============================================================================
//  build — WHICH BUNDLE IS THIS CLIENT RUNNING. One value, one place.
//  ---------------------------------------------------------------------------
//  `<branch>@<short-sha>` (`-dirty` when the tree was), computed once by
//  vite.config.ts's computeBuildId() and injected as
//  `import.meta.env.VITE_KH_BUILD_ID` — the same shape `box-deploy.sh --status`
//  prints and the same VALUE for a checkout at that commit, so an operator
//  compares them character-for-character rather than translating id schemes.
//
//  WHY IT IS ITS OWN MODULE. On 2026-09-01 a phone visit was recorded in full
//  — UA, session, every span — and "which bundle did that phone run?" was the
//  one question it could not answer. So the build id rides our own telemetry:
//  the `/traces` resource envelope (analytics/index.ts) and the first event of
//  every `/clientlog` batch (three/clientDebug.ts), both reading THIS constant.
//
//  spa/index.html's inline build-id script (which the boot-time error
//  reporter's `build` reads) cannot import this — it runs before any bundle
//  evaluates — so it reads the `%VITE_KH_BUILD_ID%` placeholder Vite
//  substitutes into the HTML instead. Same value, both fed by
//  vite.config.ts's single computation; see that file for the two mechanisms.
//
//  DEGRADES HONESTLY: with no git, no `define` (vitest) or an unconfigured
//  build this reads `unknown-build` — never a value that merely LOOKS like a
//  commit id.
// ============================================================================

export const BUILD_ID =
  (import.meta.env as { VITE_KH_BUILD_ID?: string }).VITE_KH_BUILD_ID || 'unknown-build';
