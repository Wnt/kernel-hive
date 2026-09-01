// FIRST, before anything else in this module runs: patch window.fetch so
// every same-origin request this app makes — 22 of the 24 call sites that
// exist today carried no trace context before this landed — automatically
// propagates `traceparent`, and join the page-load trace the server named in
// <meta name="traceparent"> (docs/lab/TRACE-CONTEXT.md §4/§7) before the
// first flow (station.connect, typically) opens and would otherwise mint an
// unrelated id. See analytics/khFetch.ts's header for why this install point
// — as early in OUR OWN bundle as we control — is a deliberate best-effort
// rather than a hard guarantee against Instana's separately-loaded agent.
import { installKhFetchPropagation } from './analytics/khFetch';
import { joinPageLoadTraceFromMeta } from './analytics/pageLoadJoin';

installKhFetchPropagation();
joinPageLoadTraceFromMeta();

import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import App from './App';
import { loadSession, type Session } from './data/session';
import { isWalkinPath, walkinShape } from './walkin/route';
import { SessionProvider } from './data/SessionContext';
import { exposePointerRecorder, installPointerRecorder } from './input/pointerRecorder';
import { exposeKeyRecorder } from './input/keyRecorder';
import { clientSessionId, initClientDebug, setTelemetryAllowed } from './three/clientDebug';
import { initAnalytics, reportError } from './analytics';
import { BUILD_ID } from './analytics/build';
import { configureInstana, configureInstanaIdentity } from './analytics/instana';
import './index.css';

type ErrorReporterInput = {
  event: 'react-error';
  message: string;
  stack: string;
  source: string;
  componentStack: string;
};

declare global {
  interface Window {
    __kernelHiveErrorSessionId?: string;
    __kernelHiveReportError?: (input: ErrorReporterInput) => void;
  }
}

type ErrorBoundaryState = { error: Error | null };

function asError(value: unknown): Error {
  if (value instanceof Error) return value;
  try {
    return new Error(String(value));
  } catch {
    return new Error('Unknown render error');
  }
}

class ErrorBoundary extends React.Component<React.PropsWithChildren, ErrorBoundaryState> {
  state: ErrorBoundaryState = { error: null };

  static getDerivedStateFromError(error: unknown): ErrorBoundaryState {
    return { error: asError(error) };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    try {
      const input: ErrorReporterInput = {
        event: 'react-error',
        message: error.message || 'Unknown render error',
        stack: error.stack || '',
        source: 'react',
        componentStack: info.componentStack || '',
      };
      // BOTH lanes, deliberately. /clientlog keeps the stack and the component
      // stack so one broken session can be read; this keeps the fingerprinted
      // COUNT so a fault that happens four hundred times is one row that says
      // so. The fingerprint is printed into neither by accident — it is how an
      // operator gets from the top row of the report back to a real stack.
      reportError({
        message: input.message,
        source: 'react',
        stack: input.stack,
        componentStack: input.componentStack,
      });
      if (window.__kernelHiveReportError) {
        window.__kernelHiveReportError(input);
      } else {
        void fetch('/clientlog', {
          method: 'POST',
          keepalive: true,
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            ...input,
            href: location.href,
            ua: navigator.userAgent,
            clientTs: Date.now(),
            sessionId: window.__kernelHiveErrorSessionId || 'unknown',
            // Same reason the inline reporter in index.html carries it: a
            // client error is only actionable once you know which build threw.
            build: BUILD_ID,
          }),
        }).catch(() => {});
      }
    } catch {
      // Diagnostics must not interfere with the visible fallback.
    }
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <main className="fatal-error" role="alert">
        <section className="fatal-error-card">
          <h1>The gallery failed to load.</h1>
          <p>Something went wrong while drawing this page.</p>
          <pre>{this.state.error.message}</pre>
          <button type="button" onClick={() => location.reload()}>Reload</button>
        </section>
      </main>
    );
  }
}

// Raw pointer capture for input debugging — listeners installed here so they see
// events in the capture phase before any component mounts, but INERT until armed
// (`?penrec=1`, or `window.__osgPenRec = true` in a running tab). It lives in the
// bundle rather than being injected through the operator eval plane because a
// client-side input fix requires a reload to test, and an injected recorder dies
// on exactly that reload — costing a re-arm round trip per iteration.
installPointerRecorder();
exposePointerRecorder();
// Key-edge capture for the keyboard-lag investigation: no listeners to install
// (it records at the wire choke point inside streamClient), only the operator
// plane readers to expose. Armed by default — see input/keyRecorder.ts.
exposeKeyRecorder();

// Telemetry + operator reachability for this TAB, before React mounts and
// before any station is chosen. Deliberately first: a session that fails —
// manifests that never load, a station that never connects, a visitor sitting
// on a blank grid — is the session whose telemetry matters most, and it used
// to produce nothing at all because every log call hung off a stream that had
// already failed to start. This also starts the /clientcmd poller, so every
// tab is reachable for debugging, not just one with a working station open.
// …but NOT for a walk-in visitor: the operator poller is a gallery surface a
// walk-in is fenced out of, and a walk-in has no operator to be reached by.

// The session is resolved BEFORE the first render, and the whole app hangs off
// the answer. Waiting costs one cheap same-origin request; not waiting is what
// the old path-based split cost instead — a walk-in at `/` booting the gallery
// and firing a fleet manifest fetch their own gate refuses. Nothing renders
// against an unknown role, so no view has to carry a "role not known yet" case.
function mount(session: Session) {
  // Two different questions, and conflating them is what the old path test did.
  //
  // TELEMETRY (/clientlog) is allowed to any SESSION, walk-in accounts included
  // — gate.py puts it in WALKIN_PATHS so a stranger's broken stream is still
  // debuggable. It is also open on the ungated LAN listener and on a staging
  // preview, where the role reads `anon` because there is no auth plane to ask;
  // silencing those would take telemetry away from the two places the lab
  // actually debugs from. The ONE caller that must stay quiet is the signed-out
  // stranger on the /walkin signup door: they have no session, so every flush
  // would 401 every 5s and be re-queued forever.
  const signedOutAtTheDoor = session.role === 'anon'
    && isWalkinPath(window.location.pathname, import.meta.env.BASE_URL);
  setTelemetryAllowed(!signedOutAtTheDoor);
  // The feature-reach plane rides the SAME answer, not a second policy: it is
  // the identical question (may this tab talk to the box at all), and two
  // separate gates would drift the first time one of them was tightened.
  // A walk-in signed IN is deliberately included — the walk-in plane is a whole
  // surface built for strangers, and leaving it out would make it look unused.
  initAnalytics({
    // clientDebug's id, not a second one: /clientlog stamps this same value on
    // every raw event, so a trace and the event tail behind it join on it.
    sessionId: clientSessionId(),
    allowed: !signedOutAtTheDoor,
    // WHO, when there is a who. The gallery has named invited accounts and
    // pseudonymous walk-in handles, and both are wanted on the trace —
    // "which account hit this" is the first question a report opens with.
    // Omitted entirely for `anon`, which is a UI shape and not a person.
    user: session.role === 'anon' || !session.id ? undefined : session,
  });
  // Instana EUM (analytics/instana.ts) rides the SAME session id and the SAME
  // `allowed` gate as the plane above — a build with no website key configured
  // makes every call inside a no-op regardless, but a signed-out stranger at
  // the walk-in door must never be handed to Instana just because their build
  // happens to be configured. configureInstana sets the pseudonymous identity;
  // configureInstanaIdentity immediately upgrades it to the real account when
  // one exists (see that function's header for why both calls are needed and
  // why nothing here calls `ineum('terminateSession')`).
  if (!signedOutAtTheDoor) {
    configureInstana(clientSessionId());
    configureInstanaIdentity(session);
  }
  if (!walkinShape(session.role, window.location.pathname, import.meta.env.BASE_URL)) {
    initClientDebug();
  }

  ReactDOM.createRoot(document.getElementById('root')!).render(
    <React.StrictMode>
      <ErrorBoundary>
        {/* The router base must agree with the VITE base the bundle was built
            with. Without this a stage.sh preview served under /staging/<name>/
            treats its own path as an unknown route and redirects to '/', which
            silently loads the PRODUCTION bundle instead — so every staged
            preview of anything that routes was really testing live. BASE_URL is
            '/' for a normal build, leaving production behaviour unchanged. */}
        <BrowserRouter basename={import.meta.env.BASE_URL}>
          <SessionProvider value={session}>
            {/* ONE app for both visitor classes. App reads the role and
                renders the lineup, the navigation and the card targets the
                session is allowed to have — see App.tsx. */}
            <App />
          </SessionProvider>
        </BrowserRouter>
      </ErrorBoundary>
    </React.StrictMode>,
  );
}

void loadSession().then(mount);

// Register the PWA service worker (public/sw.js) so the gallery is installable
// as a standalone app. Only in a production build, and never from a /staging/
// preview — a staging page shares the live origin and must not plant a
// root-scoped worker on it. Deferred to load so it never competes with the
// first paint or the stream handshake; failure is silent (an uninstalled app is
// a fine fallback). See sw.js for the deliberately network-first, no-app-cache
// policy that keeps a box deploy visible on the next load.
//
// THE `?build=` IS LOAD-BEARING, not a cache-buster habit. The worker names its
// shell cache after it, so a new bundle means a new script URL, which means a
// new worker, whose activate deletes every earlier shell — including the
// `kh-shell-v1` entry a client installed months ago and could otherwise keep
// serving itself an old HTML shell from forever. The scope is unaffected: a
// registration's scope comes from the script's PATH, and the query string is
// not part of it. sw.js has the whole story.
if (
  'serviceWorker' in navigator
  && import.meta.env.PROD
  && !window.location.pathname.startsWith('/staging/')
) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register(`/sw.js?build=${encodeURIComponent(BUILD_ID)}`).catch(() => {});
  });
}
