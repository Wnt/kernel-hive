// ============================================================================
//  publicAuth.spec.ts — the passkey login, exercised for real.
//  ---------------------------------------------------------------------------
//  scripts/serve/auth/test_auth.py covers every decision AROUND the ceremony
//  (code parsing, invites, roles, the state file, the last-admin guard) but it
//  cannot perform one — that needs an authenticator. Here a CDP virtual
//  authenticator supplies it, so the ceremony is genuine: real WebAuthn, real
//  origin binding, real signature verification by fido2 on the box.
//
//  Because it runs against the public origin, a pass also proves the forwarder
//  tunnel, Caddy's on-demand certificate, the cookie flags over the real TLS
//  hop, and the auth gate in front of the gallery.
//
//  See publicAuth.config.ts for how to run it and how to reset the token after.
// ============================================================================
import { test, expect, type BrowserContext, type Page } from '@playwright/test';

const ORIGIN = process.env.PUBLIC_ORIGIN || 'https://gallery.example.com';
const TOKEN = process.env.PUBLIC_BOOTSTRAP_TOKEN || '';

/** A virtual passkey that behaves like a platform authenticator (phone/laptop). */
async function virtualAuthenticator(page: Page) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('WebAuthn.enable');
  await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true, // discoverable, so signing in needs no username
      hasUserVerification: true,
      isUserVerified: true, // no biometric prompt to click through
      automaticPresenceSimulation: true,
    },
  });
}

test.describe('public gallery auth', () => {
  test.skip(!TOKEN, 'set PUBLIC_BOOTSTRAP_TOKEN to the one-time master token');
  test.describe.configure({ mode: 'serial' });

  // ONE context for the whole file, not Playwright's per-test default: these
  // tests hand state to each other on purpose — a token is spent, an account
  // exists, then it invites someone — and both the session cookie and the
  // registered virtual passkey live in the context. A fresh context per test
  // would silently sign the user back out between steps.
  let ctx: BrowserContext;
  let page: Page;

  test.beforeAll(async ({ browser }) => {
    ctx = await browser.newContext();
    page = await ctx.newPage();

    // HARD STOP on a gallery that has accounts. This suite needs an empty one
    // (it redeems the master token), and the obvious way to get one is to
    // delete auth-state.json — which destroys real passkeys permanently. That
    // is exactly how a live admin account with two enrolled devices was lost on
    // 2026-08-05. Point this at a gallery that is genuinely new, or stand up a
    // separate hostname for it; do NOT clear a populated one to make it pass.
    const state = await page.request.get(`${ORIGIN}/auth/state`);
    const { needsBootstrap } = await state.json();
    if (!needsBootstrap) {
      throw new Error(
        `${ORIGIN} already has accounts. This suite is destructive and needs an EMPTY gallery — ` +
          'do not wipe a real one to satisfy it (passkeys cannot be recovered). ' +
          'Use a throwaway deployment, or scripts/serve/reset-auth.sh if the accounts truly are disposable.'
      );
    }

    await page.goto(`${ORIGIN}/login`);
    await virtualAuthenticator(page);
  });

  test.afterAll(async () => {
    await ctx?.close();
  });

  test('a signed-out visitor lands on login and cannot read signalling', async () => {
    await page.goto(`${ORIGIN}/`);
    expect(page.url()).toBe(`${ORIGIN}/login`);
    await expect(page.locator('h1')).toHaveText('Kernel Hive');

    // The signalling document is what a visitor needs to reach a tile at all.
    const signal = await page.request.get(`${ORIGIN}/signal/helenos.json`);
    expect(signal.status()).toBe(401);
  });

  test('the master token creates the first admin and signs them in', async () => {
    await page.goto(`${ORIGIN}/login`);
    await expect(page.locator('#name-field')).toBeVisible(); // bootstrap asks a name
    await page.fill('#code', TOKEN);
    await page.fill('#name', 'e2e admin');
    await page.click('#redeem');
    await page.waitForURL(`${ORIGIN}/`, { timeout: 30_000 });

    const state = await (await page.request.get(`${ORIGIN}/auth/state`)).json();
    expect(state.authenticated).toBe(true);
    expect(state.user.role).toBe('admin');
    expect(state.user.name).toBe('e2e admin');
    expect(state.needsBootstrap).toBe(false); // the window closed behind them
  });

  test('the spent token is refused a second time', async () => {
    await page.goto(`${ORIGIN}/login`);
    const res = await page.request.post(`${ORIGIN}/auth/redeem/begin`, {
      headers: { Origin: ORIGIN },
      data: { code: TOKEN, name: 'gatecrasher' },
    });
    expect(res.status()).toBe(403);
  });

  test('a signed-in visitor gets signalling that points at the relay, with a ticket', async () => {
    await page.goto(`${ORIGIN}/login`);
    const doc = await (await page.request.get(`${ORIGIN}/signal/helenos.json`)).json();
    expect(doc.host).toBe(new URL(ORIGIN).hostname);
    expect(doc.certHashB64).toBeTruthy();
    // The ticket streamhost checks before it accepts a WebTransport session.
    expect(doc.path).toMatch(/^\/wt\/\d+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  });

  test('signing out and back in with the passkey works', async () => {
    await page.goto(`${ORIGIN}/login`);
    await page.request.post(`${ORIGIN}/auth/logout`, { headers: { Origin: ORIGIN }, data: {} });
    await page.reload();

    // Same context, so the virtual authenticator still holds the credential.
    await expect(page.locator('#signin')).toBeVisible();
    await page.click('#signin');
    await page.waitForURL(`${ORIGIN}/`, { timeout: 30_000 });

    const state = await (await page.request.get(`${ORIGIN}/auth/state`)).json();
    expect(state.authenticated).toBe(true);
    expect(state.user.name).toBe('e2e admin');
  });

  test('an admin invites someone, and that code works exactly once', async ({ browser }) => {
    await page.goto(`${ORIGIN}/admin`);
    await page.fill('#inv-name', 'Invited Guest');
    await page.selectOption('#inv-role', 'viewer');
    await page.click('#invite');

    // toHaveText retries; innerText() alone would read the box before the
    // create call came back.
    await expect(page.locator('#issued-code')).toHaveText(/^[0-9A-Z]{5}-[0-9A-Z]{5}-[0-9A-Z]{5}$/);
    const code = (await page.locator('#issued-code').innerText()).trim();
    await expect(page.locator('#invites')).toContainText('Invited Guest');

    // A fresh context is a fresh device with its own authenticator.
    const guestCtx = await browser.newContext();
    const guest = await guestCtx.newPage();
    await guest.goto(`${ORIGIN}/login`);
    await virtualAuthenticator(guest);
    await guest.fill('#code', code);
    await guest.click('#redeem');
    await guest.waitForURL(`${ORIGIN}/`, { timeout: 30_000 });

    const state = await (await guest.request.get(`${ORIGIN}/auth/state`)).json();
    expect(state.user.role).toBe('viewer'); // the invite's role, not one they picked
    expect(state.user.name).toBe('Invited Guest');

    // A viewer must not reach the people surface...
    const denied = await guest.request.post(`${ORIGIN}/auth/people`, {
      headers: { Origin: ORIGIN },
      data: {},
    });
    expect(denied.status()).toBe(403);

    // ...and the invite is spent.
    const reused = await guest.request.post(`${ORIGIN}/auth/redeem/begin`, {
      headers: { Origin: ORIGIN },
      data: { code, name: 'second guest' },
    });
    expect(reused.status()).toBe(403);
    await guestCtx.close();
  });

  // The whole point of the exercise: a signed-in visitor on the public internet
  // can actually watch a machine. This is the only test that crosses the UDP
  // relay — browser -> edge (dnat) -> WireGuard -> the tile's QUIC listener —
  // and it is also the only one that proves the ticket is accepted rather than
  // merely well-formed.
  test('a signed-in visitor can open a stream through the public relay', async () => {
    await page.goto(`${ORIGIN}/login`);
    const result = await page.evaluate(async () => {
      const sig = await (await fetch('/signal/helenos.json', { cache: 'no-store' })).json();
      const hash = Uint8Array.from(atob(sig.certHashB64), (c) => c.charCodeAt(0));
      const url = `https://${sig.host}:${sig.udpPort}${sig.path}`;
      const wt = new WebTransport(url, {
        serverCertificateHashes: [{ algorithm: 'sha-256', value: hash.buffer }],
      });
      await wt.ready;

      // One access unit off the wire is enough: the session was accepted and
      // media is flowing back through the relay.
      const reader = wt.incomingUnidirectionalStreams.getReader();
      const timeout = new Promise((resolve) => setTimeout(() => resolve(null), 15000));
      const first = await Promise.race([reader.read(), timeout]);
      if (!first || first.done) return { url, bytes: 0 };
      const chunk = await first.value.getReader().read();
      wt.close();
      return { url, bytes: chunk.value ? chunk.value.byteLength : 0 };
    });

    expect(result.url).toContain(new URL(ORIGIN).hostname);
    expect(result.bytes).toBeGreaterThan(0);
  });

  // The point of linking: a second device ends up on the SAME account, with its
  // own passkey, rather than becoming a second person with the same name.
  test('a link QR puts another device on the same account', async ({ browser }) => {
    await page.goto(`${ORIGIN}/account`);
    const me = await (await page.request.get(`${ORIGIN}/auth/state`)).json();

    await page.click('#make-link');
    await expect(page.locator('#link-code')).toHaveText(/^[0-9A-Z]{5}-[0-9A-Z]{5}-[0-9A-Z]{5}$/);
    await expect(page.locator('#qr svg')).toBeVisible();
    await expect(page.locator('#countdown')).toContainText('Expires in');
    const code = (await page.locator('#link-code').innerText()).trim();

    // Device B: its own context, its own authenticator, no session — exactly
    // what a phone that scanned the QR arrives as. The code rides the fragment,
    // so this is the URL the QR encodes.
    const deviceB = await browser.newContext();
    const bPage = await deviceB.newPage();
    // Straight to the fragment URL, the way opening a scanned QR does. The
    // authenticator is attached after the load because it is only needed when
    // the button is pressed.
    await bPage.goto(`${ORIGIN}/link#${code.replace(/-/g, '')}`);
    await virtualAuthenticator(bPage);
    await expect(bPage.locator('#link')).toBeVisible();
    await bPage.click('#link');
    await bPage.waitForURL(`${ORIGIN}/`, { timeout: 30_000 });

    const bState = await (await bPage.request.get(`${ORIGIN}/auth/state`)).json();
    expect(bState.user.id).toBe(me.user.id); // the SAME account, not a new one
    expect(bState.user.name).toBe(me.user.name);
    expect(bState.user.role).toBe(me.user.role);

    // Device A now lists two passkeys, and the code is spent.
    const mine = await (await page.request.post(`${ORIGIN}/auth/me`, {
      headers: { Origin: ORIGIN }, data: {},
    })).json();
    expect(mine.passkeys.length).toBe(2);

    const replay = await bPage.request.post(`${ORIGIN}/auth/redeem/begin`, {
      headers: { Origin: ORIGIN },
      data: { code },
    });
    expect(replay.status()).toBe(403);
    await deviceB.close();
  });

  test('linking needs a session — a stranger cannot mint a code', async ({ browser }) => {
    const stranger = await browser.newContext();
    const sPage = await stranger.newPage();
    await sPage.goto(`${ORIGIN}/login`);
    const res = await sPage.request.post(`${ORIGIN}/auth/link/create`, {
      headers: { Origin: ORIGIN },
      data: {},
    });
    expect(res.status()).toBe(401);
    await stranger.close();
  });

  test('a cross-site POST is refused even carrying the session cookie', async () => {
    await page.goto(`${ORIGIN}/login`);
    const res = await page.request.post(`${ORIGIN}/auth/invites/create`, {
      headers: { Origin: 'https://evil.example' },
      data: { name: 'attacker', role: 'admin' },
    });
    expect(res.status()).toBe(403);
  });
});
