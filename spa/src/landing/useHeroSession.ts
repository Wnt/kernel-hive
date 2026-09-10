import { useCallback, useEffect, useRef, useState } from 'react';
import { claimWalkin, engageWalkin, releaseWalkin } from '../walkin/api';
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
  resumeTarget,
  switchPlan,
  type HeroPhase,
} from './heroSession';
import {
  budgetRunning,
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
//  4. The visitor's minute starts HERE and is kept THERE. The first meaningful
//     input on the machine is reported once per clone to `POST /walkin/engage`
//     and the server starts the clock; this file never counts seconds and never
//     tells the server how many have passed. What it sends is an event.
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
  /** The station this hero is ABOUT: the one streaming, or — after the page
   *  handed a cell back — the one it was. Kept through a stop so the strip, the
   *  poster and the switcher all keep naming the same machine instead of
   *  reverting to a default the visitor never chose. */
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
  /** Has a real person touched the machine yet? Until they have, the minute is
   *  not running and the page says so. */
  engaged: boolean;
  /** The station "give it back" should ask for — the one on screen or the one
   *  just handed back, and null only when the visitor has never had one. A
   *  station change comes from a switcher chip or from nowhere. */
  resume: string | null;
  /** Seconds before an un-engaged cell goes back — the caption's honest warning. */
  graceLeft: number;
  busy: boolean;
  /** Take a machine: a station id, or null for "whichever the server picks". */
  take: (os: string | null) => void;
  /** A trusted press/tap/key on the stage — input into the guest itself, and the
   *  one thing that starts the visitor's minute. */
  noteInput: () => void;
  /** A trusted press anywhere on the hero (a chip, the call to action). Proves
   *  a person is here, which is all the aggressive release ever asked. */
  notePresence: () => void;
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
  // The first MEANINGFUL input, ever — a press, a tap or a key ON THE GUEST.
  // Sticky for the visit, matching the server's own `engaged`: engagement is a
  // fact about the person, so a visitor who switches machines does not have to
  // prove they exist again.
  const engagedAtRef = useRef<number | null>(null);
  // The last trusted press anywhere on the hero. Not engagement — a chip press
  // says nothing about the guest — but proof a person is here, so it pushes the
  // un-engaged release out instead of cancelling it.
  const lastPresenceRef = useRef<number | null>(null);
  // The clone the server has already been told about, so one visitor tapping
  // ten times sends one request per machine and not ten.
  const engagedCloneRef = useRef<string | null>(null);
  const hiddenSinceRef = useRef<number | null>(isVisible() ? null : Date.now());
  const attemptsRef = useRef(0);
  const opRef = useRef(0);
  const phaseRef = useRef(phase);
  phaseRef.current = phase;

  const [engaged, setEngaged] = useState(false);
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

  const holding = heldClone(phase) !== null;
  const anon = state?.anon;
  // Has this visitor EVER touched a machine? Sticky, like the server's own
  // `engaged`, and read from the server first — the local fact is only there so
  // the first press moves the page immediately instead of waiting up to a poll
  // interval for the server to agree with it.
  const hasEngaged = engaged || (anon?.engaged ?? false);
  // Whether the minute is being spent RIGHT NOW, which is the narrower
  // question and the only one the countdown mirror may ask.
  const clockRunning = budgetRunning({ holding, engaged: hasEngaged });
  // The mirror measures from the last poll, and the last poll can be up to a
  // whole interval old when the visitor finally touches the machine. Without
  // this the first press appeared to cost thirteen seconds — a probe watched
  // 1:00 become 0:47 on one click — because the seconds spent reading the page
  // were suddenly counted as driving. Re-stamping at the moment the clock
  // starts is right, not merely kind: the server's number was the FULL budget
  // and it starts spending at the touch, so the touch is where to count from.
  const runningRef = useRef(false);
  if (clockRunning && !runningRef.current) polledAtRef.current = Date.now();
  runningRef.current = clockRunning;
  // A signed-in visitor has no countdown, so nothing on this page changes every
  // second for them and the tick must not re-render the hero. Held in a ref so
  // the watchdog interval below can read it without re-subscribing.
  const hasClockRef = useRef(false);
  hasClockRef.current = state?.anon !== undefined;
  const remainingSeconds = anon
    ? mirroredRemaining(anon.remainingSeconds, polledAtRef.current, nowTick, clockRunning)
    : null;
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
    // NOTE what is deliberately NOT reset here: `engagedAtRef`. Engagement is a
    // fact about the PERSON, not about the cell, so a visitor who has already
    // shown they are there does not have to prove it again for every machine
    // they try. Resetting it made the page take a machine away from somebody
    // who had pressed a chip twelve seconds earlier and was reading the
    // desktop it gave them — which a switch probe caught on the staged build,
    // and which no amount of clicking around by hand would have, because a
    // hand always clicks the guest next. The server keeps the same rule for
    // the same reason (`auth/anon.py`), so the two clocks cannot disagree.

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
  /** Somebody is here. Pushes the un-engaged release out and nothing else — in
   *  particular it does NOT start the minute, because pressing a chip is not
   *  driving a machine. */
  const notePresence = useCallback(() => {
    lastPresenceRef.current = Date.now();
  }, []);

  /**
   * A deliberate input INTO THE GUEST, and the start of the visitor's minute.
   *
   * Narrower than presence, and kept separate for two reasons now. `drove()` is
   * the end of `walkin.play.toPlayableMs`, "the first moment the machine is
   * demonstrably usable rather than merely painted"
   * (walkin/playTelemetry.ts) — a press on a switcher chip proves a person is
   * on the page and proves nothing about the guest. And this is the event the
   * SERVER's clock starts on: `POST /walkin/engage` is reported once per clone,
   * fire-and-forget, because the request is a NOTIFICATION and the visitor must
   * not wait on it to keep typing. A dropped one costs them nothing — their
   * minute simply has not started yet — and the server's un-engaged sweep is
   * what stops that from being a way to hold a cell for free.
   */
  const noteInput = useCallback(() => {
    notePresence();
    if (engagedAtRef.current === null) engagedAtRef.current = Date.now();
    setEngaged(true);
    telRef.current?.drove();
    const clone = heldClone(phaseRef.current);
    if (clone && engagedCloneRef.current !== clone) {
      engagedCloneRef.current = clone;
      void engageWalkin(clone).catch(() => {
        // Let the next machine try again: an engage that never landed is a
        // clock that never started, and the visitor should not be charged for
        // a request they cannot see.
        if (engagedCloneRef.current === clone) engagedCloneRef.current = null;
      });
    }
  }, [notePresence]);

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
        engagedAt: engagedAtRef.current,
        lastPresenceAt: lastPresenceRef.current,
        hiddenSince: hiddenSinceRef.current,
      };
      setGraceLeft(engagedAtRef.current === null ? graceSecondsLeft(facts) : 0);
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
    station: liveStation(phase) ?? (phase.kind === 'stopped' ? phase.station : null),
    state,
    remainingSeconds,
    budgetSeconds: anon?.budgetSeconds ?? null,
    expired,
    playable,
    caps,
    engaged: hasEngaged,
    resume: resumeTarget(phase),
    graceLeft,
    busy: isBusy(phase),
    take,
    noteInput,
    notePresence,
    stop,
  };
}
