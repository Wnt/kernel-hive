// lib/cli.mjs — argument parsing, defaults, and the hard safety ceilings.
//
// The caps below are deliberately not "sensible suggestions" the rest of the
// tool can talk its way past: visitor-sim.mjs reads config.concurrency and
// config.visitors straight from here and nowhere else recomputes them.
//
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

CREDENTIALED MODE (optional)
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

JOURNEYS (what --mix names)
  exhibits   Browse /walkin/exhibits (no login needed), widen to the whole
             museum, wander cards, sometimes open a poster.
  poster     Open one station's poster/placard and read it (scroll, dwell,
             sometimes scroll back).
  walkin     Sign up for a walk-in passkey account (capped, see --walkin-max),
             play a walk-in clone from the pool, type, leave.
  station    Open a live pool station from the full grid and interact.
             Requires --storage-state.

OTHER
  --headed        Run headed instead of headless (debugging).
  --out-dir <dir> Where run manifests and screenshots land. Default
                  ./visitor-sim-runs (relative to CWD).
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

  const hasStorageState = args.has('storage-state');
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
    throw new Error('--mix includes "station" but no --storage-state was given — that journey needs an invited session.');
  }
  if (Object.keys(mix).length === 0) throw new Error('--mix resolved to no usable journeys — check --walkin-max/--storage-state');

  return {
    galleryUrl: (args.get('gallery-url') ?? 'https://kernelhive.madekivi.fi').replace(/\/$/, ''),
    stations,
    visitors,
    durationMs,
    concurrency,
    mix,
    allowResets,
    resetMax,
    resetMinIntervalMs,
    walkinMax,
    storageState: args.get('storage-state') ?? null,
    dryRun: !!args.get('dry-run'),
    headed: !!args.get('headed'),
    outDir: args.get('out-dir') ?? './visitor-sim-runs',
    seed: args.has('seed') ? Number(args.get('seed')) : null,
  };
}

export { HELP };
