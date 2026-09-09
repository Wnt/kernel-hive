# Kernel Hive

**A living computer museum. Ninety-odd machines, from 1970 to today, running
right now — and you can move their mice.**

<a href="https://kernelhive.madekivi.fi">
  <img src="docs/media/hero.webp" alt="Twenty desktops from the collection, side by side" width="100%">
</a>

![A machine opening, the pointer moving, a line being typed](docs/media/demo.gif)

*Not a video of an old computer. That is a real guest, booted, at the other end
of a browser tab — the pointer and the keystrokes are going back into it.*

[![rust](https://img.shields.io/github/actions/workflow/status/Wnt/kernel-hive/rust.yml?branch=main&label=rust)](https://github.com/Wnt/kernel-hive/actions/workflows/rust.yml)
[![spa](https://img.shields.io/github/actions/workflow/status/Wnt/kernel-hive/spa.yml?branch=main&label=spa)](https://github.com/Wnt/kernel-hive/actions/workflows/spa.yml)
[![quality](https://img.shields.io/github/actions/workflow/status/Wnt/kernel-hive/quality.yml?branch=main&label=quality)](https://github.com/Wnt/kernel-hive/actions/workflows/quality.yml)
[![licence: MIT](https://img.shields.io/badge/licence-MIT-informational)](LICENSE)
[![streamhost: GPL-2.0-or-later](https://img.shields.io/badge/streamhost-GPL--2.0--or--later-informational)](streamhost/LICENSE)

## Why this is interesting

- **Every machine here is live, not a recording.** Open one and you are driving
  a running guest: click a menu, launch an application, break something. There
  is no scripted path and nothing pre-rendered.
- **The pointer lands where you point — even on a 1990s Unix workstation.**
  Most of these systems only understand *motion*, not position, so a browser's
  coordinates used to turn into a cursor that crawled behind your hand. On the
  hardest machines the emulator now reads the cursor back out of the graphics
  chip's own registers and steers until the two agree. Click to photon is
  around 20–25 ms on the LAN
  ([`docs/INPUT-LATENCY.md`](docs/INPUT-LATENCY.md)).
- **The machines are wired to a 1990s internet that has no way out.** Sign into
  **ICQ** on Windows 98 and message someone at a Solaris workstation; open
  **Internet Explorer 5** and land on archived 1998 pages exactly as they were,
  nothing later than the end of 2000. A chatbot lives on that network and says
  hello about thirty seconds after a machine wakes up. Nothing on it can reach
  today's internet.
- **You can have one to yourself.** No invitation needed: sign up and the
  museum hands you a private copy of Windows 3.11, OS/2 Warp or Rhapsody. Wreck
  it, close the tab — the next visitor still gets a pristine one.

## Visit the museum

**[kernelhive.madekivi.fi](https://kernelhive.madekivi.fi)**

Walk in and you can register an account on the spot and be given a private
machine for the visit — three to choose from, yours to install things on and
ruin. Signing in on an invited account opens the whole floor instead: every
live machine in the collection, its write-up, photographs of the real hardware
it is imitating, and the private 1990s internet several of them are joined to.
Sign-in is a passkey, so there is no password to pick.

The full public path — the edge, the three gates, the media plane — is
[`docs/PUBLIC-GALLERY.md`](docs/PUBLIC-GALLERY.md).

## The lineup

Every machine on the floor, by the decade it came from. Each one is a link
straight into the running system.

<!-- lineup:start -->
<!-- lineup:end -->

## How it works

![Browser, streaming daemon and emulator, with the retronet plane beside them](docs/media/architecture.svg)

A browser tab decodes H.264 and Opus arriving over WebTransport, and sends the
pointer and keyboard back the same way. Behind it, one small Rust daemon per
machine captures the screen only when it actually changes, encodes it, and
injects your input into the guest by whichever channel that guest understands.
Behind *that* is a period-correct emulator — QEMU, MAME, FS-UAE or an Alpha
simulator — and, for some machines, the museum's own private network.
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) is the map into the rest.

### Six things that turned out to be hard

- **Nobody wants to watch a boot.** A machine is launched already restored to a
  captured full machine state — RAM, devices and disk together — and left
  paused; the first visitor to arrive resumes it. Which is why a Tru64 Alpha
  puts a CDE desktop on screen in seconds rather than minutes.
  ([`docs/GUEST-TIERS.md`](docs/GUEST-TIERS.md),
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md))
- **The closed-loop pointer.** Where a guest exposes no absolute pointing
  device, the emulator reads the cursor position back — from the graphics
  chip's registers, or from the address the operating system itself keeps its
  pointer at — and corrects until it matches. Arithmetic and hope was not
  enough; a feedback loop was.
  ([`docs/lab/INPUT-DEBUGGING.md`](docs/lab/INPUT-DEBUGGING.md))
- **Encoding a screen that mostly does not move.** An idle desktop should cost
  nothing, and a dragged window should still be smooth. Capture is gated on the
  emulator signalling damage rather than run at a fixed rate, encoding happens
  on its own thread at constant quality, and an unwatched machine is paused
  outright. ([`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md),
  [`streamhost/docs/DESIGN.md`](streamhost/docs/DESIGN.md),
  [`streamhost/docs/IDLE-PAUSE.md`](streamhost/docs/IDLE-PAUSE.md))
- **Giving the 1990s machines an internet.** Period browsers and period chat
  clients speaking real HTTP/1.0 and real OSCAR to services inside the lab,
  against an archive of pages as they were — with no route to the modern web
  anywhere in the design, because half of what makes it convincing is that it
  cannot cheat. ([`docs/lab/RETRONET-BRIEF.md`](docs/lab/RETRONET-BRIEF.md),
  [`docs/lab/retronet/`](docs/lab/retronet/))
- **Handing a stranger a machine of their own.** A private copy per visitor,
  spun off a shared starting state onto its own throwaway overlay and its own
  isolated network, reaped when the visit ends.
  ([`docs/lab/WALKIN-BRIEF.md`](docs/lab/WALKIN-BRIEF.md))
- **Patching the emulators.** Several exhibits only exist because the emulator
  was changed: an SGI Indy that panics under hardware virtualisation, an Amiga
  that had to publish its frames into shared memory, an Alpha, and a Cirrus
  card that restored a saved Windows NT desktop in the wrong colours for
  reasons that took a trace to find. The patches are published, one commit per
  patch. ([`docs/lab/ES40-FORK-BRIEF.md`](docs/lab/ES40-FORK-BRIEF.md),
  [`docs/lab/FSUAE-NATIVE-BRIEF.md`](docs/lab/FSUAE-NATIVE-BRIEF.md),
  [`streamhost/qemu-patches/`](streamhost/qemu-patches/))

## This week at the museum

The museum keeps a written account of every week. The latest one:

<!-- release-notes:start -->
## Release notes

### Week 5 · The mouse finally lands · 2026-08-30 09:00 – 2026-09-06 09:00

#### New stations

Three machines arrived. [Amiga UNIX](https://kernelhive.madekivi.fi/os/amix) is the Amiga's road not taken: Commodore licensed AT&T's **System V Release 4**, put **OPEN LOOK** on it instead of Motif, and sold it on the *Amiga 3000UX* to almost nobody. It boots from the real 1992 installation tape onto an emulated *68030*, and runs in colour on the **A2410**, a card most owners never bought. Its cursor lands exactly where you point, by a route no other machine here uses: the museum reaches inside the guest's own X server and moves the pointer there. [ravynOS](https://kernelhive.madekivi.fi/os/ravynos) also joined. At the other extreme, [bootOS](https://kernelhive.madekivi.fi/os/bootos) is an entire operating system in **512 bytes**, the one sector a PC reads to start up: a prompt, a filesystem and a hex loader, written by Óscar Toledo G. in two evenings in 2019. Its floppy carries nineteen more one-sector programs — chess, a Doom, a BASIC, a Flappy Bird — and you run one by typing its name. That makes 75 machines, 71 of them open to visitors.

#### Major features

<u>Five more machines now put the cursor exactly where you point.</u> A mouse in a browser sends a position; most of these guests only understand motion, which is why a cursor used to crawl behind your hand and pile up in a corner. [AIX](https://kernelhive.madekivi.fi/os/aix432) and [HP-UX](https://kernelhive.madekivi.fi/os/hpuxvue) closed that by letting the emulator read the cursor back out of the graphics chip's own registers and steer until it agrees — a real feedback loop rather than arithmetic and hope. [Rhapsody](https://kernelhive.madekivi.fi/os/rhapsody), [Mac OS 7.5.3](https://kernelhive.madekivi.fi/os/macos753) and [BeOS](https://kernelhive.madekivi.fi/os/beos) have no such chip, so instead the emulator writes the coordinate straight into the place each operating system keeps its own pointer, and nudges it awake. On all five the cursor is now 1:1: no chase, no drift, no corner.

#### Quality improvements

The private machines handed out to signed-in visitors left everyone else on a blank front page; the museum now renders one hall for all and picks what you see by who you are. Clicks, not just movement, take the corrected route into AIX, so a button press lands where the cursor already is. AIX also had an invisible magnet — pass near a window's resize handle and the pointer stuck to it — which is gone. And the museum's own weekly test used to count cards on the collection page, quietly passing while the page was empty; it now checks the gallery really drew.

#### Also this week

- [Amiga UNIX](https://kernelhive.madekivi.fi/os/amix) installs from a 29-segment tape image, the way an *A3000UX* really did — roughly two hours of emulated restore
- **OPEN LOOK** is the desktop Sun and AT&T backed against **Motif**; Amiga UNIX is the only machine here that runs it
- [bootOS](https://kernelhive.madekivi.fi/os/bootos) keeps one file per floppy track, thirty-two at most; the museum snapshots the floppy, so a deleted game is gone only until the next reset
- Type `enter` on bootOS and it takes a program as lines of hex; the 'Hello, world' from its own manual is the exhibit's demo button
- [AIX](https://kernelhive.madekivi.fi/os/aix432)'s graphics card had to be identified from a driver's file name before its cursor could be read back at all
- [Mac OS 7.5.3](https://kernelhive.madekivi.fi/os/macos753) keeps its pointer in low memory, and the museum writes it there the same way the system's own mouse driver does
- [HP-UX](https://kernelhive.madekivi.fi/os/hpuxvue)'s cursor loop needed no new emulated hardware — the registers were already there, so no machine had to be rebuilt
- [Rhapsody](https://kernelhive.madekivi.fi/os/rhapsody)'s pointer lives at an address belonging to one saved disk, so the emulator checks it before every write and refuses if it moved
- A new tool finds the cursor in a captured frame, which is how each of these loops was proved rather than assumed
- Amiga UNIX seemed stuck in monochrome because a search tool had been silently skipping the one file that proved the emulator could drive its colour card

*7,484 lines of code.*

### Earlier weeks

- [Week 4 · The doors open to everyone](docs/RELEASE-NOTES.md#week-4) · 2026-08-23 09:00 – 2026-08-30 09:00
- [Week 3 · The museum gets its own internet](docs/RELEASE-NOTES.md#week-3) · 2026-08-16 09:00 – 2026-08-23 09:00
- [Week 2 · Twenty-two machines in one week](docs/RELEASE-NOTES.md#week-2) · 2026-08-09 09:00 – 2026-08-16 09:00
- [Week 1 · The museum opens its source](docs/RELEASE-NOTES.md#week-1) · 2026-08-07 14:37 – 2026-08-09 09:00
- [Week 0 · The month the museum was built](docs/RELEASE-NOTES.md#week-0) · 2026-07-07 21:39 – 2026-08-07 14:37

Full archive: [`docs/RELEASE-NOTES.md`](docs/RELEASE-NOTES.md).

Every machine named here is live at [kernelhive.madekivi.fi](https://kernelhive.madekivi.fi).
<!-- release-notes:end -->
## A reading tour

Five documents worth reading even if you never run any of this.

1. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the whole system in one
   sitting, including the awkward truth that for a large part of the collection
   the thing being captured is not the machine you came to see, but a bare
   Linux screen with a period emulator filling it edge to edge.
2. [`docs/INPUT-LATENCY.md`](docs/INPUT-LATENCY.md) — where every millisecond
   between a key press and the pixel changing actually goes, stage by stage,
   measured rather than assumed, with what is left to win.
3. [`docs/lab/nt4-cirrus-vmstate-trace-fix.md`](docs/lab/nt4-cirrus-vmstate-trace-fix.md)
   — a detective story: Windows NT 4 cold-boots to a clean desktop but always
   restores a blue-lavender one, and the culprit is a struct being read at the
   wrong offset. The before-and-after screenshots are in
   [`docs/lab/nt4-cirrus-vmstate-proofs/`](docs/lab/nt4-cirrus-vmstate-proofs/).
4. [`docs/lab/RETRONET-BRIEF.md`](docs/lab/RETRONET-BRIEF.md) — the design for
   an internet that only goes backwards: what a 1997 browser needs, why every
   service is offline by construction, and what it costs to put a real machine
   on it without breaking it.
5. [`docs/guests/irix.md`](docs/guests/irix.md) — one machine, at length. An
   SGI Indy with no window, no virtual machine and no display at all, publishing
   frames into shared memory, and the long list of performance angles that were
   measured and closed — including the one closed in error and reopened.

If a word in any of these is unfamiliar,
[`docs/GLOSSARY.md`](docs/GLOSSARY.md) is the whole vocabulary on one page.

---

<details>
<summary><b>Status — a home lab, not a product</b></summary>

<br>

Personal home-lab project. Everything here is built against one specific
machine ("the lab box"), a single Proxmox host. The code is published for
reading, reuse and reference; reproducing the full gallery is real work, and
the docs describe that work rather than hiding it behind an installer.

The public gallery is reachable over the internet, but every session is
authenticated — by passkey, on an invited account or a self-registered one.

</details>

<details>
<summary><b>Building the pieces</b></summary>

<br>

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

Everything else — station launchers, seed-image builders, `labctl` — assumes
the Proxmox lab host and its VM inventory. Follow the
[reproduction quickstart](docs/REPRODUCE-QUICKSTART.md) for the required
external inputs and the ordered full-box runbook chain.

</details>

<details>
<summary><b>Hardware and scope</b></summary>

<br>

This assumes a single Linux host (Proxmox VE in production) with enough CPU and
RAM to run the fleet plus a per-station encoder — the lab box is a Supermicro
server, not a laptop. There is no cloud deployment path and no installer: the
[reproduction quickstart](docs/REPRODUCE-QUICKSTART.md) separates what builds on
any machine (the SPA, the `streamhost` daemon) from what only makes sense
against the Proxmox host and its VM inventory (station launchers, seed-image
builders, `labctl`).

</details>

<details>
<summary><b>Repository layout</b></summary>

<br>

| Path | What lives there |
| --- | --- |
| `streamhost/` | Rust streaming daemon (WebTransport + in-process libx264/Opus), per-station launchers, in-guest agents, crate docs in `streamhost/docs/` — **GPL-2.0-or-later** |
| `spa/` | The gallery front-end: Vite + React + TypeScript, WebCodecs decode |
| `tests/e2e-live/` | Playwright suite that drives the *live* lab box — not run in CI |
| `scripts/` | Ops tooling: `labctl` (unified box CLI), `build-guests/` (per-OS seed-image builders), `serve/` (HTTPS server for the SPA), `dev/` (build-and-deploy loop) — indexed in [`scripts/README.md`](scripts/README.md) |
| `registry/` | The station registry (source of truth for the roster) and per-station poster prose |
| `docs/` | `lab/` runbooks and hardware notes, `guests/` per-OS notes, `catalog/` media and software catalogs, `history/` retired status docs — indexed in [`docs/README.md`](docs/README.md) |
| `.github/workflows/` | CI: Rust fmt/clippy/test, SPA lint/build, shell + Python + workflow lint |

</details>

<details>
<summary><b>Addresses and hostnames in these docs are placeholders</b></summary>

<br>

Every IP, hostname and domain shown in this repository (`192.0.2.10`,
`labhost.lan`, `example.com`, and similar RFC 5737 / `.example` values) is a
stand-in for the operator's real lab box, substituted throughout before this
repo was published. The one deliberate exception is the gallery's own public
address, `kernelhive.madekivi.fi`.

Placeholders are not wrong values to fix, and they will not resolve —
reproducing the stack means supplying your own via `registry/local.env` (see
`registry/local.env.example` and [`registry/README.md`](registry/README.md)) and
the other gitignored, operator-local files listed in `.gitignore`. A deployment
left on the placeholders builds but is unreachable. Please don't submit patches
that put real addresses, hostnames or credentials back into the repo.

</details>

<details>
<summary><b>The MAME fork</b></summary>

<br>

Several exhibits (SGI IRIX, the Microprofessor II) need MAME patches that are
not upstream. Those patches are published, one commit per patch, on a fork of
MAME at [github.com/Wnt/mame](https://github.com/Wnt/mame), on branches `irix`,
`irix-experimental` (working patches deliberately not shipped in the default
stack), and `mpf2`. The fork exists to support Kernel Hive.

</details>

<details>
<summary><b>Contributing</b></summary>

<br>

See [`CONTRIBUTING.md`](CONTRIBUTING.md): what can be built and verified
without lab hardware, the CI quality gate, and PR expectations.

</details>

<details>
<summary><b>License</b></summary>

<br>

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

</details>
