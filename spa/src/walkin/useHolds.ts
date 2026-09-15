import { useEffect, useState } from 'react';
import type { WalkinHold } from '../data/walkinTypes';

// Turns the polled `holds` array (GET /walkin/state, usePools.ts polls every
// 15s) into a live per-station countdown the switcher and the grid card can
// read every second, without either of them opening its own timer or its own
// idea of what "held" means.
//
// WHY DEADLINES, NOT A DECREMENTING NUMBER: the obvious implementation —
// `secondsLeft -= 1` once a second — drifts against the server's own clock the
// moment the tab is backgrounded. A backgrounded tab throttles or fully
// suspends `setInterval` (Chrome: once a minute or less in a hidden tab), so a
// counter ticking itself down either freezes while the visitor is elsewhere or
// — worse — jumps by however many seconds it missed the instant the tab comes
// back, which reads as a glitch on a number whose entire job is to be legible.
// Deriving from an absolute deadline (`now + secondsLeft` at poll time) sidesteps
// this: whatever the wall clock says when the tab wakes IS the right answer,
// no catch-up arithmetic required. `secondsLeft` from the server is still the
// sole authority — each poll's holds array re-derives the deadline from
// scratch rather than reconciling against the client's running guess, which is
// also why a *reference-equal but re-sent* holds array (the 15s poll fires
// this) is treated as a fresh reading rather than something to diff against.
//
// The math is exported as plain functions so it is testable without mounting
// a component or a fake DOM timer; `useHolds` is the thinnest possible React
// wrapper around them (see AGENTS.md brief on this file — no renderHook idiom
// exists in this repo, so the logic lives where it can be tested directly).

export type HoldDeadlines = Record<string, number>;
export type HoldsMap = Record<string, number>;

/** Absolute deadlines (epoch ms) from a poll's holds, as of `now`. Absent or
 *  empty `holds` both produce `{}` — the contract states those are the same
 *  fact ("nothing held") and this is where that equivalence is enforced, so
 *  no caller has to re-derive it. */
export function holdDeadlines(holds: WalkinHold[] | undefined, now: number): HoldDeadlines {
  const out: HoldDeadlines = {};
  for (const hold of holds ?? []) {
    out[hold.os] = now + Math.max(0, hold.secondsLeft) * 1000;
  }
  return out;
}

/** Deadlines resolved against `now`, as whole seconds remaining. A deadline
 *  that has passed is DROPPED rather than clamped to 0 and kept: the server's
 *  reaper stops calling it held at that point, and this is the same fact
 *  played out locally between polls, so the switcher and the grid stop
 *  presenting a hold the instant it would read as a lie rather than showing
 *  a trailing "0:00" chip until the next poll catches up. */
export function tickSecondsLeft(deadlines: HoldDeadlines, now: number): HoldsMap {
  const out: HoldsMap = {};
  for (const [os, deadline] of Object.entries(deadlines)) {
    const secondsLeft = Math.round((deadline - now) / 1000);
    if (secondsLeft > 0) out[os] = secondsLeft;
  }
  return out;
}

/** "4:01" — the switcher's and the grid card's shared format for a hold's
 *  remaining time. Minutes:seconds because the whole window is single-digit
 *  minutes (~5); a station whose hold ever grew past an hour would need a
 *  different display, which is a decision for whoever retunes the window, not
 *  a silent hour-scale format this function guesses at today. */
export function formatHold(secondsLeft: number): string {
  const s = Math.max(0, secondsLeft);
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return `${m}:${String(rem).padStart(2, '0')}`;
}

/** Live `os -> secondsLeft` for every machine the caller currently holds.
 *  Ticks once a second locally; re-syncs to the server's own `secondsLeft`
 *  every time `holds` changes identity, which is every `useWalkinPools` poll
 *  (15s) whether or not the contents actually moved — see the module header
 *  for why that is the correct thing to resync on rather than something to
 *  optimise away. */
export function useHolds(holds: WalkinHold[] | undefined): HoldsMap {
  const [deadlines, setDeadlines] = useState<HoldDeadlines>(() => holdDeadlines(holds, Date.now()));
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    setDeadlines(holdDeadlines(holds, Date.now()));
  }, [holds]);

  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);

  return tickSecondsLeft(deadlines, now);
}
