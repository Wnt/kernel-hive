# visitor-sim — simulated visitors, from your Mac, against the public gallery

`scripts/visitor-sim/` drives real browsers around **https://kernelhive.madekivi.fi**
(or any other kernel-hive origin you point it at) to produce realistic
click/type/dwell traffic — the goal being data in Instana and in kernel-hive's
own analytics plane (`docs/ANALYTICS.md`) that looks like a gallery being
visited, not a hit counter. It runs from a plain checkout on your own machine:
no `ssh lab`, no lab-side tooling, nothing installed on the box.

**Read this whole page before your first real run**, especially "Safety" and
"What this creates". `--dry-run` first is not optional advice, it is the
first command below.

## Why a browser, not a fetch script

Instana's data comes entirely from the JavaScript EUM agent that runs inside
a real browser tab (`spa/src/analytics/instana.ts`). A script that only issues
HTTP requests produces **zero** Instana beacons — it never runs the agent,
never paints a page, never fires a `pointerdown`. Every journey below is
driven with Playwright's Chromium, real navigation, real clicks, real typed
keystrokes.

## Setup, on your Mac

```sh
git clone https://github.com/Wnt/kernel-hive.git
cd kernel-hive/scripts/visitor-sim
npm install                 # pulls Playwright
npx playwright install chromium
node visitor-sim.mjs --help
```

Nothing here needs the rest of the repo's toolchain (no Rust, no Python venv,
no lab SSH key) — `scripts/visitor-sim` is a self-contained Node package.

## First run — always this, before anything larger

```sh
node visitor-sim.mjs --stations win311,os2warp --visitors 2 --duration 3m --dry-run
```

This prints the resolved plan (every cap, every switch, every journey weight)
and touches nothing. Read it, then drop `--dry-run` for a real but tiny run:

```sh
node visitor-sim.mjs --stations win311,os2warp --visitors 2 --duration 3m
```

## Parameters

Run `node visitor-sim.mjs --help` for the authoritative, current list — this
section is the narrative version, and the CLI text is what actually enforces
the numbers.

| Flag | Meaning | Default |
|---|---|---|
| `--stations <ids>` | **Required.** Comma-separated pool of station ids the run may touch. There is no "all stations" default — you name the machines, always. |
| `--visitors <n>` | Total simulated visitors over the run. | 3 |
| `--duration <time>` | Window the visitors' arrivals are spread across (`10m`, `45s`, `1h`). | 10m |
| `--concurrency <n>` | Max simultaneous browser contexts — the number that actually stresses the box (see "Concurrency" below). | `min(visitors, 6)` |
| `--mix <spec>` | Journey weights, e.g. `exhibits=40,poster=15,walkin=35,station=10`. | depends on `--storage-state` (below) |
| `--gallery-url <url>` | The origin to drive. | `https://kernelhive.madekivi.fi` |
| `--allow-resets` | Arms the golden-reset journey (`POST /restore/<id>`). | **off** |
| `--reset-max <n>` | Resets for the whole run. | 1 |
| `--reset-min-interval <s>` | Minimum seconds between two resets of the *same* station. | 1800 (30 min) |
| `--walkin-max <n>` | Real passkey accounts this run may create. | 1 |
| `--no-walkin` | Disable the walk-in journey entirely. | off |
| `--storage-state <file>` | An invited (viewer/admin) Playwright storage-state file — see "Credentialed mode". | none |
| `--seed <n>` | Seed the RNG, for a reproducible run. | random |
| `--headed` | Watch it happen instead of running headless. | headless |
| `--out-dir <dir>` | Where the run manifest lands. An explicit path is honoured exactly as given, relative to your CWD. | `scripts/visitor-sim/visitor-sim-runs` (anchored to the tool's own directory, not your CWD — see below) |
| `--dry-run` | Print the plan, touch nothing. | — |

## The journeys (what `--mix` names)

Real visitors dwell, read, wander and type in bursts — a tight loop of
identical actions would teach this lab the wrong things about its own
telemetry, which is the whole reason this tool exists. Every journey below is
built from randomized human-paced dwells around a handful of deliberate acts,
never a fixed-interval hammer, and each simulated visitor runs **one** journey
per session (arrival → journey → departure), the way one visit to a museum is
one visit.

- **`exhibits`** — `/walkin/exhibits`, no login required. Scrolls the grid,
  sometimes opens a placard and reads it, sometimes scrolls back up.
- **`poster`** — opens one **specific** pool station's placard (resolved by id
  → display name against the public `/walkin/manifest.json`) and reads it at a
  plausible pace, including occasional scroll reversals.
- **`walkin`** — the walk-in door end to end: signs up for a real passkey
  account (via a genuine CDP virtual WebAuthn authenticator — see "Passkeys",
  below), plays a clone of a pool station that is walk-in-eligible
  (`win311`, `os2warp`, `rhapsody`), types a short line at a human pace,
  clicks **Leave** (which releases the clone). Gated by `--walkin-max`.
- **`station`** — opens *any* pool station from the full grid and interacts
  with it (typing, pointer movement, occasionally a golden reset). **Requires
  `--storage-state`** — the walk-in role cannot reach the grid at all
  (`spa/src/App.tsx`), so this journey needs a real invited session.

If your pool has none of the three walk-in-eligible ids, the `walkin` journey
reports a clean failure rather than touching a station outside your pool —
`--stations` is the only place the touchable set is declared.

## Credentialed mode (optional)

Without `--storage-state` this tool can only reach what a signed-out stranger
can: `/walkin`, `/walkin/exhibits`, and — after a walk-in signup — the three
walk-in clones. That covers two of this brief's three explicit asks (resetting
via a walk-in session, and walk-in registration/play) but not "opening
arbitrary stations", because the gallery's full grid requires an invited
(viewer/admin) session (`docs/PUBLIC-GALLERY.md`).

To unlock the `station` journey (and let resets fire from a non-walk-in
visitor), sign in by hand once and export the session:

```sh
npx playwright open --save-storage=state.json https://kernelhive.madekivi.fi
# complete the passkey sign-in in the window that opens, then close it
node visitor-sim.mjs --stations win311,irix --storage-state state.json ...
```

Every simulated visitor context that uses `--storage-state` shares that **one**
account — this tool never creates invited accounts, only walk-in ones, and
that is a deliberate scope limit, not an oversight.

## Safety

This drives real hardware behind a public edge (`docs/PUBLIC-GALLERY.md`'s
forwarder path onto one physical box already running ~71 emulated guests).
Every switch below defaults to the safe side.

- **`--stations` is required, never "all".** There is no default pool.
- **Resets are OFF by default.** `POST /restore/<id>` is disruptive to any real
  visitor on that station — it is never assumed nobody is there. `--allow-resets`
  arms it; `--reset-max` (default 1, hard ceiling 8) and
  `--reset-min-interval` (default 30 min per station) bound how often it fires
  even once armed.
- **Walk-in signups are capped**, `--walkin-max` (default 1, hard ceiling 10).
  These are real passkey accounts (`scripts/serve/auth/walkin.py`) — see
  "Cleanup" below.
- **Concurrency, not visitor count, is the number that stresses the box.** A
  "visitor" here is a whole browser process doing real WebTransport/QUIC
  decode; `--visitors` arrivals are spread across `--duration` and bounded at
  any instant by `--concurrency` (default `min(visitors, 6)`, soft cap 6, hard
  ceiling 16 — not overridable past that). `--visitors` itself has a soft cap
  of 15 (`--force-visitors` to exceed) and a hard ceiling of 60 that no flag
  lifts — run the tool again, spaced out, rather than asking for more in one
  shot.
- **A failure breaker stops the run.** Five consecutive failed journeys (a
  station that never streams, a signup that never lands) trips it; every
  visitor still queued is skipped rather than hammering a broken gallery, and
  the process exits non-zero.
- **`--dry-run` prints the resolved plan — every cap, every switch, every
  journey weight — and touches nothing.**

## Marking the traffic — so it does not poison the data it exists to produce

`docs/ANALYTICS.md` §4 already has this exact problem for the lab's own e2e
fleet: `navigator.webdriver === true` self-labels automation as `class:'probe'`
in kernel-hive's own analytics store (`spa/src/analytics/intent.ts`), and the
report defaults to `human` only. This tool relies on that, **and** declares
itself explicitly, belt and braces:

1. **Braces (fallback):** Playwright's Chromium sets `navigator.webdriver =
   true` on its own — `visitor-sim.mjs` reads it back after every page load and
   prints a warning if it were ever false, so a launcher change that broke the
   fallback would not go unnoticed.
2. **Belt (explicit declaration):** every visitor context runs
   `context.addInitScript(() => { window.__khClientClass = 'probe'; })`
   **before** any bundle script executes — the same mechanism
   `analytics/intent.ts`'s header documents for a rig that wants to declare
   itself, so this reads exactly as any other probe in the fleet does.

Both mechanisms feed **one** dimension, `class`, and it now reaches Instana
too, not only kernel-hive's own store: `configureInstana()`
(`spa/src/analytics/instana.ts`) sends `ineum('meta', 'kh.client.class',
clientClass())` on every configured tab. Filter it in Instana's UI on the
`kh.client.class` custom meta field — `probe` is this tool (and the CT950 e2e
fleet); its absence, or `human`, is everything else.

**Verified end to end**, not merely written: `spa/src/analytics/instana.test.ts`
pins the call shape (`configureInstana('sess1')` with `window.__khClientClass
= 'probe'` produces `ineum('meta', 'kh.client.class', 'probe')`), a low-volume
live run (see below) confirmed `navigator.webdriver === true` holds under the
Chromium build Playwright installs, and the same run's browser console showed
no warning about the fallback. Reading the beacon back out of Instana's own UI
needs an Instana session, which this tool does not have — the operator is the
one who can open Instana and confirm the `kh.client.class` meta field appears
on the beacons from a run's time window; this doc states what to look for
rather than claiming a screenshot never taken.

## What this creates, and how to clean it up

- **Real walk-in passkey accounts** (`--walkin-max`, default 1 per run). Each
  run writes its created handles to the run manifest (see below) and prints
  them at the end:
  `walk-in handles created this run: bold-turing, quiet-hopper`.
  Remove them from `/admin` → **People** (any admin account), or leave them —
  `scripts/serve/auth/walkin.py`'s idle reaper deletes a walk-in account
  automatically after 90 days with no sign-in (`IDLE_EXPIRY_DAYS`), so an
  unattended run's accounts do not accumulate forever even if nobody cleans up
  by hand.
- **Golden resets**, only if `--allow-resets` was passed. Non-destructive by
  the endpoint's own design (`scripts/serve/restore.py`: `loadvm`-restores or
  cold-boots, never `savevm`) but disruptive in the moment to anyone actually
  on that station. The run manifest lists every station reset and when.
- **A run manifest**, `<out-dir>/run-<timestamp>.json` — the config used, every
  visitor's journey/outcome, every reset, every walk-in handle created, every
  error. This is the one place to look after a run to know exactly what it
  touched; it is local to your machine and is never sent anywhere.
- **Nothing else.** No station state is force-changed outside the reset
  action above; a `station` journey's typing/clicking is ordinary guest input,
  indistinguishable after the fact from a real visitor's.

## Concurrency, restated plainly

One physical box runs the whole fleet (~71 emulated guests) behind a
loopback-bound public listener (`docs/PUBLIC-GALLERY.md`). There is no elastic
capacity on the other end of a careless `--visitors 500`. `--concurrency` is
what bounds simultaneous load — a run can walk 40 visitors through over half
an hour at concurrency 4 without the box noticing, but 40 *at once* would open
40 simultaneous station sessions against a fleet built around one visitor per
exhibit. The defaults are conservative on purpose; raise them deliberately
(`--force-concurrency`, `--force-visitors`) and watch the gallery while you do.

## Low-volume test evidence

Run against the live public gallery, `--stations win311,os2warp --visitors 2
--duration 3m`, resets disabled (the default), `--walkin-max` at its default
of 1: two simulated visitors completed (`exhibits` and `walkin` journeys under
the tool's default no-credential mix), one real walk-in passkey account was
created and its handle recorded in the run manifest, `navigator.webdriver`
read back `true` on every page, and the run manifest + console log confirmed
both journeys' outcomes with no exceptions. See the session that built this
tool for the exact command and its output; the manifest shape is what
`lib/log.mjs`'s `RunManifest` class documents at the top of this file's
package.

## What was reused from existing tooling, and what is new

- **`scripts/e2e/station-open.mjs`'s resolution rules** (find a card by
  `href$="/os/<id>"`, never by text; assert the SPA actually navigated before
  waiting on video; the offscreen-canvas stream probe) are reused near-verbatim
  in `lib/stationOpen.mjs`, trimmed for the public origin.
- **`scripts/e2e/typing-pace-probe.mjs`'s human-pace reasoning** (overlapping
  key edges around 5-8 chars/s, not a clean scripted burst) is reused as
  `typeHumanPace()` in the same module.
- **`tests/e2e-live/e2e/publicAuth.spec.ts`'s CDP virtual authenticator**
  (`WebAuthn.addVirtualAuthenticator`, resident-key, auto-presenting) is reused
  verbatim in `lib/webauthn.mjs` for the walk-in signup journey — a genuine
  WebAuthn ceremony, not a stub.
- **New, because nothing existing fit:** a Node package installable from a
  plain checkout with no lab-side dependency (`scripts/e2e/*.mjs` assume a
  `~/e2e/node_modules` on CT950 and a LAN address); the journey/mix model;
  the safety gates (`lib/safety.mjs`); the run manifest; and the
  `kh.client.class` Instana meta this tool's existence made necessary
  (`spa/src/analytics/instana.ts`).
