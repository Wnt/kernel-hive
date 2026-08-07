# Architecture

Technical overview of how Kernel Hive gets a guest OS's screen into a
browser tab and a visitor's keystrokes back into the guest. This is a map
into the deeper docs, not a replacement for them — each section links to
the file that actually specifies the behavior.

## The streaming path, end to end

```
QEMU / MAME / another emulator (one process per guest, "tile")
  │  shared-memory scanout, or QMP screendumps, or a serial console
  ▼
streamhost — Rust daemon, one instance per tile
  frame capture → damage tracking → H.264 (in-process libx264) + Opus
  │  WebTransport (QUIC), one unidirectional stream per access unit
  ▼
browser — React SPA (spa/), WebCodecs VideoDecoder, live tile grid
  ▲  pointer/keyboard events return over their own QUIC streams/datagrams
```

Each tile runs its own `streamhost` process; there is no shared fan-out
server on the media path. A `streamhost@<tile>` systemd unit per tile is
what's deployed on the lab box (see `AGENTS.md`'s access map for how an
operator reaches a running tile).

Design and the reasoning behind each piece: `streamhost/docs/DESIGN.md`.
Encoder/transport latency work and the measured numbers:
`streamhost/docs/LATENCY-NOTES.md`, `docs/INPUT-LATENCY.md`. The dbus-based
fast-poll QEMU patch that cuts capture latency: `streamhost/docs/CAPTURE-FASTPOLL.md`.
Idle-tile auto-pause/resume: `streamhost/docs/IDLE-PAUSE.md`. The `SH_*`
environment-variable reference: `streamhost/docs/CONFIG.md`.

## The daemon's responsibilities

One `streamhost` process, per tile, owns:

- **Capture** — pulling frames from the guest only when the emulator
  signals display damage (no fixed-rate re-encode of an unchanged screen).
- **Encode** — a dedicated `sh-encode` thread holding the x264 handle,
  constant-quality encoding with ABR tiers driven by client RTT/loss/queue
  feedback.
- **Transport** — WebTransport/QUIC to the browser: one H.264 Annex-B
  access unit per unidirectional stream, decoded on stream completion; a
  forced keyframe on join so a new viewer never waits for the next GOP.
- **Input** — receiving pointer/keyboard/wheel events from the browser and
  injecting them into the guest by whichever channel that guest supports
  (see below), each input class on its own QUIC stream so one class can't
  block another.
- **Session gating** — refusing any WebTransport session that doesn't
  present a valid ticket for that tile (see "Session tickets" below).
- **Idle management** — QMP-pausing an unwatched guest after a grace
  period and resuming it on the next visitor.

Source: `streamhost/streamhost/src/`. Per-tile launch scripts (the exact
device set, capture channel, and any in-guest agent a tile needs) live
under `streamhost/tiles/<tile>/` and `scripts/build-guests/`.

## The tile / registry model

A **tile** is one guest OS instance: an emulator process, its `streamhost`
capture/encode/transport wrapper, a golden disk image with a known-good
snapshot to reset to, and an entry in the registry describing all of that.
`registry/tiles/<osId>.json` is the single typed source of truth (schema at
`registry/schema/tile-v1.schema.json`); `scripts/tiles-registry.py generate`
renders it into the deployed artifacts (`registry/index.json`, the
manifest `streamhost` consumes, SPA poster data). Never hand-edit a
generated file — edit the registry source and regenerate; `make
tile-registry-check` fails a drifted generated file. Current roster size:

```sh
python3 scripts/tiles-registry.py count
```

A registry entry records a tile's **lifecycle** (`production` — running
live; `showcase` — poster-only, backend retired; also `experiment` and
`candidate` for work in progress), its build recipe, its runtime env
(`SH_*` vars, ports), and — for production tiles — a poster (prose in
`registry/posters/`, hero image at `spa/public/posters/<tile>/desktop.webp`)
so an exhibit is never live without something to show for it.

Turning a guest into a tile is the subject of
[`docs/lab/ADD-NEW-OS-PLAYBOOK.md`](lab/ADD-NEW-OS-PLAYBOOK.md) — sourcing
install media, building a golden image, wiring the registry entry, and the
acceptance checks a new tile has to pass before it ships.

## Input paths

Guests fall into a few families depending on what channel they expose:

- **Networked guests with a shell** — `streamhost` (or the operator, via
  `labctl exec`) reaches them over SSH/a bridge key and gets real captured
  stdout and exit codes.
- **GUI guests with no exec channel** — driven blind through the QMP
  console (deterministic key injection, absolute pointer via `usb-tablet`
  or `dbus`, screendumps as the only proof of state) or a small in-guest
  agent (the `warpd` family: a TCP or serial listener baked into several
  golden images that accepts pointer/exec verbs). See
  `streamhost/guest-agents/*/README.md` per agent and
  `docs/lab/INPUT-DEBUGGING.md` for which code path a given press actually
  takes.
- **Emulator-bridge tiles** (period 8/16-bit machines) — a captured Linux
  kiosk running the period emulator (VICE, Hatari, FS-UAE, LinApple); input
  reaches the emulator window the same way any bridge-tile input does, one
  layer further removed from the guest OS itself.

Pacing (`SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS`, `SH_ABS_PACE_MS`) matters
because an emulator samples input once per emulated frame; the release→press
gap between synthetic keystrokes has to survive that sampling. See
`docs/lab/ADD-NEW-OS-PLAYBOOK.md` §5.1 for the measurements behind the
current defaults.

## Public gallery and session tickets

The LAN origin (`streamhost`'s WebTransport listeners, the HTTPS SPA
origin) is open and unauthenticated by design — it's a home network. The
public deployment adds a session-gated listener in front of it, described
in full in [`docs/PUBLIC-GALLERY.md`](PUBLIC-GALLERY.md):

1. A **session gate** in front of the public HTTP listener — default-deny,
   only the login page and `/auth/*` reachable without a session.
2. A **passkey** (WebAuthn) login that issues a server-side session cookie.
3. A **media-plane ticket** (`streamhost/src/session_ticket.rs`): because a
   WebTransport session carries a tile's *input* plane as well as its
   video, the authenticated gateway mints a short-lived HMAC ticket per
   connect, and every tile with `SH_SESSION_KEY` set refuses a session
   whose path doesn't carry a live one — LAN callers included, so minting
   only for the public listener would have left the LAN gallery unusable.

A WebTransport client must use the `path` from a tile's `/signal/<tile>.json`
verbatim; a hardcoded path is refused (`SESSION_REJECTED` in the daemon's
journal).

## Where the deeper docs live

| Area | Doc |
| --- | --- |
| Daemon design, encoder, transport internals | `streamhost/docs/DESIGN.md`, `streamhost/docs/LATENCY-NOTES.md`, `streamhost/docs/CONFIG.md` |
| Bridge-tile pattern (period emulator inside a captured kiosk) | `streamhost/docs/BRIDGE.md`, `streamhost/docs/GRAPHICAL-BRIDGE.md` |
| Capture fast-poll QEMU patch | `streamhost/docs/CAPTURE-FASTPOLL.md` |
| Idle auto-pause | `streamhost/docs/IDLE-PAUSE.md` |
| Input latency budget and levers | `docs/INPUT-LATENCY.md` |
| Pointer/tap/drag debugging | `docs/lab/INPUT-DEBUGGING.md` |
| Adding a new OS tile | `docs/lab/ADD-NEW-OS-PLAYBOOK.md` |
| Registry schema and generated artifacts | `registry/README.md` |
| Public gallery (passkeys, invites, session tickets) | `docs/PUBLIC-GALLERY.md` |
| Per-guest build/install notes | `docs/guests/<os>.md` |
| Documentation index | `docs/README.md` |
