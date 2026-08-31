import type { Session } from '../data/session';

/** The admin nav (AdminNav.tsx) is the role fence made visible, same as the
 *  gallery/walk-in split in App.tsx's TopBar: it renders for an admin session
 *  ONLY, and grants nothing — the server-side gate is the actual authority,
 *  whatever this renders. Pulled out as its own pure predicate so the gate
 *  logic is testable under plain node (spa/vitest.config.ts runs no DOM), the
 *  same split session.ts uses for `walkinShape`. */
export function showAdminNavFor(role: Session['role']): boolean {
  return role === 'admin';
}
