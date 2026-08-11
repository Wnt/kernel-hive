# Dev workstation — CT 950 `osgallery-dev`

An Ubuntu 24.04 LTS LXC on labhost for continuing this project from *inside*
the labhost network (created 2026-07-08). Sibling of CT 110 (the deploy container),
NOT nested in it; its own `/etc/pve/lxc/950.conf` + `data/subvol-950-disk-0`
(24G) on the shared `data` ZFS pool.

> **Recreate from scratch:** `scripts/provision/provision-dev-ct.sh` (AUTHORED-FROM-DOCS,
> UNTESTED — reconstructed from this file + the live 950.conf; supervise first run).
> It scripts everything below incl. the locale/mosh fix, xdesk.service and the
> mandatory ffmpeg/libavcodec install for Firefox H.264 e2e.

## Access (from the Mac)
- **`ssh osgallery-dev`** or **`mosh osgallery-dev`** — user **`wnt`**, passwordless
  sudo, static **192.0.2.11** on the LAN (reachable over the WiFiman VPN).
  Aliased in the Mac `~/.ssh/config` (also `devbox`), uses the default `id_rsa`.
- `ssh lab` works **from inside** the container (its own key is authorized on
  labhost) -> drive labhost exactly like from the Mac.
- mosh note: the container's sshd had `AcceptEnv LANG LC_*` disabled because
  macOS forwards `LC_CTYPE=UTF-8`, which is not a valid Linux locale and made
  `mosh-server` abort. Now it uses the container's own `en_US.UTF-8`.

## Installed
node 22 LTS + npm, rustup/cargo stable, `gh` (authed as Wnt), git, `claude`
(Claude Code CLI), mosh, Playwright 1.61 + google-chrome-stable, python3,
ripgrep/jq/tmux, qemu-utils. Repo cloned at **`~/osgallery`**. Gitignored secrets
transferred in (unifitoken, uptoken, docs/gallery-credentials.md, credentials.ts,
serve/pki). Claude memory at `~/.claude/projects/-home-wnt-osgallery/memory/`.

## Headed browser + shared remote desktop (for end-to-end tests)
A SINGLE shared X display that both an automation session and the human see:
- **`xdesk.service`** (systemd, auto-start, Restart=on-failure) runs **Xvfb `:1`
  1920x1080x24 + openbox + x11vnc**. `DISPLAY=:1` is exported for interactive
  shells (`/etc/profile.d/xdesk.sh`).
- **Connect from the Mac (native):** `open vnc://192.0.2.11:5900`
  (Finder -> Screen Sharing). Password: see the **"Dev box remote desktop (VNC)"**
  section of the gitignored `docs/gallery-credentials.md` (NOT in git).
- **Drive a browser so the VNC viewer sees it live:** `e2e-chrome <url>` (headed
  Chrome on `:1` with the right flags: `--no-sandbox --use-gl=angle
  --use-angle=swiftshader --ignore-certificate-errors ...`), e.g.
  `e2e-chrome https://192.0.2.10:8443`. Or Playwright with
  `headless:false, channel:'chrome'` and `DISPLAY=:1`. Anything painted on `:1`
  is the exact framebuffer x11vnc streams -> one shared session.
- Server-side capture for inference: `DISPLAY=:1 import -window root /tmp/x.png`.
- Playwright smoke test: `~/e2e/smoke.mjs`.

### Gotchas
- No GPU -> software GL (SwiftShader/llvmpipe): WebGL/WebCodecs work but are
  CPU-bound, lower FPS than the Mac. Fine for E2E correctness, not perf.
- Chrome needs `--no-sandbox` in the privileged/nesting LXC (harmless infobar).
- Kill Chrome with `pkill -9 -u wnt chrome` (on-disk cmdline is
  `/opt/google/chrome/chrome`). Restarting `xdesk.service` drops browser windows
  -> relaunch `e2e-chrome`.
- Hardening option: add `-localhost` to x11vnc in `/usr/local/bin/xdesk-start.sh`
  and tunnel `ssh -L 5900:localhost:5900 osgallery-dev`.

## Browser e2e deps (Firefox smoke suites)

- **Playwright Firefox**: `npx playwright install firefox` (from a dir with
  playwright 1.61.x, e.g. `~/e2e` or `tests/e2e-live`) → bundled build
  **firefox-1532** (Firefox 151) in `~/.cache/ms-playwright`. Headless works —
  no `DISPLAY`/xdesk needed, unlike the Chrome path.
- **libavcodec60 is REQUIRED for H.264 WebCodecs in Firefox**: without system
  libavcodec, `VideoDecoder.isConfigSupported` for every `avc1.*` config is
  `false` (vp8-only) and decode silently fails. A freshly provisioned dev box
  MUST `apt-get install ffmpeg` (pulls `libavcodec60`). Installed here
  2026-07-12; bake into any rebuild.
- **SecureContext gotcha**: WebCodecs + WebTransport are SecureContext-gated in
  Firefox — `typeof VideoDecoder` is `undefined` on `about:blank`/`data:` pages.
  Probes/tests must run on the real https origin (the UI at
  `https://192.0.2.10:8443` with `ignoreHTTPSErrors: true`) or localhost.
- Suites: `scripts/e2e/ff-check.mjs` (one-station PASS/FAIL smoke) and
  `tests/e2e-live/e2e/firefoxSmoke.config.ts` (FreeDOS/Win95/Solaris, firefox +
  chromium projects). Working caps/connect probe kept at `~/e2e/probe2.mjs`.

## To continue the project here
`cd ~/osgallery && claude` — picks up `AGENTS.md` (via the `CLAUDE.md` pointer) + the transferred memory.
