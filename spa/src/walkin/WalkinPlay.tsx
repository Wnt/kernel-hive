import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import StreamView from '../ui/grid/StreamView';
import type { OSBinding } from '../three/archetypeRegistry';
import type { WalkinClaim, WalkinState } from '../data/walkinTypes';
import { claimWalkin, fetchWalkinState, releaseWalkin, resetWalkin } from './api';
import {
  phaseAfterClaim,
  phaseAfterClaimError,
  playAgainLabel,
  reclaimsOnPageShow,
  releasesCloneOnEnd,
  type Phase,
} from './playPhase';
import { accessAllows, clockText, resolveEndReason } from './sessionEnd';
import { walkinReasonCopy, type WalkinReason } from './reasons';
import { currentAccount } from './passkey';
import { playTelemetry, type PlayTelemetry } from './playTelemetry';
import { IdentityBadge } from '../ui/IdentityBadge';

// /walkin/play/<os> — the visitor's own clone, in the normal station view.
//
// Three things make this different from /os/<id>:
//   1. The stream endpoint comes from the CLAIM, not from a manifest row. A
//      walk-in is never handed another station's signaling document (§5.3).
//   2. There is a RESET: "discard my clone, give me a fresh one". The visitor
//      is told what it does in their words; the mechanism (respawn) is the
//      broker's business, POST /walkin/reset.
//   3. The session can end for reasons that are nobody's fault, and each one
//      gets its own sentence (§3.1 / reasons.ts). A walk-in dropped because the
//      operator closed access must never see "connection lost".
//   4. A reload, a back-navigation or a bfcache restore lands the visitor back
//      on the cell they still hold (the broker answers the claim `resumed`),
//      or on a free one — the transitions are playPhase.ts, with tests.

const IDLE_WINDOW_SECONDS = 180;

/** The station view's binding for a clone: the station's identity, the CLONE's
 *  endpoint. archetype/accent are cosmetic and safe to default. */
function cloneBinding(os: string, claim: WalkinClaim): OSBinding {
  return {
    osId: os,
    displayName: os,
    archetypeId: 'beige-tower-crt',
    transport: 'streamhost',
    accentColor: '#9c4f35',
    eraLabel: 'your own copy',
    signalEndpoint: claim.signalEndpoint,
  };
}

export default function WalkinPlay() {
  const { os = '' } = useParams();
  const navigate = useNavigate();
  const [phase, setPhase] = useState<Phase>({ kind: 'claiming' });
  const [secondsLeft, setSecondsLeft] = useState(0);
  const claimRef = useRef<WalkinClaim | null>(null);
  const lastInputRef = useRef(Date.now());
  const roleRef = useRef('walkin');

  // ---- the claim attempt (playTelemetry.ts) ---------------------------------
  // Created in an effect, never during render and never in a setState updater:
  // StrictMode runs both twice and the funnel would count every attempt twice.
  const telRef = useRef<PlayTelemetry | null>(null);
  useEffect(() => {
    const attempt = playTelemetry();
    telRef.current = attempt;
    return () => {
      attempt.ended();
      if (telRef.current === attempt) telRef.current = null;
    };
  }, []);

  const take = useCallback(
    async (again: boolean) => {
      setPhase({ kind: 'claiming' });
      // `again` is a RESET — the visitor asking for a fresh machine and getting
      // one. That is the feature working, so it is explicitly not a retry.
      telRef.current?.claiming({ reset: again });
      try {
        const held = claimRef.current;
        const result = again && held ? await resetWalkin(held.clone) : await claimWalkin(os);
        const next = phaseAfterClaim(result);
        if (next.kind === 'queued') {
          telRef.current?.queued();
          setPhase(next);
          return;
        }
        if (next.kind !== 'playing') return;
        telRef.current?.held();
        claimRef.current = next.claim;
        lastInputRef.current = Date.now();
        setSecondsLeft(next.claim.ttlSeconds);
        setPhase(next);
      } catch (reason) {
        const next = phaseAfterClaimError(reason);
        if (next.kind === 'ended' && next.reason === 'WALKIN_CLOSED') telRef.current?.refused();
        else telRef.current?.failed();
        setPhase(next);
      }
    },
    [os],
  );

  useEffect(() => { void currentAccount().then((who) => { if (who) roleRef.current = who.role; }); }, []);

  useEffect(() => { void take(false); }, [take]);

  // Back/forward cache: Safari restores the old document on a back-navigation,
  // effects and all, with a clone that was released when the visitor left.
  // Claim afresh — the broker hands the same cell back if it is still theirs.
  useEffect(() => {
    const onShow = (event: PageTransitionEvent) => {
      if (reclaimsOnPageShow(event.persisted)) void take(false);
    };
    window.addEventListener('pageshow', onShow);
    return () => window.removeEventListener('pageshow', onShow);
  }, [take]);

  // Hand the clone back when the visitor leaves the page. Without this the pool
  // is only freed by the broker's own reaper, and the next visitor waits for a
  // machine nobody is using.
  useEffect(() => () => {
    const held = claimRef.current;
    claimRef.current = null;
    if (held) void releaseWalkin(held.clone).catch(() => { /* the reaper is the backstop */ });
  }, []);

  // The session clock, and the two ends the client can see for itself: the TTL
  // running out, and access being closed under a live session. Whatever the
  // broker says (a code on the drop) still wins — resolveEndReason.
  useEffect(() => {
    if (phase.kind !== 'playing') return;
    let alive = true;
    let state: WalkinState | null = null;
    const started = Date.now();
    const ttl = phase.claim.ttlSeconds;

    const poll = () => {
      fetchWalkinState().then((next) => { if (alive) state = next; }, () => { /* a poll miss is not a drop */ });
    };
    poll();
    const pollTimer = setInterval(poll, 20_000);

    const tick = setInterval(() => {
      if (!alive) return;
      const left = ttl - Math.floor((Date.now() - started) / 1000);
      setSecondsLeft(left);
      const allowed = state ? accessAllows(state.access, roleRef.current) : true;
      const reason = resolveEndReason({
        access: state?.access,
        allowed,
        secondsLeft: left,
        idleSeconds: Math.floor((Date.now() - lastInputRef.current) / 1000),
        idleWindowSeconds: IDLE_WINDOW_SECONDS,
      });
      if (reason) {
        alive = false;
        // A clone whose time is up goes back to the pool NOW, so "Play again"
        // claims a fresh machine instead of re-attaching to this one.
        const held = claimRef.current;
        if (held && releasesCloneOnEnd(reason)) {
          claimRef.current = null;
          void releaseWalkin(held.clone).catch(() => { /* the reaper is the backstop */ });
        }
        setPhase({ kind: 'ended', reason });
      }
    }, 1000);

    return () => { alive = false; clearInterval(tick); clearInterval(pollTimer); };
  }, [phase]);

  const noteInput = useCallback(() => { lastInputRef.current = Date.now(); }, []);

  /** A DELIBERATE input on the clone — a press or a key, not a mouse crossing
   *  the page. This, not a painted frame, is the end of `toPlayableMs`: the
   *  frame is already measured by the station plane, and a clone that paints
   *  perfectly and is never touched is one the pool spent for nothing. */
  const noteDeliberateInput = useCallback(() => {
    lastInputRef.current = Date.now();
    telRef.current?.drove();
  }, []);

  if (phase.kind === 'playing') {
    const low = secondsLeft <= 120;
    return (
      <div
        className="walkin-play"
        onPointerDown={noteDeliberateInput}
        onPointerMove={noteInput}
        onKeyDown={noteDeliberateInput}
      >
        <div className="walkin-play-chrome">
          <span className="walkin-play-name">{phase.resumed ? `Your ${os}, right where you left it` : `Your ${os}`}</span>
          <span className={`walkin-clock${low ? ' walkin-clock--low' : ''}`}>{clockText(secondsLeft)} left</span>
          <IdentityBadge />
          <span className="walkin-play-chrome-spacer" />
          <button type="button" className="walkin-btn walkin-btn--quiet" onClick={() => { void take(true); }}>
            Reset — give me a fresh one
          </button>
          <button type="button" className="walkin-btn walkin-btn--quiet" onClick={() => navigate('/walkin')}>
            Leave
          </button>
        </div>
        <div className="walkin-play-stage">
          {/* KEYED BY CLONE. Reset hands back a DIFFERENT machine, and a
              station view that is merely re-rendered with a new endpoint would
              keep showing the old clone's last frame — which is exactly what
              the live smoke saw, and it is indistinguishable from a working
              reset because both clones restore the same golden. A new clone is
              a new mount. */}
          <StreamView
            key={phase.claim.clone}
            os={cloneBinding(os, phase.claim)}
            onExit={() => navigate('/walkin')}
          />
        </div>
      </div>
    );
  }

  return (
    <div className="walkin-page">
      {phase.kind === 'claiming' && (
        <section className="walkin-notice" aria-live="polite">
          <h2>Getting a machine ready…</h2>
          <p>Your own copy of {os} is being handed to you. This takes a moment.</p>
        </section>
      )}

      {phase.kind === 'queued' && (
        <section className="walkin-notice walkin-notice--warn" aria-live="polite">
          <h2>Every {os} is busy right now.</h2>
          <p>
            You are number {phase.position} in the queue. Machines come back as visitors finish, so
            try again in a minute — or read about the rest of the collection while you wait.
          </p>
          <div className="walkin-notice-actions">
            <button type="button" className="walkin-btn" onClick={() => { void take(false); }}>Try again</button>
            <button type="button" className="walkin-btn walkin-btn--quiet" onClick={() => navigate('/walkin/exhibits')}>
              See the rest of the museum
            </button>
          </div>
        </section>
      )}

      {phase.kind === 'ended' && <EndedCard os={os} phase={phase} onRetry={() => { void take(false); }} />}
    </div>
  );
}

/** Why the session ended, in the visitor's terms — never a generic error. */
function EndedCard({
  os,
  phase,
  onRetry,
}: {
  os: string;
  phase: { kind: 'ended'; reason: WalkinReason | null; message?: string };
  onRetry: () => void;
}) {
  const navigate = useNavigate();
  const copy = phase.reason
    ? walkinReasonCopy(phase.reason, { ttlSeconds: 1200, idleSeconds: IDLE_WINDOW_SECONDS })
    : null;
  const title = copy?.title ?? 'That session ended.';
  const detail =
    copy?.detail ??
    phase.message ??
    `The connection to your ${os} was lost. Nothing is broken at the museum's end that a retry will not fix.`;
  const retryable = copy?.retryable ?? true;
  // The way back in is never absent: a retryable end claims a fresh machine;
  // closed access re-asks the broker, the one party that knows whether the
  // door has reopened (playPhase.ts).
  return (
    <section className={`walkin-notice${retryable ? '' : ' walkin-notice--warn'}`} aria-live="polite">
      <h2>{title}</h2>
      <p>{detail}</p>
      <div className="walkin-notice-actions">
        <button type="button" className={`walkin-btn${retryable ? '' : ' walkin-btn--quiet'}`} onClick={onRetry}>
          {playAgainLabel(phase.reason)}
        </button>
        <button type="button" className="walkin-btn walkin-btn--quiet" onClick={() => navigate('/walkin')}>
          Back to the three machines
        </button>
        <button type="button" className="walkin-btn walkin-btn--quiet" onClick={() => navigate('/walkin/exhibits')}>
          The rest of the museum
        </button>
      </div>
    </section>
  );
}
