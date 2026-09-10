import { describe, expect, it } from 'vitest';
import { showsLandingHero, walkinPlaneAvailable } from './heroAudience';

// The regression this file guards: after the landing redesign, an invited
// visitor (admin/viewer) and a signed-up walk-in were shown the
// anonymous-stranger conversion hero at `/` — the walk-in "upper section",
// countdown included — when only role 'anon' should ever see it.

describe('showsLandingHero', () => {
  it('shows the hero to a stranger the server does not vouch for', () => {
    expect(showsLandingHero('anon')).toBe(true);
  });

  it('does not show the hero to an admin', () => {
    expect(showsLandingHero('admin')).toBe(false);
  });

  it('does not show the hero to a viewer', () => {
    expect(showsLandingHero('viewer')).toBe(false);
  });

  it('does not show the hero to a signed-up walk-in', () => {
    expect(showsLandingHero('walkin')).toBe(false);
  });
});

// The second regression this file guards: role 'anon' also covers a LAN
// visitor, where the walk-in broker does not exist at all — so a hero that
// answers on role alone renders a machine nobody can ever claim (POST
// /walkin/claim 404s the instant it is pressed). These pin walkinPlaneAvailable
// against exactly the response shapes measured on the deployed build: real
// JSON from the public listener, and the SPA's own HTML shell / a 404 / a
// dead network on the LAN.
function fakeFetch(status: number, contentType: string | null): typeof fetch {
  return (async () => ({
    ok: status >= 200 && status < 300,
    headers: { get: (name: string) => (name.toLowerCase() === 'content-type' ? contentType : null) },
  })) as unknown as typeof fetch;
}

describe('walkinPlaneAvailable', () => {
  it('is true for a real JSON answer from the broker', async () => {
    expect(await walkinPlaneAvailable(fakeFetch(200, 'application/json'))).toBe(true);
    // A charset parameter must not break the match.
    expect(await walkinPlaneAvailable(fakeFetch(200, 'application/json; charset=utf-8'))).toBe(true);
  });

  it('is false for the SPA history fallback answering instead of a broker — the LAN measurement', async () => {
    expect(await walkinPlaneAvailable(fakeFetch(200, 'text/html'))).toBe(false);
  });

  it('is false for an outright 404', async () => {
    expect(await walkinPlaneAvailable(fakeFetch(404, 'application/json'))).toBe(false);
  });

  it('is false when the fetch itself throws', async () => {
    const boom = (async () => { throw new Error('network down'); }) as unknown as typeof fetch;
    expect(await walkinPlaneAvailable(boom)).toBe(false);
  });
});
