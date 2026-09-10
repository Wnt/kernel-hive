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
- For an anonymous caller `ttlSeconds` = the visitor's REMAINING budget (<= 60),
  never a fresh 60. The media-plane ticket TTL must match — the browser must not
  be able to outlive the budget by holding a socket open.

### The anonymous budget
- **60 seconds of connected time, per anonymous visitor, not per session.**
  It carries across station switches, reloads and back-navigation.
- Server-authoritative, keyed on the anonymous visitor cookie. The client
  countdown is a MIRROR of the server's number, never the source of truth.
- Rationale: if switching stations reset the clock, a stranger could hop the
  three machines forever and never convert. Trying all three costs your minute,
  and the wall says so.
- On exhaustion: refuse further claims for that visitor with reason
  `WALKIN_ANON_BUDGET`, and **hold their last clone reserved for 120s** so that
  registering resumes THE SAME MACHINE, with their work intact.

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
- Auto-claim on load when the browser is capable AND the tab is visible.
  Release aggressively if no input arrives within ~15s, so crawlers and
  background tabs do not hold cells.
- Station switcher: three chips (the walk-in stations), showing live free/size.
- Countdown mirrors the server's `remainingSeconds`.
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
