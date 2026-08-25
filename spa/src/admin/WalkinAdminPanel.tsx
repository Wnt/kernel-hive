import { useState } from 'react';
import type { WalkinAccess } from '../data/walkinTypes';
import { accessRank, useWalkinAdmin } from './useWalkinAdmin';
import './WalkinAdminPanel.css';

// /admin's walk-in panel (CONTRACT-LEDGER.md §3, §7; WALKIN-BRIEF.md §5.1).
// Everything here reads from GET /auth/walkin/status and writes through
// POST /auth/walkin/{access,drain,purge} — no local guess at server state
// beyond the one field the contract does not expose (drain, see useWalkinAdmin).

const POSITIONS: Array<{ value: WalkinAccess; label: string; hint: string }> = [
  { value: 'closed', label: 'Closed', hint: 'Nobody reaches the walk-in plane. Pool empty.' },
  { value: 'invited', label: 'Invited only', hint: 'Invited accounts, on the production URL.' },
  { value: 'open', label: 'Open', hint: 'Anyone with a passkey.' },
];

function envFloorNote(envFloor: WalkinAccess): string | null {
  if (envFloor === 'open') return null;
  const label = POSITIONS.find((p) => p.value === envFloor)?.label ?? envFloor;
  return `WALKIN_OPEN holds the env floor at ${label}. The switch cannot be raised past it until a deploy changes that setting — this is not a bug.`;
}

export function WalkinAdminPanel() {
  const { state, busy, lastResult, actionError, drainRequested, changeAccess, toggleDrain, purge } = useWalkinAdmin();
  const [purgeDays, setPurgeDays] = useState(90);

  if (state.phase === 'loading') {
    return <div className="wa-panel"><p className="wa-status">Loading walk-in status…</p></div>;
  }
  if (state.phase === 'forbidden') {
    return (
      <div className="wa-panel">
        <p className="wa-status wa-status--err">
          Admin sign-in required to see or change walk-in access. <a href="/login">Sign in</a>.
        </p>
      </div>
    );
  }
  if (state.phase === 'error') {
    return (
      <div className="wa-panel">
        <p className="wa-status wa-status--err">Could not load walk-in status: {state.message}</p>
      </div>
    );
  }

  const { status } = state;
  const floorNote = envFloorNote(status.envFloor);

  const onPick = (value: WalkinAccess) => {
    if (busy || value === status.access) return;
    if (accessRank(value) > accessRank(status.envFloor)) return; // env floor blocks it — no click possible anyway
    if (value === 'closed' && status.sessions > 0) {
      const n = status.sessions;
      const ok = window.confirm(
        `Drop walk-in access to Closed? This disconnects ${n} live walk-in session${n === 1 ? '' : 's'} immediately.`,
      );
      if (!ok) return;
    }
    void changeAccess(value);
  };

  return (
    <div className="wa-panel">
      <section className="wa-card">
        <h2>Access</h2>
        <div className="wa-switch" role="radiogroup" aria-label="Walk-in access">
          {POSITIONS.map((pos) => {
            const blocked = accessRank(pos.value) > accessRank(status.envFloor);
            const active = pos.value === status.access;
            return (
              <button
                key={pos.value}
                type="button"
                role="radio"
                aria-checked={active}
                className={`wa-switch-opt${active ? ' active' : ''}${blocked ? ' blocked' : ''}`}
                disabled={busy || blocked}
                title={blocked ? 'Blocked by the WALKIN_OPEN env floor' : pos.hint}
                onClick={() => onPick(pos.value)}
              >
                {pos.label}
                {blocked && <span className="wa-lock" aria-hidden="true">🔒</span>}
              </button>
            );
          })}
        </div>
        {floorNote && <p className="wa-note wa-note--floor">{floorNote}</p>}
        {status.access === 'closed' && <p className="wa-note">{POSITIONS[0].hint}</p>}
        {status.access === 'invited' && <p className="wa-note">{POSITIONS[1].hint}</p>}
        {status.access === 'open' && <p className="wa-note">{POSITIONS[2].hint}</p>}

        {lastResult?.kind === 'access' && (
          <p className="wa-result">
            Access set to {POSITIONS.find((p) => p.value === lastResult.access)?.label ?? lastResult.access}
            {lastResult.disconnected > 0
              ? ` — disconnected ${lastResult.disconnected} session${lastResult.disconnected === 1 ? '' : 's'}.`
              : '.'}
          </p>
        )}
      </section>

      <section className="wa-card">
        <h2>Live state</h2>
        <dl className="wa-stats">
          <div className="wa-stat">
            <dt>Walk-in sessions live now</dt>
            <dd>{status.sessions}</dd>
          </div>
          <div className="wa-stat">
            <dt>Walk-in accounts</dt>
            <dd>{status.accounts}</dd>
          </div>
        </dl>
        <h3>Pools</h3>
        {status.pools.length === 0 ? (
          <p className="wa-note">No walk-in pools configured.</p>
        ) : (
          <ul className="wa-pools">
            {status.pools.map((pool) => (
              <li key={pool.os} className="wa-pool">
                <span className="wa-pool-os">{pool.os}</span>
                <span className="wa-pool-free">{pool.free} of {pool.size} free</span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="wa-card">
        <h2>Drain</h2>
        <p className="wa-note">
          Refuses new claims and lets sessions already in flight finish on their own — for a maintenance
          window. It is <strong>not</strong> the off switch: it does not touch anyone currently connected,
          and it does not close signup. Use the switch above to actually stop walk-in access.
        </p>
        <p className="wa-note wa-note--floor">
          The status route does not report drain state (frozen contract), so this reflects only what this
          browser tab has asked for, not necessarily the server's live state after a reload or from another tab.
        </p>
        <div className="wa-row">
          <button type="button" className="wa-btn" disabled={busy || drainRequested} onClick={() => void toggleDrain(true)}>
            Start drain
          </button>
          <button type="button" className="wa-btn wa-btn--secondary" disabled={busy || !drainRequested} onClick={() => void toggleDrain(false)}>
            Cancel drain
          </button>
          {drainRequested && <span className="wa-tag">draining (this tab)</span>}
        </div>
        {lastResult?.kind === 'drain' && (
          <p className="wa-result">{lastResult.drain ? 'Drain requested.' : 'Drain cancelled.'}</p>
        )}
      </section>

      <section className="wa-card">
        <h2>Purge old accounts</h2>
        <p className="wa-note">Removes walk-in accounts idle for longer than the threshold below.</p>
        <div className="wa-row">
          <label htmlFor="wa-purge-days" className="wa-purge-label">Older than</label>
          <input
            id="wa-purge-days"
            type="number"
            min={1}
            className="wa-purge-input"
            value={purgeDays}
            onChange={(ev) => setPurgeDays(Math.max(1, Number(ev.target.value) || 1))}
          />
          <span className="wa-purge-unit">days</span>
          <button
            type="button"
            className="wa-btn wa-btn--danger"
            disabled={busy}
            onClick={() => {
              const ok = window.confirm(`Purge every walk-in account idle for more than ${purgeDays} day${purgeDays === 1 ? '' : 's'}?`);
              if (ok) void purge(purgeDays);
            }}
          >
            Purge
          </button>
        </div>
        {lastResult?.kind === 'purge' && (
          <p className="wa-result">Purged {lastResult.purged} account{lastResult.purged === 1 ? '' : 's'}.</p>
        )}
      </section>

      {actionError && <p className="wa-status wa-status--err">{actionError}</p>}
    </div>
  );
}
