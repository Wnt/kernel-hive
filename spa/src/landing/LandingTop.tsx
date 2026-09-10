import { useCallback, useEffect, useRef } from 'react';
import { useMuseum } from '../state/store';
import { useSession } from '../data/SessionContext';
import { accessAllows } from '../walkin/sessionEnd';
import { supportsPasskeys } from '../walkin/passkey';
import { registerRefused, registerTelemetry, type RegisterTelemetry } from '../walkin/registerTelemetry';
import { WALKIN_CLOSED_COPY } from '../walkin/reasons';
import { LandingHeader } from './LandingHeader';
import { HeroStage } from './HeroStage';
import { StationSwitcher } from './StationSwitcher';
import { Countdown } from './gate/Countdown';
import { useHeroSession } from './useHeroSession';
import { HERO_STATIONS } from './stations';

// ============================================================================
//  landing/LandingTop — everything above the fold.
//  ---------------------------------------------------------------------------
//  It is a component of its own, and not a block inside LandingPage, for a
//  reason that is entirely about cost: this subtree re-renders once a second
//  (the countdown, the release grace clock), and the 96-card collection below
//  it must not. Keeping the clock inside this component means React re-renders
//  THIS and leaves GridView's element — created once per LandingPage render —
//  untouched.
//
//  The reading order is the order of the promise: what this is, that it is
//  already running, that it is yours, and only then what it costs to stay.
// ============================================================================

export function LandingTop() {
  const hero = useHeroSession();
  const { role } = useSession();
  const listed = useMuseum((s) => s.listedVms);
  const vm = useMuseum((s) => s.vms.find((entry) => entry.id === hero.station));

  const running = hero.phase.kind === 'live';
  const exhibits = listed.length > 0 ? `See all ${listed.length} exhibits` : 'See the collection';
  const pools = hero.state?.pools ?? [];
  const free = pools.reduce((n, pool) => n + pool.free, 0);
  const size = pools.reduce((n, pool) => n + pool.size, 0);
  const closed = hero.state !== null && hero.state.access === 'closed';

  // ---- the registration attempt (walkin/registerTelemetry.ts) -------------
  // This page inherits the walk-in door's funnel, because it IS the walk-in
  // door now: the three static cards it replaced were the only thing opening
  // `walkin.register`, and a funnel nothing enters reads as a feature nobody
  // uses rather than a page that was rewritten. Held in a ref and created from
  // an EFFECT — never during render, never inside a setState updater, both of
  // which StrictMode invokes twice and would double every count.
  //
  // ONE STEP IS NOT REPORTED HERE, and deliberately: `passkeyStarted`. The
  // ceremony belongs to the conversion gate (landing/gate/), so its clock is
  // theirs to start. The funnel's steps are monotonic (analytics/flows.ts), so
  // `accountReady` still credits the passkey step it necessarily passed.
  const telRef = useRef<RegisterTelemetry | null>(null);
  const startedRef = useRef(false);
  useEffect(() => () => {
    telRef.current?.abandoned();
    telRef.current = null;
    // Reset the once-guard too: StrictMode mounts, tears down and re-mounts,
    // and a guard that survived that would leave the real mount with no
    // attempt open at all.
    startedRef.current = false;
  }, []);

  const access = hero.state?.access;
  useEffect(() => {
    if (access === undefined || startedRef.current) return;
    startedRef.current = true;
    // Three populations, three different things to do. A closed door is a
    // REFUSAL, counted on its own so a switch the operator flipped is never
    // read as a landing page that lost people. A visitor who already has an
    // account is not registering and opens nothing. Only a stranger at an open
    // door enters the funnel.
    if (!accessAllows(access, role)) { registerRefused(); return; }
    if (role !== 'anon') return;
    const tel = registerTelemetry();
    telRef.current = tel;
    if (!supportsPasskeys()) { tel.unsupported(); return; }
    tel.landed();
  }, [access, role]);

  const pick = useCallback((os: string) => {
    telRef.current?.chose();
    // Pressing a chip is a person, whether or not it changes the machine.
    hero.notePresence();
    hero.take(os);
  }, [hero]);

  // "Give me a machine" means the one they were on, when there was one. A
  // visitor whose machine went back to the pool is asking for THAT machine —
  // claiming with no station here is what used to hand them a different OS for
  // pressing the page's own recovery button (landing/heroSession.resumeTarget).
  const takeAny = useCallback(() => {
    hero.notePresence();
    hero.take(hero.resume);
  }, [hero]);

  const scrollToCollection = useCallback(() => {
    document.querySelector('.era-section')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }, []);

  // A visitor who has just converted holds the SAME cell (the broker reserves
  // it for 120s and answers the next claim `resumed`), but their ROLE has
  // changed on the server and this document resolved its role once, before
  // React mounted (main.tsx). Reloading is how the page picks up all of it at
  // once — no budget, no wall, the right name in the bar, the same machine
  // still warm — instead of running on for up to a poll interval insisting the
  // visitor is anonymous.
  const reload = useCallback(() => { window.location.reload(); }, []);

  /** The wall converted. The attempt SUCCEEDED — an account exists and the
   *  visitor is on a machine — so it is reported before the document goes. */
  const registered = useCallback(() => {
    telRef.current?.accountReady();
    telRef.current?.reachedMachine();
    reload();
  }, [reload]);

  return (
    <section className="landing-top">
      <LandingHeader exhibitCount={listed.length} />

      <div className="landing-top__body landing-hero">
        <div className="landing-hero__pitch">
          <h1 className="landing-hero__headline">
            It is already running.<br />
            <em>Go on, click it.</em>
          </h1>
          <p className="landing-hero__lede">
            Every exhibit in this museum is a real operating system on real emulated hardware, in
            one rack, streamed to this tab. The machine beside this text is a private copy of one
            of them, and it is yours right now — your mouse and your keyboard go straight into the
            guest. No install, no plugin, no account. Break anything you like: the next visitor
            gets a pristine one.
          </p>

          {/* The primary action is whatever the visitor does NOT already have.
              With no machine on screen that is a machine; with one running it
              is the rest of the museum — and the accent has to move with it,
              or a page whose hero succeeded is a page with no call to action
              on it at all. */}
          <div className="landing-hero__cta">
            {running
              ? (
                <button type="button" className="landing-btn landing-btn--primary landing-btn--big" onClick={scrollToCollection}>
                  {exhibits}
                </button>
              )
              : (
                <>
                  {hero.playable && (
                    <button
                      type="button"
                      className="landing-btn landing-btn--primary landing-btn--big"
                      disabled={hero.busy || closed}
                      onClick={takeAny}
                    >
                      {hero.busy
                        ? 'Finding you a machine…'
                        : hero.resume === null ? 'Give me a machine' : 'Bring it back'}
                    </button>
                  )}
                  <button type="button" className="landing-btn landing-btn--quiet landing-btn--big" onClick={scrollToCollection}>
                    {exhibits}
                  </button>
                </>
              )}
            {hero.remainingSeconds !== null && hero.budgetSeconds !== null && (
              <Countdown
                remainingSeconds={hero.remainingSeconds}
                budgetSeconds={hero.budgetSeconds}
                engaged={hero.engaged}
              />
            )}
          </div>

          {closed
            ? (
              <p className="landing-hero__note landing-hero__note--warn">
                {WALKIN_CLOSED_COPY}{' '}
                {hero.state?.notice
                  ?? 'The drivable machines are switched off while the lab is being worked on — the rest of the collection is below, and it is all still here.'}
              </p>
            )
            : (
              <p className="landing-hero__meter">
                <strong>{free}</strong> of {size || HERO_STATIONS.length * 3} drivable machines free
                right now, across {HERO_STATIONS.length} stations.
              </p>
            )}

          <p className="landing-hero__note">
            Staying longer than a minute costs a passkey, and a passkey is all it costs: your
            device makes one key for this museum and nothing else. No name, no email, no password —
            you get a handle like <code>bold-turing</code>, and that is the whole account.
          </p>
        </div>

        <HeroStage hero={hero} vm={vm} onRegistered={registered} onSignedIn={reload} />
      </div>

      <div className="landing-top__body">
        <StationSwitcher
          phase={hero.phase}
          state={hero.state}
          disabled={hero.busy || closed || !hero.playable}
          onPick={pick}
        />
      </div>

      {/* The seam. Without a line here the collection reads as a second page
          that happened to be stapled on; with it, the hero is the first
          exhibit and the index follows. */}
      <div className="landing-top__body landing-divider">
        <span>The whole collection</span>
      </div>
    </section>
  );
}
