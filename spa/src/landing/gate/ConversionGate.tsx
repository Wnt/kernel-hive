import { useCallback, useEffect, useRef, useState } from 'react';
import type { JSX } from 'react';
import { Countdown } from './Countdown';
import { shouldShowWall } from './budget';
import { isClosedError } from '../../walkin/api';
import { supportsPasskeys, walkinSignIn, walkinSignup } from '../../walkin/passkey';
import { WALKIN_ANON_BUDGET_COPY, WALKIN_CLOSED_COPY } from '../../walkin/reasons';
import './gate.css';

// The conversion gate — the wall a signed-out stranger hits at the end of
// their intro time (LANDING-REDESIGN-CONTRACT.md "the goal": drive a real
// machine inside one second, hit a 60-second wall that converts). It renders
// OVER the frozen last frame the landing page leaves on screen — this
// component paints only the scrim and the placard on top of it, never the
// frame itself, so "your machine is still here" is a fact the visitor can see
// with their own eyes, not a claim in copy.
//
// Two ways through, both first-class (never a primary button beside a dead
// one): CREATE, the existing `walkinSignup()` ceremony, and SIGN IN, which
// this file is what wires up — `walkinSignIn()` (walkin/passkey.ts) runs the
// gallery's EXISTING /auth/login ceremony, the same one /login's "Sign in"
// button already runs. Neither is a new server endpoint.

/** Cancelled-by-the-user and "wrong door" both deserve their own sentence, not
 *  a fetch stack trace. Shared by both ceremonies below. */
function describeError(reason: unknown): string {
  if (isClosedError(reason)) return WALKIN_CLOSED_COPY;
  const message = reason instanceof Error ? reason.message : 'That did not work.';
  return message.includes('NotAllowed') ? 'That passkey step was cancelled.' : message;
}

export function ConversionGate(props: {
  remainingSeconds: number;
  budgetSeconds: number;
  expired: boolean;
  stationTitle: string;
  onRegistered: (handle: string) => void;
  onSignedIn: () => void;
}): JSX.Element | null {
  const { remainingSeconds, budgetSeconds, expired, stationTitle, onRegistered, onSignedIn } = props;
  const visible = shouldShowWall(remainingSeconds, expired);

  const [ceremony, setCeremony] = useState<'idle' | 'register' | 'signin'>('idle');
  const [error, setError] = useState<string | null>(null);
  // Set the moment the ceremony ANSWERS, not the moment it is requested — this
  // is the visitor's reward, so it appears only once there is a real handle to
  // show, never optimistically.
  const [justRegistered, setJustRegistered] = useState<string | null>(null);

  // The frame is the strongest asset on the page; the wall arriving on top of
  // it should still move keyboard focus onto itself, the way any modal must.
  const panelRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (visible) panelRef.current?.focus();
  }, [visible]);

  const register = useCallback(async () => {
    setCeremony('register');
    setError(null);
    try {
      const account = await walkinSignup();
      setJustRegistered(account.handle);
    } catch (reason) {
      setError(describeError(reason));
    } finally {
      setCeremony('idle');
    }
  }, []);

  const signIn = useCallback(async () => {
    setCeremony('signin');
    setError(null);
    try {
      await walkinSignIn();
      onSignedIn();
    } catch (reason) {
      setError(describeError(reason));
    } finally {
      setCeremony('idle');
    }
  }, [onSignedIn]);

  if (!visible) return null;

  const capable = supportsPasskeys();
  const busy = ceremony !== 'idle';

  return (
    <div className="gate-scrim">
      <div className="gate-panel" role="dialog" aria-modal="true" aria-labelledby="gate-title" tabIndex={-1} ref={panelRef}>
        <Countdown remainingSeconds={0} budgetSeconds={budgetSeconds} />
        <h2 id="gate-title" className="gate-title">{WALKIN_ANON_BUDGET_COPY}</h2>

        {justRegistered ? (
          <div className="gate-welcome">
            <p className="gate-welcome-kicker">Your key is made.</p>
            <p className="gate-welcome-handle">{justRegistered}</p>
            <p className="gate-copy">
              That is your handle here — the whole account. Nothing else about you is on file.
            </p>
            <div className="gate-actions">
              <button
                type="button"
                className="gate-btn"
                onClick={() => onRegistered(justRegistered)}
              >
                Back to {stationTitle}
              </button>
            </div>
          </div>
        ) : (
          <>
            <p className="gate-lede">
              but your {stationTitle} station is still here, exactly as you left it.
            </p>

            {capable ? (
              <>
                <p className="gate-copy">
                  We kindly ask you to register with The Kernel Hive. All it takes is a passkey. This is how we
                  keep bot traffic out.
                </p>
                <div className="gate-actions">
                  <button
                    type="button"
                    className="gate-btn"
                    disabled={busy}
                    onClick={() => { void register(); }}
                  >
                    {ceremony === 'register' ? 'Waiting for your device…' : 'Register'}
                  </button>
                  <button
                    type="button"
                    className="gate-btn gate-btn--quiet"
                    disabled={busy}
                    onClick={() => { void signIn(); }}
                  >
                    {ceremony === 'signin' ? 'Waiting for your device…' : 'Sign in'}
                  </button>
                </div>
              </>
            ) : (
              <p className="gate-copy">
                This browser cannot create or use a passkey, so neither button here would do anything — that is
                the plain truth, not a bug. A current Safari, Chrome, Edge or Firefox can.
                Already have an account? <a className="gate-link" href="/login">Try signing in from there.</a>
              </p>
            )}
          </>
        )}

        {error && <p className="gate-error" role="alert">{error}</p>}
      </div>
    </div>
  );
}
