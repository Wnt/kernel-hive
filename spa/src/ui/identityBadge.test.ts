import { describe, expect, it } from 'vitest';
import { identityBadgeText } from './identityBadge';

// The operator's report: a walk-in signs up, gets a handle like `tidy-noyce`,
// and then never sees it again anywhere in the UI. This is the text that
// fixes that — IdentityBadge.tsx just renders whatever this returns.
describe('identityBadgeText', () => {
  it('shows the handle for a walk-in, with a short hint of what it is', () => {
    expect(identityBadgeText({ role: 'walkin', name: 'tidy-noyce' })).toBe(
      "signed in as tidy-noyce — that's your handle here",
    );
  });

  it('shows the plain form for viewer and admin', () => {
    expect(identityBadgeText({ role: 'viewer', name: 'jonni' })).toBe('signed in as jonni');
    expect(identityBadgeText({ role: 'admin', name: 'jonni' })).toBe('signed in as jonni');
  });

  it('shows nothing for anon', () => {
    expect(identityBadgeText({ role: 'anon', name: '' })).toBeNull();
  });

  it('shows nothing when the account has no name, whatever the role', () => {
    expect(identityBadgeText({ role: 'viewer', name: '' })).toBeNull();
  });
});
