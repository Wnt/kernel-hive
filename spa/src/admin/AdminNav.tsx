import { NavLink } from 'react-router-dom';
import { useSession } from '../data/SessionContext';
import { showAdminNavFor } from './adminNavVisibility';
import './AdminNav.css';

// The admin-level nav the operator asked for: the three admin surfaces are in
// TWO systems (a static server-rendered page at /admin, and two SPA routes —
// see App.tsx's comment on the split) and none of them linked to the others.
// This bar is the fix, mounted at the top of each SPA admin page's own scroll
// container. It renders for role === 'admin' ONLY — the same Session/role
// check the rest of the app already uses (SessionContext.useSession,
// walkin/sessionEnd.ts's accessAllows) — and nothing here grants access: the
// server-side gate does that regardless of what this renders, exactly like
// the walk-in/gallery nav split in App.tsx's TopBar.
//
// /admin itself is a plain <a>, not a <NavLink>: it is not a React Router
// route (config.py's AUTH_PAGES claims that literal path for the static
// people/passkeys page), so a client-side route match would never be "active"
// there and a full navigation is the correct way to reach it anyway.
const ADMIN_LINKS: Array<{ to: string; label: string }> = [
  { to: '/admin/walkin', label: 'Walk-in' },
  { to: '/admin/observability', label: 'Observability' },
];

export function AdminNav() {
  const { role } = useSession();
  if (!showAdminNavFor(role)) return null;
  return (
    <nav className="admin-nav" aria-label="Admin views">
      <a className="admin-nav-link" href="/admin">People &amp; passkeys</a>
      {ADMIN_LINKS.map((link) => (
        <NavLink
          key={link.to}
          to={link.to}
          className={({ isActive }) => `admin-nav-link${isActive ? ' active' : ''}`}
        >
          {link.label}
        </NavLink>
      ))}
    </nav>
  );
}
