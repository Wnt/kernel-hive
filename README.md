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

### Week 5 · Nine Unixes in one night · 2026-08-30 09:00 – 2026-09-06 09:00

#### New stations

<u>Nine Unix and Linux machines arrived in a single night.</u> [Slackware 3.4](https://kernelhive.madekivi.fi/os/slackware) brings 1997's **fvwm95**, the desktop that made a Unix workstation look like Windows 95; [NetBSD 1.4.1](https://kernelhive.madekivi.fi/os/netbsd14) follows from 1999. The year 2000 gives three at once — [Red Hat Linux 6.2 "Zoot"](https://kernelhive.madekivi.fi/os/redhat62) with **GNOME 1.0**, [Debian 2.2 "potato"](https://kernelhive.madekivi.fi/os/debian22), and [SuSE Linux 6.4](https://kernelhive.madekivi.fi/os/suse64) with **KDE 1**, from the last spring SuSE spelled itself with a small u. [Ubuntu 4.10 "Warty Warthog"](https://kernelhive.madekivi.fi/os/ubuntu) is the very first Ubuntu, running off its live CD, so every reset returns to the same instant. [FreeBSD 4.11](https://kernelhive.madekivi.fi/os/freebsd411) closes the 4.x line with the full **KDE 3.3.2**; [PC-BSD 1.5.1](https://kernelhive.madekivi.fi/os/pcbsd) is FreeBSD made point-and-click; [OpenBSD 7.9](https://kernelhive.madekivi.fi/os/openbsd) stands at the modern end. Earlier in the week came [Amiga UNIX](https://kernelhive.madekivi.fi/os/amix), Commodore's *System V Release 4* with **OPEN LOOK**, in colour on the **A2410** card most owners never bought; [ravynOS](https://kernelhive.madekivi.fi/os/ravynos); [PC/GEOS Ensemble](https://kernelhive.madekivi.fi/os/pcgeos), a 1990 desktop in *640 KB on a 286*; and [bootOS](https://kernelhive.madekivi.fi/os/bootos), a whole operating system in *512 bytes*. That makes 87 machines, 85 of them open to visitors.

#### Major features

Eight of the new arrivals joined the museum's private 1990s internet, browsing the archived web through the browser each would really have had, from **Netscape 4.77** on [Debian](https://kernelhive.madekivi.fi/os/debian22) to **Lynx** on [NetBSD](https://kernelhive.madekivi.fi/os/netbsd14). Seven signed on to the chat network too, taking it from eleven machines to nineteen. [Windows 3.11](https://kernelhive.madekivi.fi/os/win311) joined through the **AOL Instant Messenger** already sitting on its disk, and a bridge now relays between the AIM and ICQ halves, so a 1993 desktop can answer a message from a 2000 Linux box. A machine you have just reset signs itself back in, unprompted. The cursor landed on many more machines as well: [AIX](https://kernelhive.madekivi.fi/os/aix432) and [HP-UX](https://kernelhive.madekivi.fi/os/hpuxvue) read it back out of the graphics chip's own registers and steer until it agrees, while [Rhapsody](https://kernelhive.madekivi.fi/os/rhapsody), [Mac OS 7.5.3](https://kernelhive.madekivi.fi/os/macos753) and [BeOS](https://kernelhive.madekivi.fi/os/beos) have the coordinate written straight into the place each system keeps its own pointer. Cursor and hand now agree exactly.

#### Quality improvements

[AIX](https://kernelhive.madekivi.fi/os/aix432) had stopped taking the keyboard and would lock itself out; [HP-UX](https://kernelhive.madekivi.fi/os/hpuxvue) looked broken the same way and turned out to be a focus trap, not a fault. Both type again. A key still held down when you close the tab is released now, so nobody arrives to a machine stuck on shift. The private machines handed to signed-in visitors used to leave everyone else on a blank front page; the museum renders one hall for all.

#### Also this week

- Each new arrival chats with its era's own client — **GtkICQ** on SuSE, **GnomeICU** on Debian, **mICQ** on NetBSD, **Kopete** on PC-BSD, **Gaim** on Ubuntu
- The network's resident bot says hello about a minute after a machine signs in, and every station carries every other one in its contact list
- [FreeBSD 4.11](https://kernelhive.madekivi.fi/os/freebsd411)'s network card went silent after every reset, so it was swapped for one that survives — the fault shows only on the wire
- [NetBSD 1.4.1](https://kernelhive.madekivi.fi/os/netbsd14) needed a kernel built inside the guest: the stock 1999 one hangs on this hardware before it ever reaches the disk
- [Slackware 3.4](https://kernelhive.madekivi.fi/os/slackware)'s 1997 boot floppy still wedges under a modern emulator, so the museum boots its kernel from a GRUB2 rescue disc instead
- [FreeBSD 4.11](https://kernelhive.madekivi.fi/os/freebsd411) reads a CD one 16-bit word at a time, so it had to be installed on the slow software emulator and only then run at full speed
- [Debian 2.2](https://kernelhive.madekivi.fi/os/debian22) writes an emulated disk just as slowly, so its root filesystem was assembled outside the machine and handed over finished
- [Red Hat Linux 6.2](https://kernelhive.madekivi.fi/os/redhat62) installs itself from a kickstart file and [OpenBSD](https://kernelhive.madekivi.fi/os/openbsd) from a scripted installer — nobody answers a prompt
- [SuSE Linux 6.4](https://kernelhive.madekivi.fi/os/suse64) is installed by SuSE's own graphical **YaST2** — what its CD really boots, not the text YaST everyone remembers
- [Amiga UNIX](https://kernelhive.madekivi.fi/os/amix) installs from a 29-segment tape image, the way an *A3000UX* really did — roughly two hours of emulated restore
- **OPEN LOOK** is the desktop Sun and AT&T backed against **Motif**; Amiga UNIX is the only machine here that runs it
- [bootOS](https://kernelhive.madekivi.fi/os/bootos)'s floppy carries chess, a Doom, a BASIC and a Flappy Bird, each one sector long; you run one by typing its name
- Type `enter` on bootOS and it takes a program as lines of hex; the 'Hello, world' from its own manual is the exhibit's demo button
- [PC/GEOS Ensemble](https://kernelhive.madekivi.fi/os/pcgeos) boots straight into its desktop from FreeDOS, and its word processor stopped crashing once one font was dropped
- [AIX](https://kernelhive.madekivi.fi/os/aix432)'s graphics card had to be identified from a driver's file name before its cursor could be read back at all
- [Mac OS 7.5.3](https://kernelhive.madekivi.fi/os/macos753) keeps its pointer in low memory, and the museum writes it there the same way the system's own mouse driver does
- [Rhapsody](https://kernelhive.madekivi.fi/os/rhapsody)'s pointer lives at an address belonging to one saved disk, so the emulator checks it before every write and refuses if it moved
- A new tool finds the cursor in a captured frame, which is how each of these loops was proved rather than assumed
- [OpenBSD](https://kernelhive.madekivi.fi/os/openbsd)'s tablet pointer needed one fix after X registered the same device twice, once with no calibration range
- [ravynOS](https://kernelhive.madekivi.fi/os/ravynos) 0.6.1 is the last of its kind — days after this build, its makers threw the FreeBSD kernel away and deleted the line

*76,663 lines of code.*

### Earlier weeks

- [Week 4 · The doors open to everyone](docs/RELEASE-NOTES.md#week-4) · 2026-08-23 09:00 – 2026-08-30 09:00
- [Week 3 · The museum gets its own internet](docs/RELEASE-NOTES.md#week-3) · 2026-08-16 09:00 – 2026-08-23 09:00
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
