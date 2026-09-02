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
| `--invite <code-or-file>` | Redeem an invite link's code for a session with no passkey — see "Credentialed mode". Mutually exclusive with `--storage-state`. | none |
| `--invite-state <file>` | Where the invite-derived session is cached. | `scripts/visitor-sim/visitor-sim-runs/invite-session.json` |
| `--invite-refresh` | Redeem `--invite` again even if `--invite-state` already has a cached session. | off |
| `--browser <name>` | `chromium` (Playwright's bundled build) or `chrome` (the system Chrome, `channel: 'chrome'`). | `chromium` |
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
  with it: navigates the grid, opens the station, waits for real stream
  video, moves the pointer, types a line at a human pace, dwells, and
  occasionally fires a golden reset (gated exactly like every other reset in
  this tool — see "Resets" below). **Requires `--storage-state` or
  `--invite`** — the walk-in role cannot reach the grid at all
  (`spa/src/App.tsx`), so this journey needs a real invited session. Reuses
  `scripts/e2e/station-open.mjs`'s card-resolution and stream-probe idiom and
  `scripts/e2e/typing-pace-probe.mjs`'s pacing, via `lib/stationOpen.mjs` —
  the same building blocks the `walkin` journey already used.
- **`editor`** — a scripted demo built on `station`, for **watching** and for
  populating the keyboard/click trace planes. Each visitor gets a **distinct**
  station (by visitor number, so `--visitors 6` drives 6 different machines,
  not a random 6), and on it: **skips the boot-video intro clip** (pre-marks
  `BootVideoOverlay` as played, via `suppressBootVideo`, so the demo lands on the
  live desktop instead of acting behind the clip), **resets to golden first**,
  opens a text editor
  **with the keyboard** (`Ctrl+Esc → R → notepad → Enter` on a Windows guest —
  never the Windows key, which would collide with the driving browser and, on a
  Mac, `Cmd+R`-reload the tab), types a funny line, **selects it with the
  keyboard** (`Home`/`Shift+End`/`Shift+ArrowLeft` — classic Notepad has no
  `Ctrl+A`), clicks a few random spots, and finishes with a figure-8. **Keys
  and clicks each become a discrete `input.dispatch.key` / `input.dispatch.click`
  span** — which continuous pointer motion (the figure-8) does *not* produce, so
  this is the journey that actually exercises those planes end to end. Also
  **requires `--storage-state` or `--invite`**. The editor-open recipe lives in
  `lib/editorDemo.mjs`; today it covers `win95`, `win98se`, `win2000`, `winxp`,
  `nt4`, `reactos` (any other id falls back to the same Windows Start→Run path).

If your pool has none of the three walk-in-eligible ids, the `walkin` journey
reports a clean failure rather than touching a station outside your pool —
`--stations` is the only place the touchable set is declared.

## Resets

`POST /restore/<id>` fires **only** from the `station` and `editor` journeys
(via `restoreToGolden` in `lib/journeys.mjs`) — the journeys with a real
invited session and a station actually open (`editor` resets unconditionally at
the start of each station, `station` occasionally). `--allow-resets`,
`--reset-max` and `--reset-min-interval` (see "Safety" below) all gate that
one call site: the per-run cap, the per-station cooldown, and the master
on/off switch are enforced there, not merely documented — there is no 4th,
undocumented gate on top (an earlier `&& Math.random() < 0.15` coin-flip did
sit here, and made a run that printed `resets ARMED` fire zero resets often
enough to look broken; removed). If your `--mix` has no `station` or `editor`
weight — a walk-in-only run, the tool's default without `--storage-state`/`--invite` —
passing `--allow-resets` arms a budget nothing in the run can ever spend; the
tool says so plainly, both in `--dry-run`'s printed plan and in a live run's
own log, rather than silently letting the flag sit there unused.

**The reset is driven through the real "↺ Restore to golden snapshot" button**
(StageMenu.tsx, behind the ☰ Controls menu), never a bare `fetch`. The
client-side `station.restore` / `station.restore.toRestoredMs` telemetry —
click to picture back, the one thing a server-side timer cannot measure — is
emitted by `useRestoreFlow.ts`'s `restoreToGolden()`, which is wired to
exactly that button's `onClick`. A raw `POST /restore/<id>` still resets the
host (the server times its own half regardless, `serve.restore` /
`serve.restore.reset`) but produces no `station.restore` span at all, so a
run built that way could reset a station all day and still leave the
operator's actual ask — golden-restore latency as the visitor experiences
it — unmeasured.

## Credentialed mode (optional)

Without `--storage-state` or `--invite` this tool can only reach what a
signed-out stranger can: `/walkin`, `/walkin/exhibits`, and — after a walk-in
signup — the three walk-in clones. That covers two of this brief's three
explicit asks (resetting via a walk-in session, and walk-in
registration/play) but not "opening arbitrary stations", because the
gallery's full grid requires an invited (viewer/admin) session
(`docs/PUBLIC-GALLERY.md`).

Two ways to get one, in order of preference for an unattended/repeated run:

### `--invite` — redeem an invite link's code, no passkey, no human

`docs/PUBLIC-GALLERY.md`, "An invite is a link, and the passkey is optional":
opening an invite link signs its holder in **immediately, with no passkey at
all** — `POST /auth/invite/enter {"code": "..."}` sets the session cookie on
the spot. That is a plain same-origin POST with a JSON body, nothing
WebAuthn about it, so it works identically from a script as from a browser
tab following the link by hand — verified live against the real gallery.

```sh
node visitor-sim.mjs --stations win311,irix --invite /path/to/invite.code ...
```

`--invite` takes **either** a literal code **or a path to a file containing
one** — a file is preferred whenever the code lives on a shared machine,
because it keeps the secret out of `ps`, shell history and this tool's own
argv logging, all of which a bare `--invite <code>` cannot avoid. The
box keeps exactly this file, gitignored and mode `600`:
`/data/vms/streamhost/serve/pki/sim-invite.code` — a `viewer`-role invite
named "visitor-sim (automated)", made for this tool. **It is a credential:**
never print it, log it, put it in a commit, or paste it into a chat.

The redemption happens **at most once**. The resulting session is saved as a
Playwright storage-state file (`--invite-state`, default
`scripts/visitor-sim/visitor-sim-runs/invite-session.json` — same
already-gitignored directory the run manifests live in) and every later
invocation reuses that cached file instead of redeeming again — the same
mechanism as a hand-exported `--storage-state`, just bootstrapped
automatically. That cache holds a session cookie only, never the invite code
itself (a Playwright storage-state is cookies + origin storage; the POST body
that minted it is never part of that shape) — verified by inspecting the
saved file after a live redemption. Pass `--invite-refresh` to force a fresh
redemption (e.g. the cached session expired).

**When it expires:** this invite's session is capped at the invite's own
expiry while it carries no passkey (`docs/PUBLIC-GALLERY.md`) —
**2026-09-08**, unless a passkey is added to the account first (which turns
it into an ordinary long-lived session, but then needs a human to complete a
passkey ceremony once). When it lapses, mint a fresh one the normal way: sign
in as any admin, go to `/admin` → **People**, issue a new invite (role
`viewer` is enough — this tool only ever reads and interacts, never manages
people), copy its code, and overwrite `sim-invite.code` on the box (or point
`--invite` at wherever you saved the new one). Delete the stale
`--invite-state` cache file too, or pass `--invite-refresh`, so a run doesn't
try the old cookie first.

### `--storage-state` — an already-signed-in session, exported by hand

The original mechanism, still available and still the right choice for a
one-off interactive run where you're already sitting at a signed-in browser:

```sh
npx playwright open --save-storage=state.json https://kernelhive.madekivi.fi
# complete the passkey sign-in in the window that opens, then close it
node visitor-sim.mjs --stations win311,irix --storage-state state.json ...
```

`--storage-state` and `--invite` are mutually exclusive — pick one; both
produce exactly the same thing (a session the `station` journey and
non-walk-in resets can use), so pairing them is refused rather than silently
preferring one.

Every simulated visitor context that uses a credentialed session (either
form) shares that **one** account — this tool never creates invited accounts,
only walk-in ones, and that is a deliberate scope limit, not an oversight.

## Browser choice

`--browser chromium` (default, Playwright's bundled build) or `--browser
chrome` (the system Chrome, `channel: 'chrome'`). Both were verified live
against the real gallery origin to expose `VideoDecoder`, `WebTransport` and
H.264 (`avc1.42E01E`, `avc1.640028`) — either is a viable choice for every
journey in this tool, including `station`'s live stream decode. `--headed`
works with either browser on this box's shared X display (`DISPLAY=:1`,
`xdesk.service`), the same as any other Playwright tool here.

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
- **Any failed journey — consecutive or not — is counted and exits non-zero.**
  The run summary line (`finished: N visitor(s), F failed, …`) counts every
  journey whose result was `ok:false`, whether or not it threw an exception
  (`manifest.errors` is exceptions only — a journey that returns a clean
  `ok:false`, like a card the grid never rendered, never touches that count).
  Each failed journey is also logged individually and recorded in the run
  manifest (`failedVisitorCount`, and `ok:false` on its own entry in
  `visitors[]`), and the process exits 1 if `F > 0`, even when the breaker
  never trips.
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
  touched; it is local to your machine and is never sent anywhere. It never
  holds an invite code (see "Credentialed mode" above) — only the resolved
  storage-state file path, if one was used.
- **A cached invite session**, `--invite-state` (default
  `visitor-sim-runs/invite-session.json`), only if `--invite` was passed. A
  Playwright storage-state file — a session cookie, nothing else — reused by
  every later run until `--invite-refresh` or the session itself expires.
  Delete it to force a clean redemption next time; leaving it is harmless.
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

**`station` journey, added later, also run live** — `--stations win311 --mix
"station=100" --visitors 1 --invite /data/vms/streamhost/serve/pki/sim-invite.code`:
the invite redeemed for a `viewer` session with no passkey (`role=viewer`,
7 days left at the time), the storage-state cache was written and confirmed
to hold a session cookie only (no code — inspected the saved JSON directly),
`win311` opened from the full grid, went live, was typed at and clicked, and
the run completed `ok:true` with no exceptions. A second, immediate run with
the same `--invite` reused the cached session (logged `reusing cached invite
session`, no second redemption) and drove the **same** station journey to the
same result — proving the "redeem once" cache actually works, not just that
the mechanism works once. See the session that added invite/station support
for the exact commands and output.

Note for whoever runs this next: a serving-plane restart empties the walk-in
clone pools (rebuilt one at a time, several minutes) — check `pools=` in
`/data/vms/streamhost/serve/https-server.log` before reading an immediate
`walkin`-journey failure as a bug. The `station` journey above does not touch
the walk-in pool at all (it opens a station from the invited grid, not a
walk-in clone), so it is unaffected by that warm-up window.

## What was reused from existing tooling, and what is new

- **`scripts/e2e/station-open.mjs`'s resolution rules** (find a card by
  `href$="/os/<id>"`, never by text; assert the SPA actually navigated before
  waiting on video; the offscreen-canvas stream probe) are reused near-verbatim
  in `lib/stationOpen.mjs`, trimmed for the public origin — this is what both
  the `walkin` and `station` journeys open a live station through.
- **`scripts/e2e/typing-pace-probe.mjs`'s human-pace reasoning** (overlapping
  key edges around 5-8 chars/s, not a clean scripted burst) is reused as
  `typeHumanPace()` in the same module, used by both journeys.
- **`tests/e2e-live/e2e/publicAuth.spec.ts`'s CDP virtual authenticator**
  (`WebAuthn.addVirtualAuthenticator`, resident-key, auto-presenting) is reused
  verbatim in `lib/webauthn.mjs` for the walk-in signup journey — a genuine
  WebAuthn ceremony, not a stub.
- **New, because nothing existing fit:** a Node package installable from a
  plain checkout with no lab-side dependency (`scripts/e2e/*.mjs` assume a
  `~/e2e/node_modules` on CT950 and a LAN address); the journey/mix model;
  the safety gates (`lib/safety.mjs`); the run manifest; the
  `kh.client.class` Instana meta this tool's existence made necessary
  (`spa/src/analytics/instana.ts`); and `lib/invite.mjs`, which redeems an
  invite link's code (`POST /auth/invite/enter`, no passkey) and caches the
  resulting session as a Playwright storage-state — nothing existing needed
  an unattended, non-interactive way into an invited session before this
  tool's `station` journey did.

## beacon-probe — the diagnostic beside the traffic generator

`scripts/visitor-sim/beacon-probe.mjs` shares this package's Playwright install
and its cached invite session, but it is the opposite kind of tool: visitor-sim
*makes* traffic, beacon-probe *reads one page load in full detail*.

It drives a single credentialed page load, captures every beacon the Instana EUM
agent POSTs to the vendor's reporting host, decodes the tab-separated wire format,
and then answers the question no document can:

- does the `ty pl` (page-load) beacon carry a `backendTraceId`, and does that id
  **exist** in `traces.db`?
- do the `ty xhr` beacons still resolve too — i.e. did a change to the page-load
  path regress the in-page correlation that already worked?
- does our outbound `traceparent` reach the wire as one clean value, or has a
  second writer comma-joined it (`spa/src/analytics/khFetch.ts`)?

It resolves ids against the store itself (`/data/vms/streamhost/serve/traces.db`,
bind-mounted, read-only) and exits non-zero on a failure, so it can be used as an
acceptance check rather than something to eyeball.

```sh
cd scripts/visitor-sim
node beacon-probe.mjs                                   # public gallery
node beacon-probe.mjs --url https://<SH_HOST_IP>:8443 --insecure   # LAN origin
node beacon-probe.mjs --json /tmp/capture.json          # keep the raw beacons
node beacon-probe.mjs --traces-db ''                    # off-box: capture only
```

**Run it after any change to** the `<meta name="traceparent">` injection
(`scripts/serve/static_files.py`), the `traceresponse` / `Server-Timing` headers
(`scripts/serve/tracing_http.py`), the `ineum(...)` bootstrap in
`spa/index.html`, or the pinned EUM agent version. The correctness argument for
all of those is a beacon on the wire and nothing else —
`docs/lab/INSTANA-VIEW-INVENTORY.md` §7a records what that measurement found and
why the vendor's own documentation could not be used.

Two things that will otherwise read as faults and are not: a beacon for a route
outside the tracing allowlist (`gallery-manifest.json`, `boot/index.json`) has
**no** `bt`, correctly — there is no server span to point at; and an anonymous
run captures the *login page's* beacons, because the gallery answers 401 to an
unauthenticated `/`. Always pass a session.
