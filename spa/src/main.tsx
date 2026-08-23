import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import App from './App';
import { exposePointerRecorder, installPointerRecorder } from './input/pointerRecorder';
import { exposeKeyRecorder } from './input/keyRecorder';
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
        <App />
      </BrowserRouter>
    </ErrorBoundary>
  </React.StrictMode>,
);

// Register the PWA service worker (public/sw.js) so the gallery is installable
// as a standalone app. Only in a production build, and never from a /staging/
// preview — a staging page shares the live origin and must not plant a
// root-scoped worker on it. Deferred to load so it never competes with the
// first paint or the stream handshake; failure is silent (an uninstalled app is
// a fine fallback). See sw.js for the deliberately network-first, no-app-cache
// policy that keeps a box deploy visible on the next load.
if (
  'serviceWorker' in navigator
  && import.meta.env.PROD
  && !window.location.pathname.startsWith('/staging/')
) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  });
}
