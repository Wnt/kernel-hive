// ============================================================================
//  streamhostInput.group.ts — the streamhost tiles under input regression.
//  ---------------------------------------------------------------------------
//  SHARED FACTS COME FROM THE GOLDEN MANIFEST (de-drifted 2026-07-14): per-tile
//  `tileDir` / `pointer` / `touch` / `resetMode` / `snapshot` are READ AT LOAD
//  from the RENDERED golden manifest (stations-registry.py; the copy deployed to
//  `/data/vms/streamhost/serve/golden-manifest.json` is what reset-tile.sh and
//  the SPA restore endpoint read). This file keeps only the TEST-SIDE fields:
//
//    osId        — the SPA OS id (drives ?streamhost=<osId> + /signal/<osId>.json
//                  + the grid card + POST /restore/<osId>). NOTE two tiles differ
//                  from their tile DIR (identical since the 2026-08-10 rename).
//    displayName — museumCatalog displayName (grid card aria-label prefix).
//    keyType     — literal string typed through the guest for the keyboard probe.
//    mouseSkip / keyboardSkip — set ONLY for a KNOWN, MEASURED limitation where a
//                  reaction cannot be pixel-verified off the QMP framebuffer even
//                  though input IS delivered (uncaptured HW cursor, a text console
//                  with no pointer, an unfocused desktop with no keyboard echo, or
//                  a continuously animating desktop). When such a flag is set, the
//                  suite still SENDS the input and proves decode + control-channel,
//                  records the measured diff, and SKIPs the gate for THAT channel —
//                  it does NOT fake a pass or a fail. A flagged channel that DOES
//                  react anyway (run-to-run variance) is still reported PASS; the
//                  flag is only a floor, never a ceiling. Channels with NO flag are
//                  GATED: a lost reaction there fails the test (regression sentinels).
//
//  Skip reasons below are the MEASURED outcome of the calibrated on-host run
//  (see streamhostInput.README.md → "Per-title results"). The split is purely
//  about whether a given channel renders a pixel-verifiable reaction into the
//  guest's VGA framebuffer.
//
//  VISUALLY CALIBRATED: every gated (non-skip) channel below was certified by an
//  agent that drove the REAL deployed SPA path and read the guest's before/after
//  QMP screendumps BY EYE (multimodal), from the tile's golden fixture. Tiles whose
//  gated set grew (win311, win98se, kolibrios-mouse, helenos-keyboard, android-
//  keyboard) did so BECAUSE a golden fixture now presents a focused editor/terminal
//  — which only holds if the suite RESETS TO GOLDEN before the run (the default).
// ============================================================================

import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export interface InputTileSpec {
  osId: string;
  displayName: string;
  tileDir: string;
  pointer: 'abs' | 'rel';
  touch?: boolean;
  keyType?: string;
  resetMode: 'loadvm' | 'restart';
  snapshot?: string;
  mouseSkip?: string;
  keyboardSkip?: string;
}

// ---------------------------------------------------------------------------
//  Golden manifest — the single shared source of per-tile infrastructure facts.
//  Search order: explicit env override → the repo copy (three levels up from
//  tests/e2e-live/e2e/) → the deployed box copy (when the suite is rsynced to
//  the host without the full repo, e.g. /data/streamhost-input-test).
// ---------------------------------------------------------------------------
interface ManifestTile {
  tileDir: string;
  pointer: 'abs' | 'rel';
  touch: boolean;
  resetMode: 'loadvm' | 'restart';
  snapshot: string | null;
  mouse: string;
  keyboard: string;
  fixture: string;
}
interface GoldenManifest { _comment: string; tiles: Record<string, ManifestTile>; }

function loadGoldenManifest(): GoldenManifest {
  // The manifest has no committed copy: it is rendered from the registry. From a
  // checkout, render it (that is the current truth by construction); on the box
  // without one, read the published document; GOLDEN_MANIFEST still wins.
  if (process.env.GOLDEN_MANIFEST) {
    return JSON.parse(readFileSync(process.env.GOLDEN_MANIFEST, 'utf8')) as GoldenManifest;
  }
  const registry = fileURLToPath(new URL('../../../scripts/stations-registry.py', import.meta.url));
  if (existsSync(registry)) {
    const rendered = spawnSync('python3', [registry, 'emit', 'golden-manifest.json'], {
      encoding: 'utf8',
      maxBuffer: 32 * 1024 * 1024,
    });
    if (rendered.status === 0) return JSON.parse(rendered.stdout) as GoldenManifest;
    throw new Error(`rendering golden-manifest.json failed: ${rendered.stderr ?? ''}`);
  }
  const published = '/data/vms/streamhost/serve/golden-manifest.json';
  if (existsSync(published)) return JSON.parse(readFileSync(published, 'utf8')) as GoldenManifest;
  throw new Error(
    `golden-manifest.json not found (no checkout to render from, and ${published} is absent). ` +
    'Set GOLDEN_MANIFEST=/path/to/golden-manifest.json.',
  );
}

export const GOLDEN_MANIFEST: GoldenManifest = loadGoldenManifest();

// TEST-SIDE OVERRIDES of manifest facts that are CERTIFIED NEWER than the shared
// manifest copy. Remove an entry once the box manifest itself is refreshed.
//   qnx — tablet-free re-bake + bounded relative input (verified live 2026-07-14,
//         branch feat/pointer-flags-live): the tile is now a PS/2 RELATIVE pointer
//         with real 1:1 tracking; the manifest still carries the tablet-era
//         "pointer": "abs".
// Empty today — add an entry ONLY while the repo/box golden-manifest lags a
// live re-bake (e.g. qnx rode here until the manifest recorded its rel re-bake).
const MANIFEST_OVERRIDES: Record<string, Partial<ManifestTile>> = {};

// ---------------------------------------------------------------------------
//  Test-only per-tile table (keyType + measured skip flags). Shared facts merge
//  in from the manifest below.
// ---------------------------------------------------------------------------
interface TestOnlySpec {
  osId: string;
  displayName: string;
  keyType?: string;
  mouseSkip?: string;
  keyboardSkip?: string;
}

const NO_ECHO = 'unfocused desktop: no text field has keyboard focus, so the guest renders no echo/selection change into the framebuffer; keys ARE delivered (control channel open, verified on tiles that echo).';
const UNCAPTURED_CURSOR = 'the guest draws its pointer as an uncaptured hardware overlay and opens no menu on a synthetic click, so pointer motion does not change the captured VGA framebuffer; input IS delivered (control channel open).';
const TEXT_CONSOLE = 'boots to a text console with no pointer/cursor rendered into the captured framebuffer; there is no interactive surface for the mouse to change.';
const BRIDGE_UNVERIFIED = 'emulator-bridge tile: input verdicts not yet pixel-certified (golden-manifest UNVERIFIED). Input IS sent and decode/control/reset are fully gated; the reaction gate is a floor, never a ceiling — certify, then remove this flag.';

const TEST_SPECS: TestOnlySpec[] = [
  { osId: 'reactos',     displayName: 'ReactOS 0.4.14',            keyType: 'a' },
  { osId: 'tinycore',    displayName: 'Tiny Core Linux',          keyType: 'ls\n',
    keyboardSkip: 'Tiny Core boots to the FLWM X desktop (not a shell); with no terminal window focused, typed text has nowhere to echo (reaction depends on a leftover terminal — 1.1e-2 with one, 0 without). Keys ARE delivered (control channel open).' },
  { osId: 'alpine',      displayName: 'Alpine Linux',             keyType: 'ls\n',
    mouseSkip: `Alpine ${TEXT_CONSOLE}` },
  // GOLDEN FIXTURE (VMID 90): boots to Notepad maximized+focused (see the tile's
  // GOLDEN.md). That gives BOTH channels a pixel-verifiable surface on the QMP
  // framebuffer, so the pre-golden Program-Manager skips no longer apply — both are
  // now GATED regression sentinels. Visually certified on the real SPA path
  // (before/after read by a human): a homed relative-cursor click on "File" opens
  // the dropdown; ArrowDown/Up move the File-menu selection; 'a' echoes at the caret;
  // Esc dismisses the menu. Deterministic, region-calibrated per-input assertions
  // live in certify-op48/win311.golden.spec.ts. RESET-TO-GOLDEN (default) starts it
  // from the fixture; both channels are gated.
  { osId: 'win311',      displayName: 'Windows 3.11',             keyType: 'a' },
  { osId: 'win95',       displayName: 'Windows 95',               keyType: 'a' },
  // GOLDEN FIXTURE (VMID 92): boots to a Win98 SE desktop with an ACTIVE/focused
  // "Untitled - Notepad" (steady caret on the "Type below:" line). That gives BOTH
  // channels a pixel-verifiable surface on the QMP framebuffer, so both are GATED
  // regression sentinels (no skips). Visually certified on the real SPA path
  // (before/after read by a human): slamming the relative cursor into the bottom-left
  // Start corner + click deactivates Notepad (title bar blue->gray); Alt+F then
  // ArrowDown/Up move the File-menu selection New<->Open (and ArrowUp also moves the
  // Notepad caret up a line); 'a' echoes at the caret; Esc dismisses the File dropdown.
  // Deterministic, region-calibrated per-input assertions live in
  // certify-win98/win98se.golden.spec.ts. RESET-TO-GOLDEN (default) starts from fixture.
  { osId: 'win98se',     displayName: 'Windows 98 SE',            keyType: 'a' },
  { osId: 'win2000',     displayName: 'Windows 2000',             keyType: 'a',
    mouseSkip: `Windows 2000 desktop: ${UNCAPTURED_CURSOR}` },
  // NEEDS RECERTIFICATION (2026-07-14): the winxp golden is now the BLISS BOOT-VIDEO
  // fixture (clean desktop for the boot-clip handoff, spa 51a0ed3) — the previously
  // certified keyboard gate expected an empty focused Notepad (caret at Line 1 Col 1)
  // that no longer exists, so an ungated run would false-FAIL. Keys ARE delivered;
  // the flag below skips the gate honestly (floor, not ceiling — a reaction still
  // reports PASS) until the keyboard surface is re-certified against the new fixture.
  { osId: 'winxp',       displayName: 'Windows XP',               keyType: 'a',
    keyboardSkip: 'NEEDS RECERTIFICATION: winxp golden changed to the Bliss boot-video fixture (2026-07-13) — no focused Notepad caret remains, so the previously certified keyboard echo surface is gone. Keys ARE delivered (control channel open); re-certify against the new fixture, then re-gate.' },
  { osId: 'freedos',     displayName: 'FreeDOS',                  keyType: 'dir\n',
    mouseSkip: `FreeDOS ${TEXT_CONSOLE}` },
  { osId: 'ninefront',   displayName: '9front (Plan 9)',          keyType: 'ls\n',
    keyboardSkip: `9front rio: no window holds keyboard focus for the typed line, so nothing echoes; ${NO_ECHO}` },
  // GOLDEN FIXTURE (VMID 97): boots to a KolibriOS desktop with TINYPAD 4.1 open,
  // focused, on an empty "Untitled" document (steady non-blinking caret at 1,1), a
  // bottom-left "Menu" button, and the clock/CPU-meter turned off so idle is
  // byte-identical (the pre-golden "continuously-animating desktop" is gone). Both
  // channels have a pixel-verifiable surface. Visually certified on the real SPA path
  // (before/after read by a human, 2026-07-07): a rel-cursor slammed into the corner
  // and nudged onto the "Menu" button, clicked, opens the KolibriOS main menu; 'a'
  // echoes at the caret (status 1,1->1,2); with two typed lines ArrowUp/Down move the
  // caret row 2<->1; Esc dismisses the open main menu. Deterministic, region-calibrated
  // per-input assertions live in certify-kolibrios/kolibrios.golden.spec.ts.
  //
  // MOUSE is GATED in the shared suite (the rel cursor sweep + the menu it opens are a
  // large FB change). KEYBOARD stays skipped in the shared suite ONLY because its
  // reaction — a 1px caret bar + a few glyph/status pixels, whole-frame cf ~1.5e-4 — is
  // below the shared whole-frame KEY_PASS floor; it is NOT invisible and NOT animation:
  // it IS pixel-verified region-scoped in the dedicated golden spec above.
  { osId: 'kolibrios',   displayName: 'KolibriOS',                keyType: 'a',
    keyboardSkip: 'KolibriOS golden fixture: the keypress DOES echo at the focused TINYPAD caret, but the reaction (1px caret bar + a few glyph/status pixels, whole-frame cf ~1.5e-4) sits below the shared suite whole-frame KEY_PASS floor. It is pixel-verified REGION-SCOPED (caret line + status "row,col" rect) in certify-kolibrios/kolibrios.golden.spec.ts. Keys ARE delivered and echoed.' },
  { osId: 'toaruos',     displayName: 'ToaruOS',                  keyType: 'ls\n',
    mouseSkip: `ToaruOS compositor: ${UNCAPTURED_CURSOR}` },
  // GOLDEN FIXTURE (VMID 99): boots to the HelenOS 0.14.1 GUI compositor @1024x768
  // with the auto-opened Terminal (Bdsh) window FOCUSED at a clean prompt
  // "/ # helenos" (the word "helenos" typed but un-executed, a solid NON-blinking
  // block caret after it), a large clear-blue desktop, and a bottom-left "Start"
  // button. Idle is byte-identical once the taskbar clock is masked. Visually
  // certified on the real SPA path (before/after read by a human, 2026-07-07):
  //   * KEYBOARD is now GATED — the focused Bdsh prompt echoes reliably: typing
  //     keyType "help\n" appends+executes (large FB change; measured shared-suite
  //     cf ~3.0e-3, ~15x the KEY_PASS floor).
  //   * MOUSE stays skipped IN THE SHARED SUITE (floor, not ceiling): HelenOS draws
  //     its pointer ONLY over windows/widgets, never over the desktop background —
  //     see the flag text. Pixel-verified DETERMINISTICALLY in
  //     certify-helenos/helenos.golden.spec.ts (corner-slam + Start → Applications).
  { osId: 'helenos',     displayName: 'HelenOS',                  keyType: 'help\n',
    mouseSkip: 'HelenOS golden fixture: the guest draws its pointer ONLY over windows/widgets (never the desktop background) and the shared mid-desktop drag/right-click opens no menu, so that generic routine yields only a small, marginal cursor-sprite reaction over the terminal (measured ~2.7e-4, ~1.3x the MOUSE_PASS floor — reacts some runs). Input IS delivered; it is pixel-verified DETERMINISTICALLY (corner-slam + nudge onto Start -> Applications menu, ~62k px) in certify-helenos/helenos.golden.spec.ts. Flag is a floor: when the sweep does react it still reports PASS.' },
  { osId: 'solaris',     displayName: 'Solaris CDE',              keyType: 'ls\n',
    mouseSkip: `Solaris CDE: ${UNCAPTURED_CURSOR} (measured ~1e-4, ~4x idle but below the reliable gate).`,
    keyboardSkip: `Solaris CDE ${NO_ECHO}` },
  // GOLDEN FIXTURE (VMID 101): boots to the Android Terminal Emulator open on a shell
  // prompt (banner + ":/ $ _" with a solid non-blinking block cursor; Stay-awake on;
  // auto-rotate off; static wallpaper => idle byte-identical bar the top status-bar
  // clock minute glyph). KEYBOARD is a GATED regression sentinel ('a' echoes at the
  // prompt; ArrowUp/Down recall/clear shell history — certified 2026-07-07;
  // region-calibrated assertions in certify-android/android.golden.spec.ts).
  // MOUSE (routed as touch) stays flagged — see the flag text.
  { osId: 'android',     displayName: 'Android',                  keyType: 'a',
    mouseSkip: 'Android golden fixture (Terminal Emulator): the DETERMINISTIC mouse surface is a tap on the action-overflow (⋮) button opening its popup (~12k px), pixel-verified region-scoped in certify-android/android.golden.spec.ts. The shared-suite generic centre swipe/tap on the empty terminal body only grazes the whole-frame floor (~2.2e-4 vs 2e-4), so it is flagged (floor, not ceiling). Touch/tap IS delivered (control channel open).' },
  { osId: 'serenityos',  displayName: 'SerenityOS',               keyType: 'a',
    keyboardSkip: `SerenityOS ${NO_ECHO}` },
  { osId: 'postmarketos',displayName: 'postmarketOS',             keyType: 'a',
    keyboardSkip: 'postmarketOS phone UI exposes no focused HW-keyboard field on the home screen; key events have no reliable FB effect. Touch/swipe is delivered + pixel-verified.' },
  { osId: 'sailfishos',  displayName: 'Sailfish OS',              keyType: 'a',
    mouseSkip: 'Sailfish home screen is static under a centre swipe: touch is delivered (identical path pixel-verifies on postmarketOS) but nothing scrolls and there is no cursor.',
    keyboardSkip: 'Sailfish phone UI exposes no focused HW-keyboard field on the home screen; key events have no reliable FB effect.' },
  // GOLDEN FIXTURE (VMID 105): TempleOS V5.03 (ISO/RAM-only) at a clean full-width
  // HolyC "T:/Home>" prompt (yellow block caret), the PS/2 arrow parked mid-desktop,
  // AutoComplete/"God" demo window closed so ONLY the top status HUD + the input
  // caret animate at idle. BOTH channels stay skipped in the SHARED suite only
  // because its whole-frame floors can't clear this tile's animated top HUD (idle
  // cf ~1e-3..6e-3 on the left clock) — the reactions are NOT invisible and NOT
  // ambient: they are pixel-verified REGION-SCOPED in
  // certify-templeos/templeos.golden.spec.ts.
  { osId: 'templeos',    displayName: 'TempleOS',                 keyType: 'dir\n',
    mouseSkip: 'TempleOS golden fixture: the rel-pointer arrow DOES move on the desktop, but the sprite is a thin ~34-px change (whole-frame cf ~1.1e-4) that sits below the shared-suite MOUSE_PASS floor AND under the animated top HUD. It is pixel-verified REGION-SCOPED (blank desktop body y40..465, idle 0) in certify-templeos/templeos.golden.spec.ts. The cursor IS delivered and moves.',
    keyboardSkip: 'TempleOS golden fixture: keys ARE delivered and echo (green char glyph at the caret; ArrowDown/Up/Esc flip the top-right last-key HUD readout), but the reactions are small/region-local relative to the shared-suite whole-frame floor + the animated top HUD. They are pixel-verified REGION-SCOPED (green-glyph gain + the non-animated last-key cell x560..640,y0..9, idle 0) in certify-templeos/templeos.golden.spec.ts.' },
  { osId: 'haiku',       displayName: 'Haiku R1/beta5',           keyType: 'a',
    mouseSkip: `Haiku app_server: ${UNCAPTURED_CURSOR} (measured FB change swings run-to-run around idle).` },
  { osId: 'os2warp',     displayName: 'OS/2 Warp 4',              keyType: 'a',
    keyboardSkip: 'OS/2 Warp Workplace Shell: no window holds keyboard focus and Ctrl+Esc (Window List) is not reliably rendered into the framebuffer; echo is state-dependent (measured 0.33 then 0 across runs). Keys ARE delivered (control channel open).' },
  { osId: 'aros',        displayName: 'AROS',                     keyType: 'a',
    keyboardSkip: `AROS Wanderer desktop: no window holds keyboard focus, so echo is unreliable (measured 2.5e-3 then 0 across runs); ${NO_ECHO}` },
  // QNX — tablet-free re-bake + direct type=4 RelMotion (live+verified 2026-07-14):
  // the guest now owns a PS/2 relative mouse with 1:1 tracking that DRAWS its cursor
  // into the captured framebuffer, so the tablet-era mouseSkip ("ignores synthetic
  // tablet buttons / uncaptured overlay") is GONE and mouse is a gated sentinel.
  // Keyboard remains flagged: Photon still presents no focused echo field.
  { osId: 'qnx',         displayName: 'QNX Neutrino 6.5',         keyType: 'a',
    keyboardSkip: `QNX Photon ${NO_ECHO}` },
  { osId: 'msdoswin1',   displayName: 'MS-DOS 6.22 + Windows 1.0',keyType: 'dir\n',
    mouseSkip: `MS-DOS 6.22 ${TEXT_CONSOLE}` },
  // ---- EMULATOR-BRIDGE TILES (added to the manifest 2026-07-08; live since the
  //      shm/backlog fix 07-12). decode/control/reset are gated — exactly the
  //      regressions these tiles have historically had. C64 mouse input was
  //      browser/framebuffer-certified on 2026-07-16; the remaining bridge input
  //      verdicts stay flagged until pixel-certified from their golden fixtures.
  { osId: 'c64',         displayName: 'Commodore 64 — GEOS 2.0',  keyType: 'a',
    keyboardSkip: BRIDGE_UNVERIFIED },
  { osId: 'atarist',     displayName: 'Atari ST (EmuTOS GEM)',    keyType: 'a',
    mouseSkip: BRIDGE_UNVERIFIED, keyboardSkip: BRIDGE_UNVERIFIED },
  { osId: 'apple2',      displayName: 'Apple GEOS',               keyType: 'a',
    mouseSkip: BRIDGE_UNVERIFIED, keyboardSkip: BRIDGE_UNVERIFIED },
  { osId: 'amiga',       displayName: 'Amiga 500 — Workbench 1.3',keyType: 'a',
    mouseSkip: BRIDGE_UNVERIFIED, keyboardSkip: BRIDGE_UNVERIFIED },
];

// ---------------------------------------------------------------------------
//  Merge: manifest facts (+ overrides) × test-side table. A tile in the table
//  but missing from the manifest is a hard error — loud drift beats silent skew.
// ---------------------------------------------------------------------------
export const STREAMHOST_INPUT_TILES: InputTileSpec[] = TEST_SPECS.map((t) => {
  const m = GOLDEN_MANIFEST.tiles[t.osId];
  if (!m) {
    throw new Error(
      `tile "${t.osId}" is in streamhostInput.group.ts but not in golden-manifest.json — ` +
      're-sync the manifest (labctl gen / refresh from the box) or drop the tile.',
    );
  }
  const facts = { ...m, ...MANIFEST_OVERRIDES[t.osId] };
  return {
    osId: t.osId,
    displayName: t.displayName,
    tileDir: facts.tileDir,
    pointer: facts.pointer,
    touch: facts.touch || undefined,
    keyType: t.keyType,
    resetMode: facts.resetMode,
    snapshot: facts.snapshot ?? undefined,
    mouseSkip: t.mouseSkip,
    keyboardSkip: t.keyboardSkip,
  };
});
