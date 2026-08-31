// lib/webauthn.mjs — the same CDP virtual authenticator
// tests/e2e-live/e2e/publicAuth.spec.ts uses to exercise the passkey ceremony
// for real: a genuine WebAuthn credential, real origin binding, real
// signature verification by fido2 on the box. Not a stub of the ceremony —
// the walk-in journey below performs the actual `/walkin/signup` round trip.
//
// Chromium-only (CDP's WebAuthn domain), which is fine: this tool always
// launches chromium (see visitor-sim.mjs).

/** Arm a resident-key, auto-presenting virtual authenticator on `page`'s CDP
 *  session — call this BEFORE any `navigator.credentials.create()` the page
 *  will run (i.e. before clicking the walk-in signup button). */
export async function armVirtualAuthenticator(page) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('WebAuthn.enable');
  await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true, // discoverable, matching the walk-in ceremony
      hasUserVerification: true,
      isUserVerified: true, // no biometric prompt to click through
      automaticPresenceSimulation: true,
    },
  });
}
