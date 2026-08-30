import { NavLink } from 'react-router-dom';
import { MUSEUM_NAME } from '../config';
import './walkin.css';

// The page chrome for the SIGNED-OUT walk-in door: /walkin, where a stranger
// with no account reads what they are being offered and makes a passkey.
//
// It is deliberately not the chrome a signed-up walk-in gets. Once the visitor
// HAS an account they are in the museum proper — the same grid, the same
// placards, the same app bar as any other visitor, narrowed to what their role
// may see (App.tsx). This shell exists only for the moment before that, which
// is the one moment there is no role to render from.

export function WalkinChrome({ children }: { children: React.ReactNode }) {
  return (
    <div className="walkin-root">
      <div className="walkin-page">
        <header className="walkin-bar">
          <h1>{MUSEUM_NAME}</h1>
          <span className="walkin-bar-tag">a working computer museum you can drive</span>
          <nav className="walkin-bar-links">
            <NavLink to="/walkin" end className={({ isActive }) => (isActive ? 'active' : '')}>Play</NavLink>
            <NavLink to="/walkin/exhibits" className={({ isActive }) => (isActive ? 'active' : '')}>Exhibits</NavLink>
          </nav>
        </header>
        {children}
        <footer className="walkin-foot">
          Every machine here is a real operating system running on real emulated hardware in one
          rack. Something wrong, or something you would like to see? Write to the address on the
          museum&rsquo;s About page.
        </footer>
      </div>
    </div>
  );
}
