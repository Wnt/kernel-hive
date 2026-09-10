import { useCallback, useEffect, useRef, useState } from 'react';
import { claimWalkin, releaseWalkin } from '../walkin/api';
import { playTelemetry, type PlayTelemetry } from '../walkin/playTelemetry';
import { useWalkinPools } from '../walkin/usePools';
import { useSession } from '../data/SessionContext';
import { detectCaps } from '../three/streamTransportSelect';
import type { WalkinState } from '../data/walkinTypes';
import {
  heldClone,
  isBusy,
  liveStation,
  phaseAfterHeroClaim,
  phaseAfterHeroClaimError,
  switchPlan,
  type HeroPhase,
} from './heroSession';
import {
  graceSecondsLeft,
  heroPlayable,
  mirroredRemaining,
  releaseDue,
  shouldAutoClaim,
  type HeroCaps,
} from './heroPolicy';

// ============================================================================
//  landing/useHeroSession — the React glue over heroSession.ts + heroPolicy.ts.
//  ---------------------------------------------------------------------------
//  Everything here is effects, refs and timers; every DECISION it makes is a
//  call into one of the two pure modules next door, which have the tests. That
//  split is deliberate and it is the only way this code is gated at all — the
//  SPA's vitest runs under plain Node with no jsdom, so a hook cannot be
//  rendered in a test in this repo.
//
//  The three things this file is careful about:
//
//  1. ONE claim, and no accidental second one. StrictMode mounts, tears down
//     and re-mounts every effect, and a claim fired from an effect body without
//     a ref guard takes two cells out of a pool of eight per page load. The
//     guard is `attemptsRef`, and it is a ref precisely because it must survive
//     the StrictMode remount that state would reset.
//  2. Operations are SERIALISED by a token. A visitor who taps three stations
//     in a second must not end up with the third one's claim landing before the
//     second one's release; every async step checks it is still the current
//     operation before it touches state.
//  3. The cell goes back. On a release-due verdict, on unmount, and on
//     pagehide — the last one by beacon, because a normal fetch started during
//     an unload is routinely cancelled and the pool then waits for the broker's
//     reaper instead of the visitor's own tab.
// ============================================================================

/** Capability detection, in one place. The two primary-path answers come from
 *  three/streamTransportSelect.ts so this page cannot drift from the client
 *  that actually opens the socket. */
function detectHeroCaps(): HeroCaps {
  const primary = detectCaps();
  return {
    wt: primary.wt,
    vd: primary.vd,
    rtc: typeof RTCPeerConnection !== 'undefined',
    secure: typeof window === 'undefined' ? false : window.isSecureContext !== false,
  };
}

function isVisible(): boolean {
  return typeof document === 'undefined' || document.visibilityState === 'visible';
}

/** Hand a clone back during an unload, where a normal fetch does not survive. */
function beaconRelease(clone: string): void {
  try {
    const body = new Blob([JSON.stringify({ clone })], { type: 'application/json' });
    if (navigator.sendBeacon?.('/walkin/release', body)) return;
  } catch { /* fall through to the ordinary call */ }
  void releaseWalkin(clone).catch(() => { /* the broker's reaper is the backstop */ });
}

export interface HeroSession {
  phase: HeroPhase;
  /** The station on screen, or null. */
  station: string | null;
  /** Live pool status + access + the anonymous budget, straight from the plane. */
  state: WalkinState | null;
  /** The countdown, mirrored from the server's number. null ⇒ no budget (signed in). */
  remainingSeconds: number | null;
  budgetSeconds: number | null;
  expired: boolean;
  /** Can this browser be handed a live machine at all? */
  playable: boolean;
  caps: HeroCaps;
  /** Has a real person touched the machine yet? */
  driven: boolean;
  /** Seconds before an untouched cell goes back — the caption's honest warning. */
  graceLeft: number;
  busy: boolean;
  /** Take a machine: a station id, or null for "whichever the server picks". */
  take: (os: string | null) => void;
  /** A trusted pointer/key on the stage. Stops the aggressive release. */
  noteInput: () => void;
  /** Give the machine back on purpose. */
  stop: () => void;
}

export function useHeroSession(): HeroSession {
  const { role } = useSession();
  const { state } = useWalkinPools();
  const [phase, setPhase] = useState<HeroPhase>({ kind: 'idle' });
  const [caps] = useState(detectHeroCaps);
  const playable = heroPlayable(caps);

  // ---- what the watchdog reads, none of which should re-render on change ----
  const claimedAtRef = useRef(0);
  const lastInputRef = useRef<number | null>(null);
  const hiddenSinceRef = useRef<number | null>(isVisible() ? null : Date.now());
  const attemptsRef = useRef(0);
  const opRef = useRef(0);
  const phaseRef = useRef(phase);
  phaseRef.current = phase;

  const [driven, setDriven] = useState(false);
  const [graceLeft, setGraceLeft] = useState(0);

  // ---- the claim attempt (walkin/playTelemetry.ts) -------------------------
  // The SAME funnel the /walkin/play surface feeds, deliberately: this page
  // claims from the same pool with the same two possible answers, and giving
  // the hero a funnel of its own would split `walkin.play` into two halves
  // that could not be read together. Created in an effect, never during render
  // and never inside a setState updater — StrictMode runs both twice and every
  // attempt would be counted twice.
  const telRef = useRef<PlayTelemetry | null>(null);
  useEffect(() => {
    const attempt = playTelemetry();
    telRef.current = attempt;
    return () => {
      attempt.ended();
      if (telRef.current === attempt) telRef.current = null;
    };
  }, []);

  // ---- the countdown mirror ------------------------------------------------
  // usePools re-polls every 15s; the display has to move every second. So the
  // server's number is stamped with the moment it arrived and recomputed from
  // wall time, never accumulated — heroPolicy.mirroredRemaining's whole point.
  const polledAtRef = useRef(Date.now());
  useEffect(() => { polledAtRef.current = Date.now(); }, [state]);
  const [nowTick, setNowTick] = useState(() => Date.now());

  const anon = state?.anon;
  // A signed-in visitor has no countdown, so nothing on this page changes every
  // second for them and the tick must not re-render the hero. Held in a ref so
  // the watchdog interval below can read it without re-subscribing.
  const hasClockRef = useRef(false);
  hasClockRef.current = state?.anon !== undefined;
  const remainingSeconds = anon ? mirroredRemaining(anon.remainingSeconds, polledAtRef.current, nowTick) : null;
  const expired = anon ? anon.expired || remainingSeconds === 0 : false;

  /** Release whatever is held, without changing the phase. */
  const handBack = useCallback((clone: string) => {
    void releaseWalkin(clone).catch(() => { /* the broker's reaper is the backstop */ });
  }, []);

  const take = useCallback((os: string | null) => {
    const steps = switchPlan(phaseRef.current, os);
    if (steps.length === 0) return;
    const op = opRef.current + 1;
    opRef.current = op;
    // A SWITCH is not a retry. The visitor asked for a different machine and is
    // getting one, which is the switcher working; counting it as a retry would
    // report a working feature as pool pressure (playTelemetry's own rule for
    // a reset, and a switch is the same act).
    telRef.current?.claiming({ reset: attemptsRef.current > 0 });
    attemptsRef.current += 1;
    setPhase({ kind: 'claiming', want: os });
    setDriven(false);
    lastInputRef.current = null;

    void (async () => {
      for (const step of steps) {
        if (step.op === 'release') {
          // Awaited, not fired and forgotten: one clone per account (ledger
          // §7), so a claim that overtakes its own release is refused — or
          // worse, retires the cell the visitor is still watching.
          try { await releaseWalkin(step.clone); } catch { /* the reaper is the backstop */ }
          if (opRef.current !== op) return;
          continue;
        }
        try {
          const result = step.os === null ? await claimWalkin() : await claimWalkin(step.os);
          if (opRef.current !== op) {
            // A newer operation won while this claim was in flight. Do not
            // render it — and do not leak the cell it just took.
            if ('clone' in result) handBack(result.clone);
            return;
          }
          claimedAtRef.current = Date.now();
          const next = phaseAfterHeroClaim(result, step.os);
          if (next.kind === 'queued') telRef.current?.queued();
          else telRef.current?.held();
          setPhase(next);
        } catch (error) {
          if (opRef.current !== op) return;
          const next = phaseAfterHeroClaimError(error);
          // A shut door and a spent budget are FENCES the lab built, not a
          // broker that could not produce a machine, and the funnel has to tell
          // them apart or every closed evening reads as an outage.
          if (next.kind === 'refused' && next.code === 'error') telRef.current?.failed();
          else telRef.current?.refused();
          setPhase(next);
        }
      }
    })();
  }, [handBack]);

  // ---- auto-claim, exactly once -------------------------------------------
  useEffect(() => {
    const ok = shouldAutoClaim({
      playable,
      visible: isVisible(),
      access: state?.access,
      role,
      budget: anon,
      holding: heldClone(phaseRef.current) !== null,
      busy: isBusy(phaseRef.current),
      attempts: attemptsRef.current,
    });
    if (ok) take(null);
  }, [playable, state, role, anon, take]);

  // ---- the visitor's own input --------------------------------------------
  const noteInput = useCallback(() => {
    lastInputRef.current = Date.now();
    // The end of `walkin.play.toPlayableMs`: a clone that paints perfectly and
    // is never touched is one the pool spent for nothing.
    telRef.current?.drove();
    setDriven(true);
  }, []);

  /** Hand the machine back and say so. The stage's own exit affordance, which
   *  on this page has nowhere to go BACK to — leaving is releasing. */
  const stop = useCallback(() => {
    const clone = heldClone(phaseRef.current);
    opRef.current += 1;
    if (clone) handBack(clone);
    setPhase({ kind: 'stopped', station: liveStation(phaseRef.current), reason: 'left' });
  }, [handBack]);

  // ---- visibility ----------------------------------------------------------
  useEffect(() => {
    const onChange = () => {
      hiddenSinceRef.current = isVisible() ? null : Date.now();
    };
    document.addEventListener('visibilitychange', onChange);
    return () => document.removeEventListener('visibilitychange', onChange);
  }, []);

  // ---- the watchdog --------------------------------------------------------
  // One second is fine: the decisions are all in whole seconds, and this is the
  // same timer that moves the countdown, so the page has one interval and not
  // three.
  useEffect(() => {
    const tick = setInterval(() => {
      const now = Date.now();
      // React bails out of a re-render when the state is identical, so this is
      // free for the visitor who has no clock to move.
      setNowTick((prev) => (hasClockRef.current ? now : prev));
      const clone = heldClone(phaseRef.current);
      if (clone === null) { setGraceLeft(0); return; }
      const facts = {
        now,
        claimedAt: claimedAtRef.current,
        lastInputAt: lastInputRef.current,
        hiddenSince: hiddenSinceRef.current,
      };
      setGraceLeft(lastInputRef.current === null ? graceSecondsLeft(facts) : 0);
      const due = releaseDue(facts);
      if (due === null) return;
      handBack(clone);
      // `stopped`, not `idle`: idle is a page that has not asked yet, and the
      // difference is what lets the stage say "handed back — take another"
      // instead of silently showing a poster the visitor never asked for.
      setPhase({ kind: 'stopped', station: liveStation(phaseRef.current), reason: due });
    }, 1000);
    return () => clearInterval(tick);
  }, [handBack]);

  // ---- the cell always goes back ------------------------------------------
  useEffect(() => {
    const onPageHide = () => {
      const clone = heldClone(phaseRef.current);
      if (clone) beaconRelease(clone);
    };
    window.addEventListener('pagehide', onPageHide);
    return () => {
      window.removeEventListener('pagehide', onPageHide);
      const clone = heldClone(phaseRef.current);
      if (clone) handBack(clone);
    };
  }, [handBack]);

  return {
    phase,
    station: liveStation(phase),
    state,
    remainingSeconds,
    budgetSeconds: anon?.budgetSeconds ?? null,
    expired,
    playable,
    caps,
    driven,
    graceLeft,
    busy: isBusy(phase),
    take,
    noteInput,
    stop,
  };
}
