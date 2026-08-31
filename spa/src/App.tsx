import { useCallback, useEffect, useRef, useState } from 'react';
import { Routes, Route, Navigate, NavLink, useLocation, useParams, useNavigate } from 'react-router-dom';
import SceneV2 from './scene/SceneV2';
import GridView from './ui/grid/GridView';
import StreamView from './ui/grid/StreamView';
import ExhibitPoster from './ui/ExhibitPoster';
import { FleetTable } from './ui/FleetTable';
import { About } from './ui/About';
import { AdminPage } from './admin/AdminPage';
import { ObservabilityPage } from './admin/observability/ObservabilityPage';
import { useManifest } from './data/useManifest';
import { useSession } from './data/SessionContext';
import WalkinLanding from './walkin/WalkinLanding';
import WalkinPlay from './walkin/WalkinPlay';
import WalkinExhibits from './walkin/WalkinExhibits';
import { WalkinChrome } from './walkin/WalkinChrome';
import { useMuseum } from './state/store';
import { bindingFromManifest, type OSBinding } from './three/archetypeRegistry';
import { MUSEUM_NAME, MUSEUM_TAGLINES } from './config';

// Dev-only: expose the store so headless verification can read hover/select state.
if (import.meta.env.DEV) (window as any).__museum = useMuseum;

export default function App() {
  useManifest();

  const { role } = useSession();
  const walkin = role === 'walkin';

  const vms = useMuseum((s) => s.vms);

  const [posterId, setPosterId] = useState<string | null>(null);

  // The exhibit-info modal is opened from within the station's /os/:osId stream
  // route. It has no route of its own, so nothing closes it automatically —
  // without this it stays open (overlaying the grid) after navigating back
  // out of the view that opened it.
  const location = useLocation();
  const prevPathnameRef = useRef(location.pathname);
  useEffect(() => {
    if (prevPathnameRef.current !== location.pathname) {
      prevPathnameRef.current = location.pathname;
      setPosterId(null);
    }
  }, [location.pathname]);

  const posterVm = vms.find((v) => v.id === posterId) ?? null;
  const openPoster = useCallback((osId: string) => setPosterId(osId), []);

  const appRootRef = useRef<HTMLDivElement>(null);

  // NOTE: the opened grid stream owns Escape itself (StreamView forwards it to
  // the guest). App-level Esc handling here would steal Escape from the guest, so
  // there is deliberately none.

  // ---- shared top bar: title + Grid/3D toggle + app-level Fullscreen ----
  const TopBar = (
    <header className="appbar">
      <div className="appbar-brand">
        <h1>{MUSEUM_NAME}</h1>
        <span className="appbar-tag" aria-hidden="true">
          {MUSEUM_TAGLINES.map((tagline) => (
            <span key={tagline} className="appbar-tag-item">{tagline}</span>
          ))}
        </span>
      </div>
      <div className="appbar-actions">
        {/* The navigation is the role fence made visible. A walk-in is refused
            /museum, /fleet and /about at the gate (gate.py WALKIN_PATHS), and a
            link that 302s the visitor back to where they started teaches them
            the site is broken. So they get the two surfaces they DO have —
            which the grid's own scope switch already spans — and the operator
            keeps the four they have always had. Nothing here grants access;
            the gate does that, whatever this renders. */}
        <div className="seg appbar-seg">
          <NavLink to="/" end className={({ isActive }) => (isActive ? 'active' : '')}>
            {walkin ? 'Machines' : 'Grid'}
          </NavLink>
          {!walkin && (
            <>
              <NavLink to="/museum" className={({ isActive }) => (isActive ? 'active' : '')}>3D Museum (early access)</NavLink>
              <NavLink to="/fleet" className={({ isActive }) => (isActive ? 'active' : '')}>Fleet table</NavLink>
              <NavLink to="/about" className={({ isActive }) => (isActive ? 'active' : '')}>About</NavLink>
            </>
          )}
          {walkin && (
            <NavLink to="/walkin/exhibits" className={({ isActive }) => (isActive ? 'active' : '')}>Exhibits</NavLink>
          )}
        </div>
      </div>
    </header>
  );

  return (
    <div className="app-root" ref={appRootRef}>
      <Routes>
        {/* ---------- DEFAULT: 2D grid ---------- */}
        <Route
          path="/"
          element={<>{TopBar}<GridView onOpenPlacard={openPoster} /></>}
        />

        {/* ---------- Full-viewport live stream of one station (deep-linkable) ---------- */}
        {/* A walk-in never streams a museum STATION — their live surface is
            their own clone at /walkin/play/<os>, and /signal/<station>.json is
            refused to them at the gate. Sending them to their own grid beats
            mounting a stream that can only fail to connect. */}
        <Route
          path="/os/:osId"
          element={
            walkin
              ? <Navigate to="/" replace />
              : <OsStreamRoute onOpenPoster={openPoster} posterOpen={posterId !== null} />
          }
        />

        {/* ---------- operator fleet table: tier / emulator / kiosk / I/O paths per station ---------- */}
        <Route path="/fleet" element={<>{TopBar}<FleetTable /></>} />

        {/* ---------- about the project + generated weekly release notes ---------- */}
        <Route path="/about" element={<>{TopBar}<About /></>} />

        {/* ---------- operator: walk-in access panel (CONTRACT-LEDGER.md §7) ----------
            /admin itself is claimed by config.py's AUTH_PAGES (exact-match lookup
            in static_files.py) for the static people/passkeys page, which stays as
            is. The walk-in panel lives one path down, at /admin/walkin, which falls
            through to the SPA untouched — see spa/src/admin/AdminPage.tsx. */}
        <Route path="/admin/walkin" element={<AdminPage />} />
        <Route path="/admin/observability" element={<ObservabilityPage />} />

        {/* ---------- 3D museum ---------- */}
        <Route path="/museum" element={<SceneV2 />} />
        <Route path="/museum2" element={<MuseumRedirect />} />

        {/* ---------- the walk-in surfaces, in the SAME router ----------
            They used to be a second app booted by main.tsx from the path
            alone, which is what left a signed-up walk-in stranded on the root
            URL. One router, one grid, one placard; the role decides what is in
            them.

            `/walkin` is the DOOR, and it means two different things by role.
            A stranger with no account gets the landing page — what they are
            being offered, live pool counts, and one tap to make a passkey. A
            visitor who already HAS a walk-in account has walked through it
            already, so they are sent to the museum proper, where their own
            machines are the grid's default scope.

            `/walkin/exhibits` is kept — it is a published path and the walk-in
            landing links to it — but for an ACCOUNT it is now just the grid at
            its wider scope, not a separate listing to maintain. */}
        <Route
          path="/walkin"
          element={walkin ? <Navigate to="/" replace /> : <WalkinChrome><WalkinLanding /></WalkinChrome>}
        />
        <Route
          path="/walkin/exhibits"
          element={
            walkin
              ? <>{TopBar}<GridView initialScope="all" onOpenPlacard={openPoster} /></>
              : <WalkinChrome><WalkinExhibits /></WalkinChrome>
          }
        />
        <Route path="/walkin/play/:os" element={<div className="walkin-root"><WalkinPlay /></div>} />

        {/* ---------- unknown path → grid ---------- */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>

      {posterId && posterVm && (
        <ExhibitPoster osId={posterId} vm={posterVm} onClose={() => setPosterId(null)} />
      )}
    </div>
  );
}

function MuseumRedirect() {
  const { search } = useLocation();
  return <Navigate to={{ pathname: '/museum', search }} replace />;
}

// Full-viewport live stream of a single station, deep-linked at /os/:osId. StreamView
// auto-connects on mount (useLiveStream starts whenever streamable), so loading
// /os/<id> directly powers on + streams that station with no extra side-effect.
function OsStreamRoute({
  onOpenPoster,
  posterOpen,
}: {
  onOpenPoster: (osId: string) => void;
  posterOpen: boolean;
}) {
  const { osId } = useParams();
  const navigate = useNavigate();
  const location = useLocation();
  const vms = useMuseum((s) => s.vms);
  const vm = vms.find((entry) => entry.id === osId);
  if (vms.length === 0) return <div className="grid-empty">Loading the collection…</div>;
  if (!vm) return <Navigate to="/" replace />; // unknown / missing osId → grid
  const binding = bindingFromManifest(vm);
  return (
    <OsStreamSession
      key={`${location.key}:${osId}`}               // snapshot state once per history entry
      os={binding}
      onExit={() => {
        if (
          typeof location.state === 'object'
          && location.state !== null
          && (location.state as { fromMuseum?: boolean }).fromMuseum
        ) {
          navigate(-1);
        } else {
          navigate({ pathname: '/', search: location.search });
        }
      }}
      onOpenPoster={() => onOpenPoster(vm.id)}
      posterOpen={posterOpen}
    />
  );
}

// Browser history entries survive a document reload, unlike React component
// state. Snapshot whether THIS entry was already opened before marking it: the
// initial visit must still play the boot clip, while a reload (or forward-nav
// back to the same entry) should connect straight to the live station. Keeping the
// marker alongside React Router's own history fields keeps the decision scoped
// to this navigation entry. A per-OS session mirror below covers engines that
// restore history state late; a genuinely first visit still gets the boot.
const BOOT_VIDEO_HISTORY_KEY = 'kernelHive.bootVideoPlayedFor';
const BOOT_VIDEO_SESSION_PREFIX = 'kernelHive.bootVideoPlayed:';

function bootVideoPlayedFor(osId: string): boolean {
  const state = window.history.state;
  const historyPlayed = typeof state === 'object'
    && state !== null
    && state[BOOT_VIDEO_HISTORY_KEY] === osId;
  if (historyPlayed) return true;

  // Firefox exposes a restored history.state slightly after the app's first
  // render during reload. Keep a per-OS session mirror so that engine can make
  // the decision synchronously; a new tab/session still gets its first boot.
  try { return window.sessionStorage.getItem(`${BOOT_VIDEO_SESSION_PREFIX}${osId}`) === '1'; }
  catch { return false; }
}

function markBootVideoPlayed(osId: string): void {
  const state = window.history.state;
  const routerState = typeof state === 'object' && state !== null ? state : {};
  window.history.replaceState(
    { ...routerState, [BOOT_VIDEO_HISTORY_KEY]: osId },
    '',
  );
  try { window.sessionStorage.setItem(`${BOOT_VIDEO_SESSION_PREFIX}${osId}`, '1'); }
  catch { /* storage blocked — history state remains the primary marker */ }
}

function OsStreamSession({
  os,
  onExit,
  onOpenPoster,
  posterOpen,
}: {
  os: OSBinding;
  onExit: () => void;
  onOpenPoster: () => void;
  posterOpen: boolean;
}) {
  // The lazy initializer is deliberately stable across later App/store renders.
  // On the first mount it reads false, then the effect marks the current entry;
  // after a hard reload the new document reads true from that same entry.
  const [bootVideoPlayed, setBootVideoPlayed] = useState(() => bootVideoPlayedFor(os.osId));
  const markedByThisMount = useRef(false);

  useEffect(() => {
    if (!os.bootVideo || bootVideoPlayed) return;

    // Firefox can restore history.state just after the first render on reload.
    // Re-read it in the effect, but don't mistake the marker this mount wrote
    // for a prior visit when React StrictMode intentionally re-runs effects.
    if (bootVideoPlayedFor(os.osId)) {
      if (!markedByThisMount.current) setBootVideoPlayed(true);
      return;
    }

    markBootVideoPlayed(os.osId);
    markedByThisMount.current = true;
  }, [bootVideoPlayed, os.bootVideo, os.osId]);

  return (
    <StreamView
      os={os}
      onExit={onExit}
      playBootVideo={!bootVideoPlayed}
      onOpenPoster={onOpenPoster}
      posterOpen={posterOpen}
    />
  );
}
