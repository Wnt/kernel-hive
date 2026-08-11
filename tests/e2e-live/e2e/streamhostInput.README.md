# streamhostInput — per-title input regression suite (streamhost tiles)

Auto-catches keyboard/mouse breakage on the QEMU **streamhost** tiles — the 24
original tiles plus the 4 emulator-bridge tiles (c64/atarist/apple2/amiga,
input verdicts still UNVERIFIED → flagged, decode/control/reset gated)
(WebTransport + WebCodecs H.264). One Playwright test per tile drives the
**genuine deployed SPA** (grid → card click → `StreamView`) exactly as a user
does, then verifies the guest's reaction on its **authoritative VGA framebuffer**
via QMP `screendump` — no admin API, no shim on the input path.

**RESET-TO-GOLDEN before every tile run is the DEFAULT.** Each test first restores
its tile to a curated **golden fixture** (a focused editor/terminal on a clean
desktop) via the shared host authority `reset-tile.sh` + `golden-manifest.json`,
so every run starts from the identical state the assertions were calibrated
against. This is the *same* code path the SPA's **"Restore to golden"** button
uses — so what the suite proves green is exactly what the button restores.

Per tile it asserts and reports four things:

| check    | how                                                                                  |
|----------|--------------------------------------------------------------------------------------|
| decode   | `StreamView`'s `<video>` paints a live frame (first `VideoFrame`).                   |
| control  | the control data channel opens (status pill flips to `— CONTROL`).                   |
| mouse    | real `page.mouse` over the `<video>` (held drag-sweep + right-click menu) changes the guest framebuffer beyond idle. |
| keyboard | real `page.keyboard` (a literal string + ArrowDown/Up + Ctrl+Esc + a single Esc) changes the guest framebuffer beyond idle. |

`decode`, `control`, and the **reset** are **gated on every tile** (failure is a
hard regression). `mouse` / `keyboard` are gated on every tile **except** those
carrying a measured `mouseSkip` / `keyboardSkip` in `streamhostInput.group.ts` —
tiles whose guest surface renders no whole-frame pixel-verifiable reaction to that
channel (uncaptured hardware cursor, a text console with no pointer, an unfocused
desktop with no keyboard echo, a guest that ignores synthetic buttons, or a
continuously-animating desktop). Those still **send** the input and prove
decode+control+reset; they just `SKIP` the whole-frame gate with the documented
reason instead of faking a pass/fail. A skipped channel that reacts anyway is still
reported `PASS` — the flag is a floor, never a ceiling.

## Reset-to-golden — the golden manifest

the rendered `golden-manifest.json` (deployed to
`/data/vms/streamhost/serve/`) is the single source of truth, keyed by **osId**.
`streamhostInput.group.ts` reads it at load for the shared per-tile facts
(`tileDir/pointer/touch/resetMode/snapshot`) — override the path with
`GOLDEN_MANIFEST=…`; when the repo tree is absent (suite rsynced to the box) it
falls back to the deployed copy. The former duplicate in this dir was deleted
2026-07-14 (de-drift). Per tile the manifest records `tileDir`,
`pointer/touch`, the **`resetMode`**, and the visually-certified `mouse`/`keyboard`
verdict + `fixture` description. Two reset modes:

| resetMode | tiles | how it resets | speed |
|-----------|-------|---------------|-------|
| `loadvm`  | 22 (all except the two below) | QMP `loadvm golden` on the tile's live `qmp.sock` — restores RAM+devices **exactly**, no restart | instant |
| `restart` | `serenityos`, `toaruos` | re-run the tile's `qemu-streamhost.sh` (cold-boot the curated fixture) + `systemctl restart streamhost@<tileDir>` — for tiles whose backing store holds no vmstate snapshot | ~cold boot (≤45 s to fixture, measured) |

`reset-tile.sh <osId>` dispatches on `resetMode`. **Non-destructive by construction:**
it only *restores* the in-qcow2 `golden` snapshot or *cold-boots* the fixture — it
**never** runs `savevm`. The harness calls it before each tile (`execFileSync`), waits
`2.5 s` (loadvm) / `45 s` (restart) to settle, then drives. A failed reset is FATAL
(the fixture the gated assertions assume would not be guaranteed).

Verified: `loadvm golden` restores **byte-identically** (post-reset framebuffer md5
stable across repeated resets, QEMU pid unchanged); both restart tiles reach their
interactive fixture well within the 45 s wait.

## How the visual certification was done

Every **gated (non-skip)** channel was certified by an agent that:

1. drove the **REAL deployed SPA path** — headless Chrome-for-Testing on the host
   opening `https://127.0.0.1:8443/?streamhost=<osId>` → the grid card → `StreamView`,
   input flowing through StreamView's own pointer/keyboard handlers over WebTransport
   (the exact final-hop injection the daemon feeds the guest), and
2. read the guest's **before/after QMP `screendump` PNGs by eye** (multimodal, not
   pixel-diff alone) from the tile's golden fixture, confirming the specific reaction
   (menu opens, caret echoes the char, selection/caret moves on arrows, Esc dismisses).

Tiles whose gated set **grew** because a golden fixture now presents a focused
surface: `win311` + `win98se` (Notepad → both channels gated), `kolibrios`-mouse,
`helenos`-keyboard (`help\n` at the Bdsh prompt), `android`-keyboard (Terminal
Emulator). Those gains only hold **because the suite resets to golden first** — which
is why reset-before-run is the default, not an opt-in. Region-scoped deterministic
per-input specs for the harder tiles live beside the fixtures in
`/data/streamhost-input-test/certify-<tile>/…golden.spec.ts` (green-glyph / rect-scoped
assertions that clear a tile's animated HUD or sub-floor caret).

## Where it runs — ON THE STREAMHOST HOST (not the dev Mac)

Two hard reasons:

1. **macOS local-network privacy** blocks fresh Chromes from `192.168.x.x`
   (`ERR_ADDRESS_UNREACHABLE`). The Linux host has no such wall.
2. Guest reactions are read from each tile's **local** `qmp.sock`
   (`/data/vms/streamhost/tiles/<tileDir>/qmp.sock`) — only reachable on the host.

It also needs a **proprietary-codec Chrome** (Chrome for Testing / Google Chrome),
**not** Playwright's bundled Chromium: the wire is H.264 and the codec-stripped
Chromium cannot decode it in WebCodecs.

### Run

```bash
cd /data/streamhost-input-test
export PATH=$PWD/node/bin:$PATH
STREAMHOST_LOG=$PWD/out/input.jsonl \
  CHROME_PATH=$PWD/chrome-linux64/chrome \
  npx playwright test -c streamhostInput.config.ts
```

Reset-to-golden runs by default. The suite writes before/after PPM screendumps to
`STREAMHOST_SHOT_DIR` (each tile: `<tileDir>-drag/-rclick/-key_a/-key_start/...`) —
spot-check those to confirm assertions match the pixels.

### Env knobs

| var                          | default                                             | meaning                                  |
|------------------------------|-----------------------------------------------------|------------------------------------------|
| `CHROME_PATH`                | `/data/streamhost-input-test/chrome-linux64/chrome` | proprietary-codec Chrome binary          |
| `SPA_BASE_URL`               | `https://127.0.0.1:8443`                            | deployed SPA origin                      |
| `STREAMHOST_TILES_DIR`       | `/data/vms/streamhost/tiles`                        | dir holding each `<tileDir>/qmp.sock`    |
| `STREAMHOST_SHOT_DIR`        | `/data/streamhost-input-test/shots`                 | scratch for QEMU PPM screendumps         |
| `STREAMHOST_RESET_SCRIPT`    | `/data/vms/streamhost/serve/reset-tile.sh`          | reset authority (shared with the button) |
| `STREAMHOST_NO_RESET`        | (unset)                                             | **disable** reset-to-golden (debug the live state) |
| `STREAMHOST_LOADVM_SETTLE_MS`| `2500`                                              | settle after a loadvm reset              |
| `STREAMHOST_RESTART_BOOT_MS` | `45000`                                             | boot wait after a restart-mode reset     |
| `STREAMHOST_LOG`             | (unset)                                             | append one JSON line of metrics per tile |
| `STREAMHOST_WORKERS`         | `1`                                                 | tiles are single-viewer; serialise       |
| `STREAMHOST_NO_GATE`         | (unset)                                             | measurement mode: record, never fail-gate — use to recalibrate `*Skip` flags |
| `STREAMHOST_CONNECT_MS`      | `70000`                                             | per-tile decode/keyframe budget          |

### The one test-environment shim

This GPU-less host has no hardware H.264 decoder, and `streamClient.ts`
hard-configures the WebCodecs `VideoDecoder` with
`hardwareAcceleration:'prefer-hardware'` (correct for real user GPUs, but
`isConfigSupported` returns **false** here, which closes the decoder). The suite
installs a single `addInitScript` that coerces that **one field** to
`no-preference` so the **unmodified deployed bundle** decodes in headless. The
wire, control plane and all input remain byte-for-byte the shipped code. Nothing
is patched on the guest or the server.

## Per-title results (on-host full run, reset-to-golden default — 24/24 green)

`decode` + `control` + `reset` PASS on **all 24** tiles. `mouse` 12 PASS / 12 SKIP,
`keyboard` 13 PASS / 11 SKIP (SKIP = input delivered + decode/control/reset proven,
but that channel has no whole-frame pixel-verifiable surface on that guest — see the
`*Skip` reasons in `streamhostInput.group.ts`; several are pixel-verified
region-scoped in a dedicated golden spec).

| tile          | ptr   | reset   | decode | control | mouse | keyboard |
|---------------|-------|---------|--------|---------|-------|----------|
| reactos       | abs   | loadvm  | PASS   | PASS    | PASS  | PASS     |
| tinycore      | abs   | loadvm  | PASS   | PASS    | PASS  | SKIP     |
| alpine        | abs   | loadvm  | PASS   | PASS    | SKIP  | PASS     |
| win311        | rel   | loadvm  | PASS   | PASS    | PASS  | PASS     |
| win95         | rel   | loadvm  | PASS   | PASS    | PASS  | PASS     |
| win98se       | rel   | loadvm  | PASS   | PASS    | PASS  | PASS     |
| win2000       | abs   | loadvm  | PASS   | PASS    | SKIP  | PASS     |
| winxp         | abs   | loadvm  | PASS   | PASS    | PASS  | PASS     |
| freedos       | rel   | loadvm  | PASS   | PASS    | SKIP  | PASS     |
| ninefront     | rel   | loadvm  | PASS   | PASS    | PASS  | SKIP     |
| kolibrios     | rel   | loadvm  | PASS   | PASS    | PASS  | SKIP²    |
| toaruos       | abs   | restart | PASS   | PASS    | SKIP  | PASS     |
| helenos       | rel   | loadvm  | PASS   | PASS    | SKIP² | PASS     |
| solaris       | abs   | loadvm  | PASS   | PASS    | SKIP  | SKIP     |
| android       | abs·t | loadvm  | PASS   | PASS    | SKIP² | PASS     |
| serenityos    | abs   | restart | PASS   | PASS    | PASS  | SKIP     |
| postmarketos  | abs·t | loadvm  | PASS   | PASS    | PASS  | SKIP     |
| sailfishos    | abs·t | loadvm  | PASS   | PASS    | SKIP  | SKIP     |
| templeos      | rel   | loadvm  | PASS   | PASS    | SKIP² | SKIP²    |
| haiku         | abs   | loadvm  | PASS   | PASS    | SKIP  | PASS     |
| os2warp       | rel   | loadvm  | PASS   | PASS    | PASS  | SKIP     |
| aros          | rel   | loadvm  | PASS   | PASS    | PASS  | SKIP     |
| qnx           | abs   | loadvm  | PASS   | PASS    | SKIP  | SKIP     |
| msdoswin1     | rel   | loadvm  | PASS   | PASS    | SKIP  | PASS     |

`abs·t` = absolute pointer routed as **touch**. ² = whole-frame SKIP in this shared
suite but **pixel-verified region-scoped** in the tile's dedicated golden spec
(`certify-<tile>/…golden.spec.ts`) — the reaction is real, just below the shared
whole-frame floor or under an animated HUD.

**Drift since that run (2026-07-14, reflected in `streamhostInput.group.ts`):**

- **qnx** — tablet-free re-bake + direct type=4 RelMotion: now `pointer: rel`
  with a guest-drawn 1:1 cursor, so the tablet-era `mouseSkip` is removed and
  mouse is **gated** (the shared manifest copy still says `abs` — a test-side
  override carries the newer certified fact until the box manifest refreshes).
- **winxp** — golden changed to the Bliss **boot-video** fixture (no focused
  Notepad caret), so the certified keyboard gate lost its echo surface: flagged
  `keyboardSkip: NEEDS RECERTIFICATION` (honest SKIP, not a false FAIL) until
  re-certified.
- **c64 / atarist / apple2 / amiga** — the 4 emulator-bridge tiles joined the
  suite: decode/control/reset gated, both input channels flagged UNVERIFIED
  pending pixel-certification.
- boot-video tiles (win95/win98se/win2000/winxp/solaris/haiku/os2warp/amiga)
  mount the recorded clip as a second `<video src=…>`; every harness probe now
  selects the srcObject-fed LIVE `<video>` only, so the clip can neither satisfy
  the decode gate nor eat the connect budget.

## SPA "Restore to golden" button + endpoint

The same reset authority is exposed to the SPA:

- **Endpoint:** `POST https://192.0.2.10:8443/restore/<osId>` in
  `osgallery-https-server.py`. **LAN-only** (loopback / RFC1918 / link-local
  clients only — others get `403`), **non-destructive** (runs `reset-tile.sh`,
  which only loadvm-restores or cold-boots), validates `<osId>` against the golden
  manifest, returns `{ok, osId, detail}`. Disable with `RESTORE_ENABLE=0`.
- **Button:** `StreamView` renders **"↺ Restore to golden"** for streamhost tiles.
  It confirms first (anyone viewing sees the reset), then same-origin
  `POST /restore/<osId>`, showing `Restoring… → ✓ Restored / ⚠ Restore failed`.

## Files

- the rendered `golden-manifest.json` (published to `/data/vms/streamhost/serve/`) — per-tile `tileDir/pointer/touch/resetMode/snapshot` + certified `mouse`/`keyboard` verdict + fixture. Single source of truth, read by the suite at load.
- `scripts/serve/reset-tile.sh` (repo root; deployed to `/data/vms/streamhost/serve/reset-tile.sh`) — the reset authority (loadvm / restart per manifest). Shared by the suite AND the restore endpoint.
- `streamhostInput.qmp.ts` — QMP `screendump` over the tile unix socket + PPM parse + diff (+ `loadSnapshot` helper).
- `streamhostInput.group.ts` — test-side tile table (keyType + measured skip reasons + visual-certification comments) merged with the manifest's shared facts at load.
- `streamhostInput.harness.ts` — the per-tile runner (**reset-to-golden** → open → decode → control → mouse → keyboard → verdict).
- `streamhostInput.spec.ts` — parameterized: one test per tile.
- `streamhostInput.config.ts` — Playwright config (on-host Chrome, no webServer, HTTPS-tolerant).

## Guardrails honoured

Read-only against guests except the synthetic input sent + the reset restore; QMP
`screendump` only **reads** the framebuffer; reset only `loadvm`-restores or
cold-boots (never `savevm`, so golden snapshots are never mutated). Kills are by
pidfile only (inside `qemu-streamhost.sh`). Never touches CT 112, `riscos`,
`windows11`, or `macos` (none is in the tile table).
