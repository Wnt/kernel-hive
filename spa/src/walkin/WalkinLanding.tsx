import { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { WalkinPool, WalkinState } from '../data/walkinTypes';
import { fetchWalkinState } from './api';
import { WALKIN_OS_IDS } from './fixture';
import { accessAllows } from './sessionEnd';
import { WALKIN_CLOSED_COPY } from './reasons';
import { currentAccount, supportsPasskeys, walkinSignup, type WalkinAccount } from './passkey';
import { posterFor } from '../data/posterIndex';

// /walkin — the landing page. Three machines you can actually play, their live
// pool status, and one tap to get an account.
//
// The CLOSED state is not an afterthought here: when access is closed the cards
// and the signup offer are not rendered at all, because a card the visitor
// cannot claim is a promise the lab is not keeping. They get the frozen
// sentence (§7) and the operator's optional notice instead — and the museum to
// read about, which is open whatever the switch says.

const CARDS: Record<string, { name: string; meta: string; blurb: string; accent: string }> = {
  win311: {
    name: 'Windows 3.11',
    meta: '1993 · 386 PC · Program Manager',
    blurb: 'Tiled windows, Solitaire and a Program Manager full of icons — the desktop that put Windows in every office.',
    accent: '#7fb0d6',
  },
  os2warp: {
    name: 'OS/2 Warp 4',
    meta: '1996 · IBM · Workplace Shell',
    blurb: "IBM's answer to Windows 95: an object desktop, speech recognition on the box, and a following that never quite let go.",
    accent: '#1e5aa8',
  },
  rhapsody: {
    name: 'Rhapsody DR2',
    meta: '1998 · Apple · the road to Mac OS X',
    blurb: "NeXTSTEP wearing a Platinum face — Apple's developer release on the way to Mac OS X, complete with a Blue Box.",
    accent: '#8f8f9c',
  },
};

function poolFor(state: WalkinState | null, os: string): WalkinPool | undefined {
  return state?.pools.find((pool) => pool.os === os);
}

/** "2 of 3 free", with the free slots also drawn as pips. */
function PoolMeter({ pool }: { pool: WalkinPool | undefined }) {
  if (!pool) return <span className="walkin-pool">checking…</span>;
  const pips = Array.from({ length: pool.size }, (_, index) => index < pool.free);
  return (
    <span className={`walkin-pool${pool.free === 0 ? ' walkin-pool--none' : ''}`}>
      <span className="walkin-pips" aria-hidden="true">
        {pips.map((free, index) => (
          <span key={index} className={`walkin-pip${free ? ' walkin-pip--free' : ''}`} />
        ))}
      </span>
      {pool.free} of {pool.size} free
    </span>
  );
}

export default function WalkinLanding() {
  const navigate = useNavigate();
  const [state, setState] = useState<WalkinState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [account, setAccount] = useState<WalkinAccount | null>(null);
  const [busy, setBusy] = useState(false);

  // Pool status is live, not a page-load snapshot: a visitor deciding between
  // three machines should see one free up while they read.
  useEffect(() => {
    let alive = true;
    const tick = () => {
      fetchWalkinState().then(
        (next) => { if (alive) { setState(next); setError(null); } },
        (reason: unknown) => { if (alive) setError(reason instanceof Error ? reason.message : 'walk-in status unavailable'); },
      );
    };
    tick();
    const timer = setInterval(tick, 15_000);
    return () => { alive = false; clearInterval(timer); };
  }, []);

  useEffect(() => {
    let alive = true;
    void currentAccount().then((who) => { if (alive) setAccount(who); });
    return () => { alive = false; };
  }, []);

  const signUp = useCallback(async () => {
    setBusy(true);
    setError(null);
    try {
      setAccount(await walkinSignup());
    } catch (reason) {
      const message = reason instanceof Error ? reason.message : 'signup failed';
      setError(message.includes('NotAllowed') ? 'Passkey creation was cancelled.' : message);
    } finally {
      setBusy(false);
    }
  }, []);

  const play = useCallback(
    async (os: string) => {
      // A walk-in needs an account before a clone can belong to anyone. One tap
      // covers both: create the passkey, then go straight to the machine.
      if (!account) {
        setBusy(true);
        try {
          setAccount(await walkinSignup());
        } catch (reason) {
          const message = reason instanceof Error ? reason.message : 'signup failed';
          setError(message.includes('NotAllowed') ? 'Passkey creation was cancelled.' : message);
          return;
        } finally {
          setBusy(false);
        }
      }
      navigate(`/walkin/play/${os}`);
    },
    [account, navigate],
  );

  const access = state?.access;
  const open = access !== undefined && accessAllows(access, account?.role ?? 'walkin');

  return (
    <>
      <p className="walkin-lede">
        Three machines from the museum are yours to use, right now, in this browser — no install, no
        account beyond a passkey, and a private copy that is thrown away when you are done. Break
        whatever you like: the next visitor gets a pristine one.
      </p>

      {access === undefined && !error && <p className="walkin-lede">Checking what is free…</p>}

      {access !== undefined && !open && (
        <section className="walkin-notice" aria-live="polite">
          <h2>{WALKIN_CLOSED_COPY}</h2>
          <p>
            {state?.notice ??
              'The walk-in machines are switched off at the moment. Nothing is wrong with your browser — check back later, or read about the collection below.'}
          </p>
        </section>
      )}

      {error && (
        <section className="walkin-notice walkin-notice--warn" aria-live="polite">
          <h2>That did not work.</h2>
          <p>{error}</p>
        </section>
      )}

      {open && (
        <>
          <div className="walkin-section-head">
            <h2>Play one now</h2>
            <span>{account ? `signed in as ${account.handle}` : 'one tap, one passkey'}</span>
          </div>
          <div className="walkin-cards">
            {WALKIN_OS_IDS.map((os) => {
              const card = CARDS[os];
              const pool = poolFor(state, os);
              const hero = posterFor(os)?.hero;
              return (
                <article className="walkin-card" key={os} style={{ ['--card-accent' as string]: card.accent }}>
                  {hero && <img className="walkin-card-hero" src={hero} alt="" loading="lazy" />}
                  <div className="walkin-card-body">
                    <span className="walkin-card-name">{card.name}</span>
                    <span className="walkin-card-meta">{card.meta}</span>
                    <p className="walkin-card-blurb">{card.blurb}</p>
                    <div className="walkin-card-foot">
                      <button
                        type="button"
                        className="walkin-btn"
                        disabled={busy || !supportsPasskeys()}
                        onClick={() => { void play(os); }}
                      >
                        {pool && pool.free === 0 ? 'Join the queue' : 'Play it'}
                      </button>
                      <PoolMeter pool={pool} />
                    </div>
                  </div>
                </article>
              );
            })}
          </div>

          {!supportsPasskeys() && (
            <section className="walkin-notice walkin-notice--warn">
              <h2>This browser cannot make a passkey.</h2>
              <p>
                Walk-in accounts are passkey-only — there is no password to steal and nothing to
                remember. Try a current Safari, Chrome, Edge or Firefox.
              </p>
            </section>
          )}

          {supportsPasskeys() && !account && (
            <section className="walkin-notice walkin-notice--ok">
              <h2>No sign-up form. Just a passkey.</h2>
              <p>
                Your device makes one key for this museum and nothing else. We never learn your name
                or your email — you get a handle like <code>bold-turing</code> and that is the whole
                account.
              </p>
              <div className="walkin-notice-actions">
                <button type="button" className="walkin-btn walkin-btn--quiet" disabled={busy} onClick={() => { void signUp(); }}>
                  {busy ? 'Waiting for your device…' : 'Create my passkey'}
                </button>
              </div>
            </section>
          )}
        </>
      )}
    </>
  );
}
