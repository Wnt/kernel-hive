// ============================================================================
//  build — WHICH BUNDLE IS THIS CLIENT RUNNING. One value, one place.
//  ---------------------------------------------------------------------------
//  `<branch>@<short-sha>` (`-dirty` when the tree was), computed once by
//  vite.config.ts's computeBuildId() and injected as
//  `import.meta.env.VITE_KH_BUILD_ID` — the same shape `box-deploy.sh --status`
//  prints and the same VALUE for a checkout at that commit, so an operator
//  compares them character-for-character rather than translating id schemes.
//
//  WHY IT IS ITS OWN MODULE. On 2026-09-01 a phone visit was recorded fully by
//  our own plane and not at all by the vendor's, and the question "which bundle
//  did that phone run?" had exactly one answer path: a vendor beacon's
//  `kh.bundle` meta, set in spa/index.html. Our own plane knew the UA and the
//  session and not the build. That is backwards for a vendor we intend to drop,
//  so the build id now rides OUR OWN telemetry: the `/traces` resource envelope
//  (analytics/index.ts) and the first event of every `/clientlog` batch
//  (three/clientDebug.ts), both reading THIS constant.
//
//  spa/index.html's two inline bootstraps (Instana's `kh.bundle`, the boot-time
//  error reporter's `build`) cannot import this — they run before any bundle
//  evaluates — so they read the `%VITE_KH_BUILD_ID%` placeholder Vite
//  substitutes into the HTML instead. Same value, both fed by
//  vite.config.ts's single computation; see that file for the two mechanisms.
//
//  DEGRADES HONESTLY: with no git, no `define` (vitest) or an unconfigured
//  build this reads `unknown-build` — never a value that merely LOOKS like a
//  commit id.
// ============================================================================

export const BUILD_ID =
  (import.meta.env as { VITE_KH_BUILD_ID?: string }).VITE_KH_BUILD_ID || 'unknown-build';
