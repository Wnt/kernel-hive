import { defineConfig, devices } from '@playwright/test';

// ============================================================================
//  streamhostInput.config.ts — per-title input regression for the streamhost tiles
//  ---------------------------------------------------------------------------
//  WHERE THIS RUNS: ON THE STREAMHOST BOX (or a peer with the tile QMP sockets +
//  a route to the SPA). Two hard reasons it cannot run from the dev Mac:
//    1. macOS local-network privacy blocks fresh Chromes from 192.168.x.x
//       (ERR_ADDRESS_UNREACHABLE).
//    2. Guest reactions are verified off each tile's LOCAL qmp.sock (screendump).
//
//  BROWSER: a proprietary-codec Chrome (Chrome for Testing / Google Chrome), NOT
//  Playwright's bundled Chromium — the streamhost wire is H.264 (webtransport-
//  h264-opus) and the codec-stripped Chromium build cannot decode it in WebCodecs.
//  Point CHROME_PATH at the binary (default: the on-host Chrome-for-Testing dir).
//
//  There is NO webServer here: the deployed SPA is already served over HTTPS by
//  osgallery-https-server.py at https://127.0.0.1:8443. Override with SPA_BASE_URL.
//
//  Run (on the host):
//    STREAMHOST_LOG=$PWD/out/input.jsonl \
//    npx playwright test -c tests/e2e/streamhostInput.config.ts
// ============================================================================

const CHROME_PATH =
  process.env.CHROME_PATH ?? '/data/streamhost-input-test/chrome-linux64/chrome';

export default defineConfig({
  testDir: '.',
  testMatch: 'streamhostInput.spec.ts',
  fullyParallel: false,
  // Each streamhost tile is single-viewer; serialise by default so screendumps are
  // unambiguous and the host isn't juggling many fresh WebTransport peers at once.
  workers: process.env.STREAMHOST_WORKERS ? Number(process.env.STREAMHOST_WORKERS) : 1,
  timeout: process.env.STREAMHOST_TEST_MS ? Number(process.env.STREAMHOST_TEST_MS) : 180_000,
  // Live guests under load occasionally drop a keyframe on the first connect; one
  // clean reconnect absorbs it without masking a real regression.
  retries: process.env.CI ? 1 : 1,
  expect: { timeout: 15_000 },
  reporter: [['list'], ['json', { outputFile: 'streamhostInput.results.json' }]],
  use: {
    ...devices['Desktop Chrome'],
    headless: true,
    viewport: { width: 1280, height: 900 },
    ignoreHTTPSErrors: true,
    actionTimeout: 20_000,
    launchOptions: {
      executablePath: CHROME_PATH,
      args: [
        '--no-sandbox',
        '--autoplay-policy=no-user-gesture-required',
        '--disable-features=WebRtcHideLocalIpsWithMdns',
      ],
    },
  },
});
