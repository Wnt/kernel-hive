import { describe, expect, it } from 'vitest';
import { showAdminNavFor } from './adminNavVisibility';

// The operator's ask: the admin nav (AdminNav.tsx, rendered on /admin/walkin
// and /admin/observability) must show for an admin session and MUST NOT
// appear for anybody else — a walk-in or an ordinary viewer must never see
// operator surfaces they cannot use.
describe('showAdminNavFor', () => {
  it('shows for an admin session', () => {
    expect(showAdminNavFor('admin')).toBe(true);
  });

  it('is hidden for every non-admin role', () => {
    expect(showAdminNavFor('viewer')).toBe(false);
    expect(showAdminNavFor('walkin')).toBe(false);
    expect(showAdminNavFor('anon')).toBe(false);
  });
});
