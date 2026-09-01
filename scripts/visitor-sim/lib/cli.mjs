// lib/cli.mjs — argument parsing, defaults, and the hard safety ceilings.
//
// The caps below are deliberately not "sensible suggestions" the rest of the
// tool can talk its way past: visitor-sim.mjs reads config.concurrency and
// config.visitors straight from here and nowhere else recomputes them.
//
// DEFAULT_OUT_DIR is anchored to THIS FILE's own directory, not the caller's
// CWD. docs/lab/VISITOR-SIM.md and this file's own --help both show the tool
// invoked as `node scripts/visitor-sim/visitor-sim.mjs …` from the repo root
// — the natural way to run it — which used to make the bare relative default
// ('./visitor-sim-runs') land in the git root. Only
// scripts/visitor-sim/visitor-sim-runs/ is gitignored, so that produced an
// UNIGNORED, untracked directory in the shared clone (AGENTS.md rule 3: the
// shared clone holds no uncommitted edits, ever). Anchoring to import.meta.url
// makes the default land in the same place regardless of invocation CWD. An
// explicitly passed --out-dir is untouched by this and stays relative to the
// CWD, as a user typing a path expects.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveInviteCode } from './invite.mjs';

const RUNS_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'visitor-sim-runs');
const DEFAULT_OUT_DIR = RUNS_DIR;
// Cached invite-derived session lands beside the run manifests — same
// already-gitignored directory (see DEFAULT_OUT_DIR's note above), one file,
// reused across runs until it is refreshed or the invite itself expires.
const DEFAULT_INVITE_STATE = path.join(RUNS_DIR, 'invite-session.json');

// WHY THESE NUMBERS. labhost runs ~71 emulated guests already (one physical
// box, docs/PUBLIC-GALLERY.md's "one relay hop... a firewall hole to one
// host's ports"). This traffic reaches it through a loopback-bound public
// listener behind a forwarder, not a CDN — there is no elastic capacity on
// the other end of a `--visitors 500`. A "visitor" here is a whole browser
// process (real WebTransport/QUIC decode, real WebGL), not an HTTP request,
// so the number that actually stresses the box is CONCURRENT contexts, not
// the total visitor count over a run — a run can walk 40 visitors through in
// half an hour at concurrency 4 and never trouble the box, but 40 at once
// would open 40 simultaneous station sessions against a fleet built for one
// visitor per exhibit.

export const CAPS = {
  // Total visitors in one run. Soft cap needs --force; hard ceiling refuses
  // outright, because a typo (`--visitors 5000` instead of `500`) should not
  // become "did I remember --force" roulette.
  visitorsSoft: 15,
  visitorsHard: 60,
  // Concurrent browser contexts. This is the number that matters for load —
  // see above.
  concurrencySoft: 6,
  concurrencyHard: 16,
  // Real passkey accounts created per run.
  walkinMaxSoft: 3,
  walkinMaxHard: 10,
  // Golden resets — disruptive to a real visitor on that station.
  resetMaxSoft: 3,
  resetMaxHard: 8,
  resetMinIntervalSecDefault: 1800,
};

const HELP = `
visitor-sim — simulate visitors clicking and typing around the kernel-hive
public gallery, with real browsers, to populate realistic Instana/analytics
data. See docs/lab/VISITOR-SIM.md for the full writeup.

USAGE
  node visitor-sim.mjs --stations <id,id,...> [options]

REQUIRED
  --stations <ids>       Comma-separated station pool the visitors may touch.
                          No default — you name the machines. Walk-in-eligible
                          ids today: win311, os2warp, rhapsody. Others need
                          --storage-state (see below) to be reachable at all.

CORE PARAMETERS
  --visitors <n>          How many simulated visitors over the run.
                           Default 3. Soft cap ${CAPS.visitorsSoft} (needs
                           --force-visitors above it), hard ceiling
                           ${CAPS.visitorsHard} (never overridable).
  --duration <time>        Spread the visitors' arrivals across this window,
                            e.g. 10m, 45s, 1h. Default 10m.
  --concurrency <n>        Max simultaneous browser contexts. Default
                            min(visitors, ${CAPS.concurrencySoft}). Soft cap
                            ${CAPS.concurrencySoft} (needs --force-concurrency),
                            hard ceiling ${CAPS.concurrencyHard}.
  --mix <spec>             Journey weights, e.g. "exhibits=40,poster=15,
                            walkin=35,station=10". Unknown/zero-weight
                            journeys are dropped. See JOURNEYS below.
  --gallery-url <url>      Default https://kernelhive.madekivi.fi

SAFETY SWITCHES (all default to the safe side)
  --allow-resets           Arm the golden-reset journey (POST /restore/<id>).
                            OFF by default. Disruptive to a real visitor on
                            that station — never assume nobody is there.
  --reset-max <n>          Resets for the WHOLE run. Default 1. Soft cap
                            ${CAPS.resetMaxSoft} (needs --force-resets), hard
                            ceiling ${CAPS.resetMaxHard}.
  --reset-min-interval <s> Minimum seconds between resets of the SAME
                            station. Default ${CAPS.resetMinIntervalSecDefault}
                            (30 min).
  --walkin-max <n>          Real passkey accounts this run may create. Default
                            1. Soft cap ${CAPS.walkinMaxSoft} (needs
                            --force-walkin), hard ceiling ${CAPS.walkinMaxHard}.
  --no-walkin               Disable the walk-in signup/play journey entirely
                             (still lets --mix include it as 0 automatically).
  --force-visitors, --force-concurrency, --force-resets, --force-walkin
                            Explicit opt-ins past the respective soft caps.
                            None of these lift a hard ceiling.
  --dry-run                Print the resolved plan and every cap check, touch
                            nothing.

CREDENTIALED MODE (optional — pick ONE of --storage-state or --invite)
  --storage-state <file>   A Playwright storageState JSON for an already
                            signed-in INVITED (viewer/admin) session — e.g.
                            exported once with 'npx playwright open
                            --save-storage=state.json <gallery-url>' after
                            signing in by hand. Unlocks the "station" journey
                            (open any pool station via the full grid, not only
                            the 3 walk-in machines) and lets --allow-resets
                            fire from a non-walk-in visitor too. Every visitor
                            context that uses it shares that ONE account —
                            documented, not hidden: this tool never creates
                            invited accounts itself.
  --invite <code-or-file>  Redeem an invite LINK's code for a session, with NO
                            passkey (docs/PUBLIC-GALLERY.md "An invite is a
                            link, and the passkey is optional") — this is how
                            an unattended run gets the "station" journey
                            without a human completing a passkey ceremony by
                            hand. A value that is an existing FILE is read and
                            trimmed (the documented case: the box's gitignored,
                            mode-600 serve/pki/sim-invite.code — keeps the
                            code out of argv/ps/shell history); anything else
                            is treated as the literal code. Redeemed AT MOST
                            ONCE: the resulting session is cached to
                            --invite-state and every later run reuses it via
                            that file, the same as a hand-exported
                            --storage-state. Not compatible with
                            --storage-state — pass one or the other.
  --invite-state <file>    Where the invite-derived session is cached. Default
                            scripts/visitor-sim/visitor-sim-runs/invite-session.json
                            (already gitignored, alongside the run manifests).
                            The invite CODE itself is never written here —
                            only the session cookie a Playwright storageState
                            captures.
  --invite-refresh          Redeem --invite again even if --invite-state
                             already has a cached session (e.g. the cached one
                             expired). Off by default — the whole point of the
                             cache is to redeem once.

JOURNEYS (what --mix names)
  exhibits   Browse /walkin/exhibits (no login needed), widen to the whole
             museum, wander cards, sometimes open a poster.
  poster     Open one station's poster/placard and read it (scroll, dwell,
             sometimes scroll back).
  walkin     Sign up for a walk-in passkey account (capped, see --walkin-max),
             play a walk-in clone from the pool, type, leave.
  station    Open a live pool station from the full grid and interact —
             occasionally a golden reset, gated by --allow-resets/--reset-max/
             --reset-min-interval exactly like every other reset in this tool.
             Requires --storage-state or --invite.

OTHER
  --headed        Run headed instead of headless (debugging). Works on
                  labhost's shared X display (DISPLAY=:1, xdesk.service) same
                  as any other Playwright tool here.
  --browser <name> 'chromium' (Playwright's bundled build, default) or
                   'chrome' (the system Chrome, channel:'chrome'). Both were
                   verified live to expose VideoDecoder, WebTransport and
                   H.264 (avc1.42E01E / avc1.640028) against the real origin —
                   pick 'chrome' only if you specifically want the system
                   browser's build.
  --out-dir <dir> Where run manifests and screenshots land. Default is
                  scripts/visitor-sim/visitor-sim-runs — anchored to this
                  tool's own directory, not wherever you ran it from, so it
                  always lands in the already-gitignored spot. Pass a path
                  explicitly and it is honoured exactly as given, relative to
                  your current working directory.
  --seed <n>      Seed the RNG for reproducible runs.
  --help          This.
`;

function parseDurationMs(s) {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)?$/.exec(String(s).trim());
  if (!m) throw new Error(`bad duration: ${s}`);
  const n = Number(m[1]);
  const unit = m[2] || 's';
  const mult = { ms: 1, s: 1000, m: 60000, h: 3600000 }[unit];
  return Math.round(n * mult);
}

function parseMix(spec, allowedJourneys) {
  const out = {};
  for (const part of spec.split(',')) {
    const [k, v] = part.split('=').map((x) => x.trim());
    if (!k) continue;
    const w = Number(v);
    if (!Number.isFinite(w) || w < 0) throw new Error(`bad mix weight for "${k}": ${v}`);
    if (!allowedJourneys.includes(k)) {
      throw new Error(`unknown journey "${k}" in --mix (known: ${allowedJourneys.join(', ')})`);
    }
    if (w > 0) out[k] = w;
  }
  return out;
}

export function parseArgs(argv) {
  const args = new Map();
  const flags = new Set([
    'allow-resets',
    'no-walkin',
    'force-visitors',
    'force-concurrency',
    'force-resets',
    'force-walkin',
    'dry-run',
    'headed',
    'invite-refresh',
    'help',
  ]);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) throw new Error(`unexpected argument: ${a}`);
    const name = a.slice(2);
    if (flags.has(name)) {
      args.set(name, true);
      continue;
    }
    const val = argv[i + 1];
    if (val === undefined) throw new Error(`--${name} needs a value`);
    args.set(name, val);
    i++;
  }
  if (args.get('help')) {
    process.stdout.write(HELP);
    process.exit(0);
  }

  if (args.has('storage-state') && args.has('invite')) {
    throw new Error('pass either --storage-state or --invite, not both — they both produce a session for this run.');
  }
  // A pending --invite counts as "will have a session" for every check below
  // that gates on credentials (mix.station, the default mix, --allow-resets'
  // effective reach) even though the session itself is not obtained until
  // main() redeems it — parseArgs stays synchronous and network-free, the
  // invite POST happens later in visitor-sim.mjs.
  const hasStorageState = args.has('storage-state') || args.has('invite');
  const allowedJourneys = ['exhibits', 'poster', 'walkin', 'station'];

  const stationsRaw = args.get('stations');
  if (!stationsRaw) {
    throw new Error('--stations is required — name the machines. See --help.');
  }
  const stations = stationsRaw.split(',').map((s) => s.trim()).filter(Boolean);
  if (stations.length === 0) throw new Error('--stations resolved to an empty pool');

  const visitors = Number(args.get('visitors') ?? 3);
  if (!Number.isInteger(visitors) || visitors < 1) throw new Error('--visitors must be a positive integer');
  if (visitors > CAPS.visitorsHard) {
    throw new Error(
      `--visitors ${visitors} exceeds the hard ceiling of ${CAPS.visitorsHard}. This is not overridable — ` +
        `run the tool more than once, spaced out, if you genuinely need more traffic than that.`,
    );
  }
  if (visitors > CAPS.visitorsSoft && !args.get('force-visitors')) {
    throw new Error(
      `--visitors ${visitors} exceeds the soft cap of ${CAPS.visitorsSoft}. Pass --force-visitors to proceed.`,
    );
  }

  const durationMs = parseDurationMs(args.get('duration') ?? '10m');

  let concurrency = args.has('concurrency') ? Number(args.get('concurrency')) : Math.min(visitors, CAPS.concurrencySoft);
  if (!Number.isInteger(concurrency) || concurrency < 1) throw new Error('--concurrency must be a positive integer');
  if (concurrency > CAPS.concurrencyHard) {
    throw new Error(`--concurrency ${concurrency} exceeds the hard ceiling of ${CAPS.concurrencyHard}.`);
  }
  if (concurrency > CAPS.concurrencySoft && !args.get('force-concurrency')) {
    throw new Error(
      `--concurrency ${concurrency} exceeds the soft cap of ${CAPS.concurrencySoft}. Pass --force-concurrency.`,
    );
  }
  concurrency = Math.min(concurrency, visitors);

  const walkinMax = args.has('walkin-max') ? Number(args.get('walkin-max')) : args.get('no-walkin') ? 0 : 1;
  if (!Number.isInteger(walkinMax) || walkinMax < 0) throw new Error('--walkin-max must be a non-negative integer');
  if (walkinMax > CAPS.walkinMaxHard) {
    throw new Error(`--walkin-max ${walkinMax} exceeds the hard ceiling of ${CAPS.walkinMaxHard}.`);
  }
  if (walkinMax > CAPS.walkinMaxSoft && !args.get('force-walkin')) {
    throw new Error(`--walkin-max ${walkinMax} exceeds the soft cap of ${CAPS.walkinMaxSoft}. Pass --force-walkin.`);
  }

  const allowResets = !!args.get('allow-resets');
  const resetMax = args.has('reset-max') ? Number(args.get('reset-max')) : 1;
  if (!Number.isInteger(resetMax) || resetMax < 0) throw new Error('--reset-max must be a non-negative integer');
  if (resetMax > CAPS.resetMaxHard) throw new Error(`--reset-max ${resetMax} exceeds the hard ceiling of ${CAPS.resetMaxHard}.`);
  if (resetMax > CAPS.resetMaxSoft && !args.get('force-resets')) {
    throw new Error(`--reset-max ${resetMax} exceeds the soft cap of ${CAPS.resetMaxSoft}. Pass --force-resets.`);
  }
  const resetMinIntervalMs = 1000 * Number(args.get('reset-min-interval') ?? CAPS.resetMinIntervalSecDefault);

  const defaultMix = hasStorageState
    ? 'exhibits=25,poster=15,walkin=25,station=35'
    : 'exhibits=45,poster=20,walkin=35';
  const mix = parseMix(args.get('mix') ?? defaultMix, allowedJourneys);
  if (mix.walkin && walkinMax === 0) delete mix.walkin;
  if (mix.station && !hasStorageState) {
    throw new Error(
      '--mix includes "station" but neither --storage-state nor --invite was given — that journey needs an invited session.',
    );
  }
  if (Object.keys(mix).length === 0) throw new Error('--mix resolved to no usable journeys — check --walkin-max/--storage-state/--invite');

  // Resets (POST /restore/<id>) fire ONLY from journeyStation
  // (lib/journeys.mjs) — a walk-in-only mix (no "station") can never use the
  // reset budget no matter how --allow-resets/--reset-max are set. Say that
  // now rather than let it arm silently; visitor-sim.mjs's printPlan repeats
  // this in the printed plan so it shows up even under --dry-run.
  const resetsCanFire = allowResets && !!mix.station;
  const resetsArmedButUnusable = allowResets && !mix.station;

  const browser = args.get('browser') ?? 'chromium';
  if (!['chromium', 'chrome'].includes(browser)) {
    throw new Error(`--browser must be "chromium" or "chrome", got "${browser}"`);
  }

  const invite = args.has('invite')
    ? {
        statePath: args.get('invite-state') ?? DEFAULT_INVITE_STATE,
        refresh: !!args.get('invite-refresh'),
        // Local, synchronous, no network: just "does a cached file already
        // exist" — safe to report in a --dry-run plan.
        willReuseCache: !args.get('invite-refresh') && fs.existsSync(args.get('invite-state') ?? DEFAULT_INVITE_STATE),
      }
    : null;

  const config = {
    galleryUrl: (args.get('gallery-url') ?? 'https://kernelhive.madekivi.fi').replace(/\/$/, ''),
    stations,
    visitors,
    durationMs,
    concurrency,
    mix,
    allowResets,
    resetsCanFire,
    resetsArmedButUnusable,
    resetMax,
    resetMinIntervalMs,
    walkinMax,
    // Explicit --storage-state stays here; a pending --invite is resolved to
    // a real path (this SAME field, mutated in place) by main() before the
    // run starts — see visitor-sim.mjs. Never the invite code itself: see
    // `inviteCode` below, deliberately NOT part of this object, because this
    // whole object is what lib/log.mjs's RunManifest serializes to disk.
    storageState: args.get('storage-state') ?? null,
    invite,
    browser,
    dryRun: !!args.get('dry-run'),
    headed: !!args.get('headed'),
    outDir: args.get('out-dir') ?? DEFAULT_OUT_DIR,
    seed: args.has('seed') ? Number(args.get('seed')) : null,
  };

  // inviteCode is intentionally NOT attached to `config` — see the comment
  // above `storageState`. It is a bearer credential
  // (docs/PUBLIC-GALLERY.md); config is what gets logged (printPlan) and
  // written verbatim into the run manifest (RunManifest.write), so it must
  // never land there. Callers destructure it out immediately and let it fall
  // out of scope once the invite is redeemed.
  const inviteCode = args.has('invite') ? resolveInviteCode(args.get('invite')) : null;

  return { config, inviteCode };
}

export { HELP };
