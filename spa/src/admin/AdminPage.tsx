import { WalkinAdminPanel } from './WalkinAdminPanel';
import { AdminNav } from './AdminNav';
import './AdminPage.css';

// /admin/walkin — operator surface, SPA half (CONTRACT-LEDGER.md §7). The
// people/passkey management page (invite, promote, remove, usage scoreboard)
// stays where it is, at the server-rendered scripts/serve/authui/admin.html,
// reached at the literal /admin (config.py's AUTH_PAGES claims that exact
// path). This page is additive, one path down: the walk-in switch, live
// state, drain and purge (WALKIN-BRIEF.md §5.1).
//
// html/body/#root are overflow:hidden (index.css, for the grid + 3D museum's
// full-viewport canvases), so this view owns its own scroll container —
// .admin-page-scroll is the scroller, .admin-page is the centred content
// block. min-height+overflow:auto on one element (the old shape here) cannot
// actually scroll: the element just grows with its content instead of being
// constrained, so overflow never engages. See About.tsx/.about-view for the
// same split, used for the same reason.
export function AdminPage() {
  return (
    <div className="admin-page-scroll">
      <AdminNav />
      <div className="admin-page">
        <header className="admin-page-head">
          <h1>Walk-in access</h1>
          <p className="admin-page-sub">
            Operator control for the public walk-in plane. <a href="/admin">People &amp; passkeys</a> is the
            separate invited-plane admin page.
          </p>
        </header>
        <WalkinAdminPanel />
      </div>
    </div>
  );
}
