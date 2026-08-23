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

### Week 3 · The museum gets its own internet · 2026-08-16 09:00 – 2026-08-23 09:00

#### New stations

Seven machines joined the floor, each installed from original media the museum tracked down itself. [NEWS-OS](https://kernelhive.madekivi.fi/os/newsos) is Sony's own Unix, running on a *1991* *MIPS* laptop. [A/UX](https://kernelhive.madekivi.fi/os/aux) is Apple's strangest hybrid: a Unix root prompt living inside the Macintosh Finder. [SunOS](https://kernelhive.madekivi.fi/os/sunos414) brings up **OPEN LOOK** and [HP-UX](https://kernelhive.madekivi.fi/os/hpuxvue) answers with **HP VUE** — two rival visions of what a *1990s* Unix workstation should look like. [Rhapsody](https://kernelhive.madekivi.fi/os/rhapsody) is the missing link between NeXT and Mac OS X, the NeXT system wearing a Mac face. [BeOS](https://kernelhive.madekivi.fi/os/beos) is the fast, doomed upstart of the late nineties. And [Mac OS 7.5.3](https://kernelhive.madekivi.fi/os/macos753) runs on emulated *68040* hardware. [Tru64 UNIX](https://kernelhive.madekivi.fi/os/tru64), which arrived last week, got past the licensing wall that kept it shut, so the museum now stands at 68 machines, 65 of them open to visitors.

#### Major features

The museum now has <u>a private 1990s internet with no way out</u>. Sign into **ICQ** on [Windows 98 SE](https://kernelhive.madekivi.fi/os/win98se) and you can message someone at a [Solaris](https://kernelhive.madekivi.fi/os/solaris) workstation — or at [Windows 2000](https://kernelhive.madekivi.fi/os/win2000), [NT 4](https://kernelhive.madekivi.fi/os/nt4), the [Tru64](https://kernelhive.madekivi.fi/os/tru64) *Alpha*, or [BeOS](https://kernelhive.madekivi.fi/os/beos). All six carry each other in their contact lists, and a chatbot named HiveBot says hello about thirty seconds after one wakes up. Open **Internet Explorer 5** on that same Windows 98 and you land on 1998 web pages exactly as they were: real archived captures, nothing later than the end of 2000, so period sites work the way they did then, or break the way they did then. There is a period search engine over them too, with **AltaVista**-styled results and a **Yahoo!**-styled directory. BeOS browses the same pages in **NetPositive**. Nothing on that network can reach today's internet.

#### Quality improvements

Machines that used to make you wait mostly don't any more. The [Tru64](https://kernelhive.madekivi.fi/os/tru64) *Alpha* puts its **CDE** desktop on screen in about six seconds instead of a seven-to-ten-minute boot; [Windows 2000 on *Alpha*](https://kernelhive.madekivi.fi/os/w2kalpha) comes back complete in three seconds instead of eighty; [Mac OS 7.5.3](https://kernelhive.madekivi.fi/os/macos753) returns in a third of a second, pixel for pixel where you left it. Typing got honest: [Windows 3.11](https://kernelhive.madekivi.fi/os/win311) no longer freezes after a few dozen keystrokes, the [VIC-20](https://kernelhive.madekivi.fi/os/vic20) stopped quietly swallowing letters, and [NEWS-OS](https://kernelhive.madekivi.fi/os/newsos) no longer scrambles a fast-typed line. Dragging on the Apple machines holds all the way to where you let go, and the Commodore machines stopped clicking through the speakers on every reset. Every machine's write-up is now checked against primary sources and linked to its relatives on the floor.

#### Also this week

- Ask twice for a page the archive is missing and the museum goes and mirrors it, so its 1990s web grows from what visitors actually try to visit
- The Unix machines chat in a real window now: **Pidgin** on [Solaris](https://kernelhive.madekivi.fi/os/solaris), **Gaim** on the [Tru64](https://kernelhive.madekivi.fi/os/tru64) *Alpha*, in place of a terminal client
- [BeOS](https://kernelhive.madekivi.fi/os/beos) signs on through an older, pre-OSCAR door than anything else on the network — the only machine here that still speaks it
- The collection opens as a folding index by decade, and the filter above it understands the shorthand people actually type
- [Sony's NEWS portable](https://kernelhive.madekivi.fi/os/newsos) folds a 1120x780 monochrome LCD over its *R3000*: the line was Japan's answer to Sun, sold to its universities
- [Apple's Unix](https://kernelhive.madekivi.fi/os/aux) arrived with **QuickTime**, man pages and a shelf of Unix games — fortune, wump — sitting under the Finder
- **HP VUE** is the desktop **CDE** was built from, so [HP-UX](https://kernelhive.madekivi.fi/os/hpuxvue) now stands beside the CDE machines as their ancestor
- [SunOS](https://kernelhive.madekivi.fi/os/sunos414) is placed deliberately next to the CDE Solaris machine: same vendor, same *SPARC*, the rival desktop that lost
- Photographs of the real hardware sit beside the write-ups now — the BeBox, a Quadra 800, an HP 9000 B180L
- The picture stops dropping to a soft, low-detail mode for no reason: the stream had been reading its own keyframes as a slow connection
- The space bar on the [Sinclair QL](https://kernelhive.madekivi.fi/os/sinclairql) typed nothing at all. It types now, and a burst-typed line keeps its order

*35,569 lines of code.*

### Earlier weeks

- [Week 2 · Twenty-two machines in one week](docs/RELEASE-NOTES.md#week-2) · 2026-08-09 09:00 – 2026-08-16 09:00
- [Week 1 · The museum opens its source](docs/RELEASE-NOTES.md#week-1) · 2026-08-07 14:37 – 2026-08-09 09:00
- [Week 0 · The month the museum was built](docs/RELEASE-NOTES.md#week-0) · 2026-07-07 21:39 – 2026-08-07 14:37

Full archive: [`docs/RELEASE-NOTES.md`](docs/RELEASE-NOTES.md).

Every machine named here is live at [kernelhive.madekivi.fi](https://kernelhive.madekivi.fi).
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
