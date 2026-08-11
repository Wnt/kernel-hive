# tests/e2e-live — Playwright suites against the LIVE lab box

These are live-integration suites, **not CI tests**: they drive the deployed
SPA at `https://192.0.2.10:8443` against the real streamhost tiles / QEMU
guests on the lab box (WebTransport + WebCodecs H.264). They require the lab
box reachable; the input suite additionally needs the tile QMP sockets (it runs
ON the box). None of this exists in CI, so **no workflow runs these** — run
them manually from this directory:

```bash
cd tests/e2e-live
npm install                            # first time only (@playwright/test ^1.61)
npx playwright install firefox chromium

npm run test:firefox                   # QUICK START: decode smoke (below)
npm run test:boot                      # boot-video replay smoke (win95)
npm run test:input                     # per-tile input regression — ON THE BOX ONLY
```

## Standalone probes (not Playwright suites)

| Script | What it answers |
|---|---|
| `nextstep-abs-probe.mjs` | Does the **nextstep** exhibit's absolute pointer survive the real client path — browser -> WebTransport -> streamhost -> QEMU `usb-tablet` -> Xorg -> SDL -> Previous's tablet -> the NeXTSTEP tabletdriver? Drives real `page.mouse` moves to guest pixels, plus a click and a drag, and prints the schedule for a framebuffer poller on the box to check. `node nextstep-abs-probe.mjs 8,8 560,416` |
| `pen-doubletap-probe.mjs` | Does a **stylus** double-tap survive the whole chain — client quantisation, wire, daemon, guest? Drives synthetic `pointerType: 'pen'` events through the DEPLOYED bundle in a touch-emulated context. Pair it with `SH_INPUT_TELEMETRY=1` on the tile and `labctl shot` (see [docs/lab/INPUT-DEBUGGING.md](../../docs/lab/INPUT-DEBUGGING.md)). `node pen-doubletap-probe.mjs "Windows 3.11" 218 178` |

## Suite families (all under `e2e/`)

| family | config | what it drives | where it runs |
|--------|--------|----------------|---------------|
| `firefoxSmoke.*` | `firefoxSmoke.config.ts` | Firefox (+chromium) decode smoke vs the DEPLOYED SPA — the quick-start suite | anywhere with a route to the box |
| `bootVideo.*` | `bootVideo.config.ts` | boot-video replay: overlay mounts, clip plays + scrubs, Skip hands off to the painting live surface (win95) | anywhere with a route to the box |
| `streamhostInput.*` | `streamhostInput.config.ts` | per-tile input regression vs the DEPLOYED SPA; resets tiles to golden first, verifies reactions on the QMP framebuffer | ON the streamhost box (local `qmp.sock` per tile + proprietary-codec Chrome) — see `e2e/streamhostInput.README.md` |

Two standalone IRIX scripts sit beside them (plain `node`, no Playwright
runner). The IRIX tile has no QMP socket, so both read guest truth from the shm
framebuffer over `ssh lab` (`fbstat.py --cursor`) rather than from the browser:

| script | what it drives |
|---|---|
| `irixbrowser.mjs` | pointer accuracy at first contact, `STEP=login` (types root+Enter), `STEP=menu` (right-press → the 4Dwm root menu must STAY posted → drag → release activates the item) |
| `irixedge.mjs` | edge-slam stress: three rounds into all four screen corners, then checks an ordinary move still lands — the dead-reckoner's edge resync is the one place the model and a clamping guest can diverge |

## Quick start: `firefoxSmoke` (run this FIRST)

`e2e/firefoxSmoke.config.ts` + `e2e/firefoxSmoke.spec.ts` — the fastest
whole-plane health check: for **FreeDOS / Windows 95 / Solaris** it opens the
DEPLOYED SPA (baseURL from `GALLERY_URL`, default the live box), clicks the
tile card, and asserts the LIVE stream surface is painting real non-black
pixels (>=1% for text-mode FreeDOS, >50% for the desktops) and that the
explicit **"decoder failing"** chip is absent. The live surface differs per
engine: **Firefox** streamhost tiles render via a direct-paint
`<canvas class="sv-video">` (no live `<video>` at all — StreamView
`directCanvas`, 2026-07-13); **Chromium** keeps the srcObject-fed `<video>`.
Boot-video tiles mount the recorded clip as a second `<video src=…>` — the
probe deliberately never accepts it as liveness. Projects: **firefox** (the
point — Firefox's WebCodecs H.264 annexb mode is broken, so this proves the
avc/avcC client path) plus a **chromium** row as a cheap cross-browser
regression. Workers 1, 90 s/tile, page console + probe JSON attached,
screenshot on failure.

```bash
npm run test:firefox                                        # both projects
npx playwright test -c e2e/firefoxSmoke.config.ts --project=firefox
GALLERY_URL=https://192.0.2.10:8443 npm run test:firefox
```

Dev-box deps: Firefox H.264 WebCodecs needs **system libavcodec**
(`apt-get install ffmpeg` → libavcodec60) — see `docs/lab/dev-box-notes.md`.

## Shared facts: the golden manifest

Per-tile infrastructure facts (`stationDir` / `pointer` / `touch` / `resetMode` /
`snapshot`) come from the **rendered `golden-manifest.json`** (`stations-registry.py
emit golden-manifest.json`; the copy published to `/data/vms/streamhost/serve/`
drives `reset-tile.sh` and the SPA "Restore to golden" endpoint).
`e2e/streamhostInput.group.ts` renders it at load (override with
`GOLDEN_MANIFEST=…`; falls back to the deployed box copy when there is no
checkout to render from) and keeps only test-side data — probe
strings and measured per-channel skip flags. The former duplicate at
`e2e/golden-manifest.json` was deleted 2026-07-14 (it had drifted: no bridge
tiles, tablet-era qnx facts).

## 2026-07-14 cleanup — the retired neko plane

The gallery's original streaming plane (n.eko/WebRTC tiles on
`192.0.2.12` — host retired) was replaced by the Rust **streamhost**
daemon (WebTransport + WebCodecs, 28 tiles on `192.0.2.10`). ~85% of this
directory tested the dead plane, so those families were **deleted** on branch
`chore/debt-cleanup` (recoverable from git history, this commit's parent):

- `e2e/neko.ts` + everything built on the neko admin-screenshot API:
  `interaction.spec.ts`/`os-list.ts`/`playwright.config.ts` (neko web-UI
  suite), `spaDriver.retro.ts` + `spa-*.spec.ts` retro/touch specs,
  `spaAltos.*`, `spaGrid.*`, `grid/`, `spa-win-os2/`, `spaTouch.ts`, and their
  configs/READMEs — all hardcoded the dead host, the retired WebRTC/data-channel
  transport, or the removed `__nekoDiag` seam and pre-router store shape.
- **Historical:** `spa-freedos.spec.ts` + `spaGrid.group.ts` misdescribed
  FreeDOS as a non-streamable `local-novnc` exhibit; it is now an ordinary
  streamhost tile.
- `e2e/golden-manifest.json` (drifted duplicate — see above).

Surviving live set: `streamhostInput.*`, `firefoxSmoke.*`, and the new
`bootVideo.*`.
