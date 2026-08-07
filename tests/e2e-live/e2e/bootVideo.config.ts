import { defineConfig, devices } from '@playwright/test';

// ============================================================================
//  bootVideo.config.ts — boot-video replay smoke vs the DEPLOYED gallery.
//  ---------------------------------------------------------------------------
//  Proves the BootVideoOverlay path end-to-end on ONE bootVideo tile (win95):
//  overlay mounts, clip plays + scrubs, Skip hands off to the painting live
//  surface. Chromium is the REQUIRED project; Firefox rides along because the
//  probe already handles its direct-paint <canvas> (needs system libavcodec for
//  H.264 WebCodecs — apt-get install ffmpeg; see docs/lab/dev-box-notes.md).
//
//  Run (defaults to the live box URL):
//    npm run test:boot
//    npx playwright test -c e2e/bootVideo.config.ts --project=chromium
//    GALLERY_URL=https://192.0.2.10:8443 npm run test:boot
// ============================================================================
export default defineConfig({
  testDir: '.',
  testMatch: 'bootVideo.spec.ts',
  fullyParallel: false,
  workers: 1, // one tile stream at a time — parallel fresh WebTransport peers flake the box
  timeout: 150_000, // clip interaction + skip + live connect budget
  retries: 0,
  expect: { timeout: 15_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`,
    headless: true,
    viewport: { width: 1600, height: 900 },
    ignoreHTTPSErrors: true,
    actionTimeout: 15_000,
    screenshot: 'only-on-failure',
  },
  projects: [
    // Chromium FIRST — the required row.
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        launchOptions: { args: ['--autoplay-policy=no-user-gesture-required'] },
      },
    },
    // Firefox: cheap extra coverage of the direct-paint canvas handoff.
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
  ],
});
