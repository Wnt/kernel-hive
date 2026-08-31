// Tests for the `kh.client.class` / `kh.bundle` labelling that lives in
// spa/index.html's inline Instana bootstrap, NOT in this directory's own
// modules — see instana.ts's own tests for why: main.tsx's
// `signedOutAtTheDoor` gate skips calling `configureInstana()` for a
// signed-out /walkin visitor, but index.html's bootstrap runs unconditionally
// (before React, before that gate is even evaluated) and is what already
// beacons page-load/ajax events for exactly that visitor. Without a class/
// bundle label ON THAT SCRIPT, exactly the traffic this lab's own visitor-sim
// and browser probes produce is unlabelled in Instana.
//
// These tests run the REAL script text extracted from index.html (via Node's
// `vm` module, with `window`/`navigator`/`document`/`location` stubbed) rather
// than a hand-retyped copy of its logic — a retyped copy could drift from the
// shipped file and still pass. The class DECISION is additionally cross-
// checked against analytics/intent.ts's `clientClass()` for the same three
// cases (declared, webdriver, neither): index.html cannot import that module
// (it runs before any bundle evaluates, the same reason TELEMETRY_PATHS/
// ROUTES are duplicated there), so the two are a deliberately duplicated
// pair kept in sync by hand — this test is what would catch them drifting.

import { afterEach, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import vm from 'node:vm';
import { clientClass, __resetIntent } from './intent';

const INDEX_HTML_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../index.html',
);

/** Pull the ONE <script> block that sets up the `ineum` stub — the Instana
 *  bootstrap this whole file is about. Fails loudly (not silently matching
 *  nothing) if that script is ever renamed or split, so a future refactor
 *  breaks this test instead of leaving it passing against nothing. */
function extractBootstrapScript(): string {
  const html = readFileSync(INDEX_HTML_PATH, 'utf8');
  // index.html has several inline <script> blocks; match each one
  // separately (non-greedy per tag) rather than one big non-greedy pattern —
  // the latter backtracks across unrelated `</script><script>` boundaries
  // and can swallow HTML between two scripts into the "JS" it hands to vm.
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  const script = scripts.find((s) => s.includes('InstanaEumObject'));
  if (!script) {
    throw new Error(
      'index.html: could not find the Instana bootstrap <script> (looked for '
      + 'the block containing "InstanaEumObject") — did it move or get renamed?',
    );
  }
  return script;
}

interface RunOptions {
  /** Website key, as it would arrive after Vite's %VAR% substitution. Leave
   *  unset (or pass the literal placeholder) to simulate an unconfigured build. */
  key?: string;
  reportingUrl?: string;
  /** Build id, as Vite would substitute it. Leave unset to simulate a build
   *  where VITE_KH_BUILD_ID never resolved (defensive case; vite.config.ts
   *  always sets it today, but the guard exists for exactly this). */
  buildId?: string;
  declaredClass?: string;
  webdriver?: boolean;
}

const PLACEHOLDER = (name: string) => `%${name}%`;

/** Run the actual extracted bootstrap script in a fresh vm context and
 *  return every `ineum(...)` call it made, as plain arrays. */
function runBootstrap(opts: RunOptions = {}): unknown[][] {
  let source = extractBootstrapScript();
  source = source.replace(
    '"%VITE_INSTANA_WEBSITE_KEY%"',
    JSON.stringify(opts.key ?? PLACEHOLDER('VITE_INSTANA_WEBSITE_KEY')),
  );
  source = source.replace(
    '"%VITE_INSTANA_EUM_REPORTING_URL%"',
    JSON.stringify(opts.reportingUrl ?? PLACEHOLDER('VITE_INSTANA_EUM_REPORTING_URL')),
  );
  source = source.replace(
    '"%VITE_KH_BUILD_ID%"',
    JSON.stringify(opts.buildId ?? PLACEHOLDER('VITE_KH_BUILD_ID')),
  );

  // The shim the script installs does `s[t] || (s[t]=a, n=s[a]=fn)` with
  // `s` = `window` — in a REAL browser `window` IS the global object, so
  // `window.ineum = fn` also creates a bare global `ineum` the script's own
  // later `ineum(...)` calls resolve against. `vm`'s sandbox object plays the
  // same dual role here: it is both `window` (self-referential) and the
  // context's global object, so a property set on it is visible both as
  // `window.x` and as the bare identifier `x`.
  const sandbox: Record<string, unknown> = {
    navigator: { webdriver: opts.webdriver === true },
    document: { createElement: () => ({}), head: { appendChild: () => {} } },
    location: { pathname: '/' },
  };
  if (opts.declaredClass !== undefined) sandbox.__khClientClass = opts.declaredClass;
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);

  const ineum = sandbox.ineum as { q: IArguments[] } | undefined;
  if (!ineum) return [];
  return Array.from(ineum.q, (args) => Array.from(args as ArrayLike<unknown>));
}

/** Node 21+ already defines a read-only `globalThis.navigator` getter, so a
 *  plain assignment throws. `defineProperty` with `configurable: true`
 *  overrides it for the duration of one test; `unstubBrowserGlobals` restores
 *  a clean slate (no `window`/`navigator` at all, matching this suite's
 *  `node` test environment outside these two tests). */
function stubBrowserGlobals(
  windowProps: Record<string, unknown>,
  navigatorProps: Record<string, unknown>,
): void {
  Object.defineProperty(globalThis, 'window', { value: windowProps, configurable: true });
  Object.defineProperty(globalThis, 'navigator', { value: navigatorProps, configurable: true });
}

function unstubBrowserGlobals(): void {
  delete (globalThis as { window?: unknown }).window;
  Object.defineProperty(globalThis, 'navigator', {
    value: undefined,
    configurable: true,
    writable: true,
  });
  delete (globalThis as { navigator?: unknown }).navigator;
}

afterEach(() => {
  __resetIntent();
});

describe('index.html bootstrap — unconfigured build stays a no-op', () => {
  it('emits nothing at all with no website key configured (leading-percent placeholder, defect-4 guard)', () => {
    const calls = runBootstrap({ webdriver: true }); // even a probe signal must not leak through
    expect(calls).toEqual([]);
  });

  it('emits nothing at all with no reporting url configured', () => {
    const calls = runBootstrap({ key: 'realkey' });
    expect(calls).toEqual([]);
  });
});

describe('index.html bootstrap — kh.client.class matches analytics/intent.ts\'s clientClass()', () => {
  it('an explicit declaration wins, regardless of navigator.webdriver', () => {
    const calls = runBootstrap({
      key: 'realkey',
      reportingUrl: 'https://eum.example.test',
      declaredClass: 'probe',
      webdriver: false,
    });
    expect(calls).toContainEqual(['meta', 'kh.client.class', 'probe']);

    stubBrowserGlobals({ __khClientClass: 'probe' }, { webdriver: false });
    expect(clientClass()).toBe('probe');
    unstubBrowserGlobals();
  });

  it('navigator.webdriver === true means probe when nothing is declared', () => {
    const calls = runBootstrap({
      key: 'realkey',
      reportingUrl: 'https://eum.example.test',
      webdriver: true,
    });
    expect(calls).toContainEqual(['meta', 'kh.client.class', 'probe']);

    stubBrowserGlobals({}, { webdriver: true });
    expect(clientClass()).toBe('probe');
    unstubBrowserGlobals();
  });

  it('defaults to human with nothing declared and no webdriver flag', () => {
    const calls = runBootstrap({
      key: 'realkey',
      reportingUrl: 'https://eum.example.test',
    });
    expect(calls).toContainEqual(['meta', 'kh.client.class', 'human']);

    stubBrowserGlobals({}, { webdriver: false });
    expect(clientClass()).toBe('human');
    unstubBrowserGlobals();
  });
});

describe('index.html bootstrap — kh.bundle', () => {
  it('sends the substituted build id as kh.bundle meta', () => {
    const calls = runBootstrap({
      key: 'realkey',
      reportingUrl: 'https://eum.example.test',
      buildId: 'main@abc1234',
    });
    expect(calls).toContainEqual(['meta', 'kh.bundle', 'main@abc1234']);
  });

  it('skips kh.bundle (but still labels kh.client.class) if the build id placeholder never resolved', () => {
    const calls = runBootstrap({
      key: 'realkey',
      reportingUrl: 'https://eum.example.test',
    });
    expect(calls.map((c) => c[1])).not.toContain('kh.bundle');
    expect(calls.map((c) => c[1])).toContain('kh.client.class');
  });
});

describe('index.html bootstrap — ineum(meta, key, value) call shape', () => {
  it('calls meta with exactly one string key and one string value per entry — never an object', () => {
    const calls = runBootstrap({
      key: 'realkey',
      reportingUrl: 'https://eum.example.test',
      buildId: 'main@abc1234',
      declaredClass: 'probe',
    });
    const metaCalls = calls.filter((c) => c[0] === 'meta');
    expect(metaCalls).toContainEqual(['meta', 'kh.client.class', 'probe']);
    expect(metaCalls).toContainEqual(['meta', 'kh.bundle', 'main@abc1234']);
    for (const call of metaCalls) {
      expect(call).toHaveLength(3);
      expect(typeof call[1]).toBe('string');
      expect(typeof call[2]).toBe('string');
    }
  });
});
