import { Navigate, Route, Routes, NavLink } from 'react-router-dom';
import WalkinLanding from './WalkinLanding';
import WalkinPlay from './WalkinPlay';
import WalkinExhibits from './WalkinExhibits';
import { MUSEUM_NAME } from '../config';
import './walkin.css';

// The walk-in shell: /walkin, /walkin/exhibits and /walkin/play/<os> (§7).
//
// The play route deliberately renders OUTSIDE this page chrome — the station
// view is full-viewport, with its own bar — so the shell here wraps only the
// two reading surfaces.

function Chrome({ children }: { children: React.ReactNode }) {
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

export default function WalkinApp() {
  // Mounted at the ROUTER ROOT by main.tsx (not nested under a gallery
  // route), so these paths are the full walk-in paths. A staged bundle’s
  // basename is stripped before matching, so /staging/<name>/walkin matches
  // /walkin here exactly as production does.
  return (
    <Routes>
      <Route path="/walkin" element={<Chrome><WalkinLanding /></Chrome>} />
      <Route path="/walkin/exhibits" element={<Chrome><WalkinExhibits /></Chrome>} />
      <Route path="/walkin/play/:os" element={<div className="walkin-root"><WalkinPlay /></div>} />
      <Route path="*" element={<Navigate to="/walkin" replace />} />
    </Routes>
  );
}
