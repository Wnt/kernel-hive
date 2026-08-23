# Kernel Hive

Kernel Hive is a "living computer museum": a single Proxmox host runs around
three dozen vintage and exotic operating systems as live emulated or
virtualised guests — from 1980s home computers to hobby OSes still under
active development — and streams each one, interactively, into a web
browser. An invited visitor can watch a guest boot, move its pointer, and
type into it, from anywhere — the public gallery is reachable over the
internet but gated behind passkey sign-in, so sessions are authenticated
rather than open to the world.

> **Status:** personal home-lab project, not a product. Everything here is
> built against one specific machine ("the lab box"). The code is published
> for reading, reuse and reference; reproducing the full gallery is real
> work, and the docs describe that work rather than hiding it behind an
> installer.

## What's in it

The registry (`registry/stations/`, queried with
`python3 scripts/stations-registry.py count`) currently lists **39 tiles: 37
running live and 2 showcase posters** (backends retired, kept as a
placard). They span 1982 (Commodore 64, Microprofessor II) to 2024 (Haiku,
OpenVMS x86-64, AROS, ReactOS), including:

- **DOS/Windows across four decades** — MS-DOS + Windows 1.0, Windows 3.11,
  95, 98 SE, NT 3.51, NT 4.0, 2000, XP, up to Windows 11.
- **Unix and Unix-adjacent workstations** — Solaris CDE, SGI IRIX, QNX
  Neutrino, OpenVMS.
- **Hobby and research OSes** — SerenityOS, ToaruOS, TempleOS, KolibriOS,
  HelenOS, 9front (a Plan 9 fork), ReactOS.
- **8/16-bit home computers**, run through a period emulator inside a
  captured Linux kiosk (an "emulator-bridge" tile) — Commodore 64, Atari ST,
  Amiga Workbench, Apple II, Amstrad CPC.
- **Mobile** — Android-x86, Sailfish OS, postmarketOS.
- **Two showcase posters** — macOS and RISC OS — whose live backends were
  retired; the SPA renders a static placard rather than dialing a dead
  service.

A representative screenshot of one running tile lives at
`spa/public/posters/solaris/desktop.webp` (every production tile has an
equivalent under `spa/public/posters/<tile>/desktop.webp`, used as its SPA
poster image).

## How it works, briefly

```
browser (React/Vite SPA)
  ▲  WebTransport (QUIC): video frames in, pointer/keyboard events out
  │
streamhost — Rust daemon, one instance per guest ("tile")
  ▲  shared-memory scanout / QMP / serial, depending on the guest
  │
QEMU, MAME, or another emulator — one process per guest
```

Each guest is captured and encoded by its own `streamhost` process, one per
tile, which pushes H.264 + Opus to the browser over WebTransport and takes
pointer/keyboard input back the same way. The transport, encode and capture
design (damage-gated capture, dedicated encode thread, per-class input
streams, idle auto-pause) and the per-guest input plumbing (QMP console
injection, in-guest warpd agents, serial bridges) are described in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), not repeated here.

## Hardware and scope

This assumes a single Linux host (Proxmox VE in production) with enough CPU
and RAM to run ~30 concurrent guests plus their per-tile encoders — the lab
box is a Supermicro server, not a laptop. There is no cloud deployment path
and no installer: the [reproduction quickstart](docs/REPRODUCE-QUICKSTART.md)
separates what builds on any machine (the SPA, the `streamhost` daemon)
from what only makes sense against the Proxmox host and its VM inventory
(tile launchers, golden-image builders, `labctl`).

## Addresses and hostnames in these docs are placeholders

Every IP, hostname and domain shown here (`192.0.2.10`, `labhost.lan`,
`example.com`, and similar RFC 5737 / `.example` values) is a stand-in for
the operator's real lab box, substituted throughout before this repo was
published. They are not wrong values to fix, and they will not resolve —
reproducing the stack means supplying your own via `registry/local.env`
(see `registry/local.env.example` and `registry/README.md`) and the other
gitignored, operator-local files listed in `.gitignore`. A deployment left
on the placeholders builds but is unreachable. Please don't submit patches
that put real addresses, hostnames or credentials back into the repo.

## Where to start reading

- [`docs/README.md`](docs/README.md) — the documentation index: lab/host
  runbooks, per-guest build notes, media/software catalogs, and a
  `docs/history/` section of retired point-in-time status docs kept for
  context.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the technical overview:
  streaming path, daemon responsibilities, the tile/registry model, input
  paths, the public-gallery session-ticket layer.
- [`docs/REPRODUCE-QUICKSTART.md`](docs/REPRODUCE-QUICKSTART.md) — fresh-clone
  entry point.
- [`docs/lab/research/`](docs/lab/research/) — the research tree (WebGL
  gallery scene, low-latency input studies, and similar deep-dive work).
- [`docs/NAMING.md`](docs/NAMING.md) — why the project is Kernel Hive in
  prose and UI, but the daemon, `labctl` and the runtime paths keep their
  own established names.

## Repository layout

| Path                  | What lives there |
| ---------------------- | ---------------- |
| `streamhost/`         | Rust streaming daemon (WebTransport + in-process libx264/Opus), per-tile launchers, in-guest agents, crate docs in `streamhost/docs/` — **GPL-2.0-or-later** |
| `spa/`                 | The gallery front-end: Vite + React + TypeScript, WebCodecs decode |
| `tests/e2e-live/`      | Playwright suite that drives the *live* lab box — not run in CI |
| `scripts/`             | Ops tooling: `labctl` (unified box CLI), `build-guests/` (per-OS golden-image builders), `serve/` (HTTPS server for the SPA), `dev/` (build-and-deploy loop) — indexed in `scripts/README.md` |
| `registry/`            | The tile registry (source of truth for the tile roster) and per-tile poster prose |
| `docs/`                 | `lab/` runbooks and hardware notes, `guests/` per-OS notes, `catalog/` media and software catalogs, `history/` retired status docs |
| `.github/workflows/`   | CI: Rust fmt/clippy/test, SPA lint/build, shell + Python + workflow lint |

## Building the pieces

**SPA** (works on any machine with Node.js and npm):

```sh
cd spa
npm ci
npm run build     # a placeholder src/data/credentials.ts is created
                  # automatically from credentials.example.ts
npm run dev       # local dev server
```

**streamhost** (Linux; links the system libx264):

```sh
sudo apt-get install libx264-dev libopus-dev libclang-dev pkg-config cmake
cd streamhost
cargo build --release
cargo test
```

Everything else — tile launchers, golden-image builders, `labctl` — assumes
the Proxmox lab host and its VM inventory. Follow the
[reproduction quickstart](docs/REPRODUCE-QUICKSTART.md) for the required
external inputs and the ordered full-box runbook chain.

<!-- release-notes:start -->
## Release notes

### Week 4 · 2026-08-23 09:00 – 2026-08-30 09:00 · in progress

30 commits — Stations 14, Gallery UI 3, Retronet 11, Tooling & infrastructure 1, Other 1.

- **hpuxvue** — NCSA Mosaic on the retronet web plane (Netscape 4.79 is a dead end)
- **spa** — Give the router the same base the bundle was built with
- Retronet web: drop the charset parameter from our own pages' Content-Type
- **serve-https-spa** — Refuse to deploy a dist built for a staging base
- STREAM-DEBUGGING: read timing from clientTs, never srvTs
- **tru64** — Web browser applied to the live golden + re-baked
- …and 24 more

### Week 3 · 2026-08-16 09:00 – 2026-08-23 09:00

336 commits — Stations 84, Gallery UI 20, Streaming daemon 13, Retronet 89, Tooling & infrastructure 61, Docs 53, Dependencies 1, Other 15.

- **win98se** — Upgrade to ICQ 2001b (SSI), unique MAC + DHCP, silent self-reconnect
- **grid** — Foldable era sections and a filter that understands shorthand
- Rel-pointer plan: aux finding — 5ms poll trips A/UX X acceleration (needs accel-off golden)
- Retronet beos: park the evidence frames where they will survive
- **box-deploy** — Track tru64's veth helper, es40 launcher and ICQ fixture
- **docs** — solaris ICQ as-built — note the unique per-station MAC
- …and 330 more

### Week 2 · 2026-08-09 09:00 – 2026-08-16 09:00

281 commits — Stations 113, Gallery UI 2, Streaming daemon 17, Tooling & infrastructure 69, Docs 60, Dependencies 4, Other 16.

- atarist back on the floor: the spike it was hidden for has landed
- **posters** — Prose becomes runtime data — poster edits need no SPA rebuild
- **ctlsock** — Per-FIELD key pacing — the global one-edge-per-slot ceiling is gone
- MAME-native launcher: golden lives in sta/\<driver>/ (MAME nests savestates)
- **terminology** — MAME_NATIVE_GOLDEN -> MAME_NATIVE_CHECKPOINT (docs/GLOSSARY.md)
- Arm B boots the ST in 640x400 mono (SM124) — GEM Bench needs high res
- …and 275 more

### Week 1 · 2026-08-07 14:37 – 2026-08-09 09:00

16 commits — Stations 6, Gallery UI 3, Tooling & infrastructure 1, Docs 1, Dependencies 3, Other 2.

- **plus4** — Bake the golden at the machine's power-on screen, not inside the suite
- **spa** — Correct 41 gallery captions against the actual photographs, fix EXIF orientation
- **build** — Auto-load operator LAN/domain values from registry/local.env everywhere
- **docs** — Research two candidate exhibit families — PDP-11 and the 8/16-bit home computers
- Add a GitHub source link to the SPA footer and the login page
- **vic20** — Add the exhibit photo gallery, like its siblings
- …and 10 more

Full archive, every commit: [`docs/RELEASE-NOTES.md`](docs/RELEASE-NOTES.md).

Generated by `make release-notes` — do not hand-edit.
<!-- release-notes:end -->

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md): what can be built and verified
without lab hardware, the CI quality gate, and PR expectations.

## MAME fork

Several exhibits (SGI IRIX, the Microprofessor II) need MAME patches that
are not upstream. Those patches are published, one commit per patch, on a
fork of MAME at [github.com/Wnt/mame](https://github.com/Wnt/mame), on
branches `irix`, `irix-experimental` (working patches deliberately not
shipped in the default stack), and `mpf2`. The fork exists to support Kernel Hive.

## License

The repository is MIT-licensed (see `LICENSE`), with two exceptions:

- `streamhost/` is **GPL-2.0-or-later** (see `streamhost/LICENSE`) because the
  daemon links the system libx264, which is GPL. The two trees are independent
  — nothing outside `streamhost/` links against it.
- The historical photographs under `spa/public/posters/*/gallery/` are
  third-party works reused under free licenses (public domain, CC0, CC BY,
  CC BY-SA) and remain their authors' property. Every image's author, license
  and source page is listed in [`docs/IMAGE-CREDITS.md`](docs/IMAGE-CREDITS.md);
  the licenses are enforced mechanically against the Wikimedia Commons API by
  `scripts/tools/fetch-poster-gallery.py` (re-check with
  `make poster-gallery-verify`). CC BY-SA images carry share-alike obligations
  on modified redistribution.
