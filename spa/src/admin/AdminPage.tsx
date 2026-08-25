import { WalkinAdminPanel } from './WalkinAdminPanel';
import './AdminPage.css';

// /admin/walkin — operator surface, SPA half (CONTRACT-LEDGER.md §7). The
// people/passkey management page (invite, promote, remove, usage scoreboard)
// stays where it is, at the server-rendered scripts/serve/authui/admin.html,
// reached at the literal /admin (config.py's AUTH_PAGES claims that exact
// path). This page is additive, one path down: the walk-in switch, live
// state, drain and purge (WALKIN-BRIEF.md §5.1).
export function AdminPage() {
  return (
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
  );
}
