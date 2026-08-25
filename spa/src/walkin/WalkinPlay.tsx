import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import StreamView from '../ui/grid/StreamView';
import type { OSBinding } from '../three/archetypeRegistry';
import type { WalkinClaim, WalkinState } from '../data/walkinTypes';
import { claimWalkin, fetchWalkinState, isClosedError, isQueued, releaseWalkin, resetWalkin } from './api';
import { accessAllows, clockText, resolveEndReason } from './sessionEnd';
import { walkinReasonCopy, type WalkinReason } from './reasons';
import { currentAccount } from './passkey';

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

type Phase =
  | { kind: 'claiming' }
  | { kind: 'queued'; position: number }
  | { kind: 'playing'; claim: WalkinClaim }
  | { kind: 'ended'; reason: WalkinReason | null; message?: string };

export default function WalkinPlay() {
  const { os = '' } = useParams();
  const navigate = useNavigate();
  const [phase, setPhase] = useState<Phase>({ kind: 'claiming' });
  const [secondsLeft, setSecondsLeft] = useState(0);
  const claimRef = useRef<WalkinClaim | null>(null);
  const lastInputRef = useRef(Date.now());
  const roleRef = useRef('walkin');

  const take = useCallback(
    async (again: boolean) => {
      setPhase({ kind: 'claiming' });
      try {
        const held = claimRef.current;
        const result = again && held ? await resetWalkin(held.clone) : await claimWalkin(os);
        if (isQueued(result)) {
          setPhase({ kind: 'queued', position: result.position });
          return;
        }
        claimRef.current = result;
        lastInputRef.current = Date.now();
        setSecondsLeft(result.ttlSeconds);
        setPhase({ kind: 'playing', claim: result });
      } catch (reason) {
        if (isClosedError(reason)) {
          setPhase({ kind: 'ended', reason: 'WALKIN_CLOSED' });
          return;
        }
        setPhase({
          kind: 'ended',
          reason: null,
          message: reason instanceof Error ? reason.message : 'the machine could not be claimed',
        });
      }
    },
    [os],
  );

  useEffect(() => { void currentAccount().then((who) => { if (who) roleRef.current = who.role; }); }, []);

  useEffect(() => { void take(false); }, [take]);

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
        setPhase({ kind: 'ended', reason });
      }
    }, 1000);

    return () => { alive = false; clearInterval(tick); clearInterval(pollTimer); };
  }, [phase]);

  const noteInput = useCallback(() => { lastInputRef.current = Date.now(); }, []);

  if (phase.kind === 'playing') {
    const low = secondsLeft <= 120;
    return (
      <div
        className="walkin-play"
        onPointerDown={noteInput}
        onPointerMove={noteInput}
        onKeyDown={noteInput}
      >
        <div className="walkin-play-chrome">
          <span className="walkin-play-name">Your {os}</span>
          <span className={`walkin-clock${low ? ' walkin-clock--low' : ''}`}>{clockText(secondsLeft)} left</span>
          <span className="walkin-play-chrome-spacer" />
          <button type="button" className="walkin-btn walkin-btn--quiet" onClick={() => { void take(true); }}>
            Reset — give me a fresh one
          </button>
          <button type="button" className="walkin-btn walkin-btn--quiet" onClick={() => navigate('/walkin')}>
            Leave
          </button>
        </div>
        <div className="walkin-play-stage">
          <StreamView os={cloneBinding(os, phase.claim)} onExit={() => navigate('/walkin')} />
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
  return (
    <section className={`walkin-notice${retryable ? '' : ' walkin-notice--warn'}`} aria-live="polite">
      <h2>{title}</h2>
      <p>{detail}</p>
      <div className="walkin-notice-actions">
        {retryable && <button type="button" className="walkin-btn" onClick={onRetry}>Take another machine</button>}
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
