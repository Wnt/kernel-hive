import { useState } from 'react';
import { supportsPasskeys, walkinSignup } from '../../walkin/passkey';

// ============================================================================
//  landing/gate — THE CONVERSION GATE, AS A PLACEHOLDER.
//  ---------------------------------------------------------------------------
//  ⚠ THIS FILE IS A STUB AND IS MEANT TO BE DELETED.
//
//  The countdown and the wall are a PARALLEL STREAM's work. Their branch had
//  not landed when the landing page was built (checked 2026-09-10: no remote
//  branch carried `spa/src/landing/gate`), and the page cannot be assembled
//  against an import that does not resolve. So this stands in, exporting
//  exactly the two signatures the landing brief froze and nothing else:
//
//    Countdown({ remainingSeconds, budgetSeconds })
//    ConversionGate({ remainingSeconds, budgetSeconds, expired, stationTitle,
//                     onRegistered, onSignedIn })
//
//  INTEGRATOR: when the gate stream lands, delete this file and take theirs.
//  Nothing outside `landing/LandingTop.tsx` imports either symbol, the props
//  are passed by name, and the two `.landing-gate*` / `.landing-countdown*`
//  rule blocks in landing.css go with it if their components bring their own.
//
//  It is deliberately the smallest thing that is not a dead end: the wall runs
//  the EXISTING one-tap ceremony (walkin/passkey.ts `walkinSignup`, already
//  shipped and already the door's signup path) and points "Sign in" at the
//  gallery's existing login page. The real component owns the discoverable
//  `navigator.credentials.get()` half; a stub that had no way through at all
//  would make the whole page untestable by eye.
// ============================================================================

function clock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  return `0:${String(total % 60).padStart(2, '0')}`;
}

export function Countdown({
  remainingSeconds,
  budgetSeconds,
}: {
  remainingSeconds: number;
  budgetSeconds: number;
}): React.JSX.Element {
  const fraction = budgetSeconds > 0 ? Math.max(0, Math.min(1, remainingSeconds / budgetSeconds)) : 0;
  const low = remainingSeconds <= 15;
  return (
    <span className={`landing-countdown${low ? ' landing-countdown--low' : ''}`} role="timer">
      <span className="landing-countdown__bar" aria-hidden="true">
        <span className="landing-countdown__fill" style={{ transform: `scaleX(${fraction})` }} />
      </span>
      <span className="landing-countdown__value">{clock(remainingSeconds)}</span>
      <span className="landing-countdown__unit">left</span>
    </span>
  );
}

export function ConversionGate({
  remainingSeconds,
  budgetSeconds,
  expired,
  stationTitle,
  onRegistered,
  onSignedIn,
}: {
  remainingSeconds: number;
  budgetSeconds: number;
  expired: boolean;
  stationTitle: string;
  onRegistered: (handle: string) => void;
  onSignedIn: () => void;
}): React.JSX.Element | null {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!expired) return null;

  const enrol = async () => {
    setBusy(true);
    setError(null);
    try {
      const who = await walkinSignup();
      onRegistered(who.handle);
    } catch (reason) {
      const message = reason instanceof Error ? reason.message : 'that did not work';
      setError(message.includes('NotAllowed') ? 'Passkey creation was cancelled.' : message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="landing-gate" role="dialog" aria-label="Keep this machine">
      <div className="landing-gate__card">
        <p className="landing-gate__kicker">
          That was your {Math.round(budgetSeconds)} seconds{remainingSeconds > 0 ? ' — nearly' : ''}
        </p>
        <h2 className="landing-gate__title">Keep going on this {stationTitle}.</h2>
        <p className="landing-gate__body">
          Make a passkey and the same machine comes back exactly as you left it, with twenty
          minutes on it. Your device makes one key for this museum and nothing else — no name,
          no email, no password.
        </p>
        {error && <p className="landing-gate__error">{error}</p>}
        <div className="landing-gate__actions">
          <button
            type="button"
            className="landing-btn landing-btn--primary"
            disabled={busy || !supportsPasskeys()}
            onClick={() => { void enrol(); }}
          >
            {busy ? 'Waiting for your device…' : 'Create my passkey'}
          </button>
          <a className="landing-btn landing-btn--quiet" href="/login" onClick={onSignedIn}>
            I already have one
          </a>
        </div>
        {!supportsPasskeys() && (
          <p className="landing-gate__body">
            This browser cannot make a passkey. Try a current Safari, Chrome, Edge or Firefox.
          </p>
        )}
      </div>
    </div>
  );
}
