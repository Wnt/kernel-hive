# Landing redesign — the contract every stream builds against

Coordinator-authored, 2026-09-10. Streams implement against THIS, not against
each other. Where this contradicts a stream's own judgement, this wins; raise it
with the coordinator instead of diverging.

## The goal

A random stranger lands, sees a **real machine already running**, drives it with
mouse and keyboard inside one second, and hits a 60-second wall that converts
into a passkey. Today the funnel is backwards: `WalkinLanding.play()` forces
passkey signup BEFORE the visitor may touch anything. We invert it.

## Route + gate

- `/` becomes the public landing page for **everyone** — stranger, walk-in and
  invited. Signed-in visitors get the same page minus the countdown and wall.
- `scripts/serve/auth/gate.py`: `/` joins `OPEN_PATHS`. A session-less stranger
  must render the landing page, NOT a 302 to `/login`.
- `/walkin` keeps working (redirect it to `/`), so no bookmark breaks.

## Server contract

### `GET /walkin/state` — extended, backward compatible
```ts
WalkinState = {
  access: 'closed' | 'invited' | 'open',
  pools: { os: string, free: number, size: number }[],
  notice?: string,
  anon?: {                       // present ONLY when the caller is role==='anon'
    budgetSeconds: number,       // 60
    remainingSeconds: number,    // counts DOWN across switches and reloads
    expired: boolean,
    heldClone?: string,          // reserved for 120s after exhaustion
  },
}
```

### `POST /walkin/claim` — `os` becomes OPTIONAL
- `{ os }` omitted → server picks a station **uniformly at random** among enabled
  pools with free capacity. This is how a visitor "gets a random station".
- Response gains `station: string` (the id actually chosen) alongside today's
  `{ clone, signalEndpoint, ttlSeconds, resumed? }`.
- **An anonymous caller may claim with no passkey.** This is the inversion.
- For an anonymous caller `ttlSeconds` is the longest the visit can still last:
  their REMAINING budget (<= 60) once the clock is running, and the un-engaged
  window on top of it before it is. Never a fresh 60. The media-plane ticket TTL
  must match the budget — the browser must not be able to outlive it by holding
  a socket open — which `POST /walkin/engage` enforces by cutting the session
  back to the budget the moment the clock starts.
- **Omitting `os` is for ARRIVAL only.** Every route back onto a machine the
  visitor already had names the station. See "Never re-roll the station".

### `POST /walkin/engage` — the visitor touched the machine
```
POST /walkin/engage  {clone}    -> {"ok": true, "anon"?: {…}}
```
- Sent once per clone, on the visitor's **first meaningful input**: a pointer
  press, a tap or a key **on the guest**. Never a mousemove, a wheel, a scroll,
  a focus or a hover.
- Starts the anonymous budget clock, and only this starts it.
- Cuts the session's TTL back to the remaining budget, and restamps the broker's
  idle window (`Broker.note_input`, whose first production caller this is).
- Refuses a clone that is not the caller's with 403 `walkin_not_yours`: the call
  names a clone and the broker's own answer to "whose is it" is the only one
  trusted.
- Fire-and-forget from the browser. The reply carries the fresh `anon` block so
  the page does not have to wait a poll interval to learn its own clock.

### The anonymous budget
- **60 seconds of connected time, per anonymous visitor, not per session,
  counted from their first meaningful input.** The clock does not start when the
  page takes a machine. It starts when the visitor touches one — an operator
  reported the difference as a bug, and it was measured on the live site:
  seventeen seconds of a stranger's minute gone before anything was touched,
  because the page auto-claims on load and the visitor was reading. Until then
  `remainingSeconds` stands still at 60, `engaged` is false, and the page says
  the clock starts on first touch.
  It carries across station switches, reloads and back-navigation.
- Server-authoritative, keyed on the anonymous visitor cookie. The client
  countdown is a MIRROR of the server's number, never the source of truth.
- Rationale: if switching stations reset the clock, a stranger could hop the
  three machines forever and never convert. Trying all three costs your minute,
  and the wall says so.
- On exhaustion: refuse further claims for that visitor with reason
  `WALKIN_ANON_BUDGET`, and **hold their last clone reserved for 120s** so that
  registering resumes THE SAME MACHINE, with their work intact.
- **Engagement is a fact about the VISITOR, not the machine.** Once they have
  touched anything, their next claim starts spending immediately — otherwise
  switching stations would buy a fresh un-touched grace every time, and a
  visitor could hold the pool for as long as they kept pressing chips.

### The un-engaged release — what pays for the rule above
A claim no longer bounds itself: with the clock stopped, nothing would ever end
the hold of a crawler, a preloaded link or a tab opened and forgotten, and every
page load takes one of 24 cells. So a machine nobody has touched goes back:

- **100 s in the browser** (`landing/heroPolicy.ts UNENGAGED_GRACE_MS`), and
  **immediately** if the tab is hidden and was never touched.
- **120 s on the server** (`auth/anon.py UNENGAGED_SECONDS`), which is the
  backstop for a client that will not — exactly the client that is not a person.
  The browser's window is deliberately shorter so the tab hands its own cell
  back first and the server rarely has to act.
- A press anywhere on the hero — a switcher chip, the call to action — buys the
  whole window again. It is proof a person is here; it is not engagement, and it
  does not start the clock.
- Releasing an un-engaged cell freezes nothing, reserves nothing and spends
  nothing. The visitor keeps their whole minute.

Why 100/120 and not 15: fifteen seconds was right while the budget was already
burning, and became the second half of the operator's bug the moment it was not.
A person reads the headline, the lede, the caption and three station chips in
well under a minute; a hundred seconds is that visit read slowly, with margin.

### Never re-roll the station
A station may change **only** when the visitor presses a switcher chip.

The page's own ways back onto a machine — the button over a stopped stage, the
hero's call to action — used to claim with no `os`, which the server answers at
random. Measured twice on the live site: `os2warp` released untouched, and one
press of the recovery button later the visitor was on `win311`.

- Random on **arrival** is the feature and stays.
- Random on **recovery** is the bug. Every recovery claim names the station that
  was on screen (`landing/heroSession.ts resumeTarget`, tested).
- What comes back is a **fresh clone** of that station — the pool never recycles
  a used one — so the copy says "a clean copy" and never implies the visitor's
  work survived.

### Switching stations
No new endpoint. Switch = `POST /walkin/release` then `POST /walkin/claim {os}`.
The budget lives on the visitor, so it survives naturally.

### After registration
`POST /walkin/signup` (existing two-step passkey ceremony, server allocates the
random handle) promotes the visitor to `role='walkin'`. The normal 1200s TTL
then applies, and a claim reattaches the held clone (`resumed: true`).

## SPA contract

- `/` above the fold: the interactive hero. Below the fold: the EXISTING
  `GridView`, which already groups by decade via `museum.era` with fold state.
  Do not rebuild decade grouping.
- The hero mounts a real stream through the existing
  `useLiveStream` / `StreamView` path, against a synthetic clone binding — copy
  the shape from `WalkinPlay.tsx:41-50 cloneBinding`.
- Auto-claim on load when the browser is capable AND the tab is visible, ONCE,
  with no `os`. Release if no MEANINGFUL input arrives within the un-engaged
  window (above), so crawlers and background tabs do not hold cells — and
  recover by re-claiming the same station, never a new one.
- Meaningful input is `pointerdown` / `mousedown` / `touchstart` / `keydown`
  (`landing/heroPolicy.ts MEANINGFUL_EVENTS`), trusted events only. It is
  explicitly NOT `mousemove`, `pointermove`, `wheel`, `scroll`, `focus` or
  hover: the machine sits directly under the headline, so a pointer travelling
  to the scrollbar crosses it on nearly every visit.
- Station switcher: three chips (the walk-in stations), showing live free/size.
- Countdown mirrors the server's `remainingSeconds`, and does not move at all
  until the server says `engaged`. Before then it shows the full budget and says
  what starts it.
- At zero: a wall over the FROZEN LAST FRAME — not a blank page. The frame the
  visitor was just driving is the strongest thing we have. Two ways through:
  "Create my passkey" (existing `walkinSignup()`) and "Sign in" (new; discoverable
  credential via `navigator.credentials.get()`).
- Capability fallback: a browser that cannot stream, or cannot make a passkey,
  gets the static poster hero and an honest line about what it needs. Never a
  broken hero.

## Hard constraints

- `spa/src/ui/grid/StreamView.tsx` is at **exactly 600 lines = the HARD
  file-size cap**. Do not add a line to it. Extract, or build alongside.
- One theme only. Every colour comes from the tokens in `spa/src/index.css`
  (`--paper`, `--ink`, `--accent`, ...). There is no dark scheme; do not add one.
- Plain global CSS, one stylesheet per feature area, BEM-ish names. No Tailwind,
  no CSS modules, no styled-components.
- Vitest runs in a **Node environment, no jsdom** — no React render tests. Put
  new logic in pure modules with `.test.ts` beside them.
- `docs/lab/walkin/CONTRACT-LEDGER.md` is the frozen endpoint contract. Update it
  in the same commit as any endpoint change.
