import { defineConfig, devices } from '@playwright/test';

// ============================================================================
//  publicAuth.config.ts — passkey sign-in against the LIVE PUBLIC gallery.
//  ---------------------------------------------------------------------------
//  Chromium only, and deliberately: the ceremony runs against a CDP virtual
//  authenticator (WebAuthn.addVirtualAuthenticator), which is a Chrome DevTools
//  Protocol facility. Firefox has no equivalent, so there is no second project
//  to ride along here.
//
//  DESTRUCTIVE, and it refuses to run against a gallery that has accounts.
//  The first test redeems the one-time bootstrap token, so it needs an EMPTY
//  deployment. Do NOT clear a populated one to make it pass: auth-state.json is
//  the account database and deleting it locks every enrolled device out
//  permanently (this cost a real admin account with two devices on 2026-08-05).
//
//  Run it against a genuinely new deployment, or a separate hostname stood up
//  for testing. If the accounts really are disposable, the guarded path is
//  `scripts/serve/reset-auth.sh --force`, which backs up first and prints how
//  to undo itself.
//
//  Run (from tests/e2e-live):
//    PUBLIC_BOOTSTRAP_TOKEN=XXXXX-XXXXX-XXXXX \
//      npx playwright test -c e2e/publicAuth.config.ts
//
//  No ignoreHTTPSErrors: the public origin has a real Let's Encrypt certificate
//  from the edge, and a test that tolerated a bad one would stop noticing when
//  the tunnel's TLS broke.
// ============================================================================
export default defineConfig({
  testDir: '.',
  testMatch: 'publicAuth.spec.ts',
  fullyParallel: false,
  // Serial by nature: these tests hand state to each other (a token is spent,
  // then an account exists, then it invites someone).
  workers: 1,
  timeout: 60_000,
  retries: 0,
  expect: { timeout: 10_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: process.env.PUBLIC_ORIGIN || 'https://gallery.example.com',
    headless: true,
    viewport: { width: 1280, height: 900 },
    actionTimeout: 15_000,
    screenshot: 'only-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});
