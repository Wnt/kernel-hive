import { describe, expect, it } from 'vitest';
import { showsLandingHero } from './heroAudience';

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
