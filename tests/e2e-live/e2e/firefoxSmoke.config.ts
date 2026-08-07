import { defineConfig, devices } from '@playwright/test';

// ============================================================================
//  firefoxSmoke.config.ts — Firefox decode smoke vs the DEPLOYED gallery.
//  ---------------------------------------------------------------------------
//  THE quick-start suite: proves the deployed SPA bundle decodes the H.264
//  WebCodecs stream in Firefox (the avc/avcC path — Firefox's annexb mode is
//  broken, Bugzilla 1918769). Firefox is the point; a chromium project rides
//  along as a cheap cross-browser regression.
//
//  Prereqs (once, in tests/e2e-live):
//    npm install                          # @playwright/test ^1.61 (firefox-1532)
//    npx playwright install firefox chromium
//  On a fresh dev box ALSO: apt-get install ffmpeg  (libavcodec60 — Firefox
//  H.264 WebCodecs needs system libavcodec; without it isConfigSupported is
//  false and decode silently fails). See docs/lab/dev-box-notes.md.
//
//  Run (defaults to the live box URL):
//    npx playwright test -c e2e/firefoxSmoke.config.ts
//    npx playwright test -c e2e/firefoxSmoke.config.ts --project=firefox
//    GALLERY_URL=https://192.0.2.10:8443 npm run test:firefox
//
//  BASELINE NOTE: against the pre-avc deployed bundle the firefox project is
//  EXPECTED to fail with the "stream stalled" chip (verified 2026-07-12).
//  The real verdict is post-deploy of the ff/client bundle.
// ============================================================================
export default defineConfig({
  testDir: '.',
  testMatch: 'firefoxSmoke.spec.ts',
  fullyParallel: false,
  // One tile stream at a time — parallel fresh WebTransport peers flake the box.
  workers: 1,
  // Per tile: grid render + card click + connect + first keyframe + probe.
  timeout: 90_000,
  retries: 0,
  expect: { timeout: 10_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`,
    headless: true, // validated: headless Firefox does WebCodecs+WebTransport fine
    viewport: { width: 1600, height: 900 },
    ignoreHTTPSErrors: true,
    actionTimeout: 15_000,
    screenshot: 'only-on-failure',
  },
  projects: [
    // Firefox FIRST — this suite exists for it.
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    // Chromium row: cheap regression that the avc path didn't break Chrome.
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        launchOptions: { args: ['--autoplay-policy=no-user-gesture-required'] },
      },
    },
  ],
});
