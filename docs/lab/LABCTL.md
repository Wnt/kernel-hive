# `labctl` — driving a guest, and what each channel can and cannot prove

`labctl` is the unified labhost CLI. Source of truth `scripts/labctl` == labhost
`/usr/local/bin/labctl` (keep byte-identical; it is a box-sync pair).

**Run `ssh lab 'labctl'` for the command list** — it is self-documenting, so the
sub-commands are deliberately not duplicated here. This page carries only what
`--help` cannot tell you: which channel to reach for, what each one *proves*,
and the traps that have cost real time.

## Start every station task with `labctl facts <tile>`

One call for the facts sessions kept re-deriving out of ten files: the station's
id (registry id == `tileDir` == `SH_TILE`, and a warning if a live station ever
drifts off that), the real `streamhost@<x>.service` name and state, kind (kiosk / direct-QEMU /
x11-runtime, derived), declared-vs-actual bridge suite, disk + format + size +
backing + snapshot names, whether `reset` works and how, the exec channel, and
the checkpoint builder plus whether that builder *captures* the checkpoint or only prints
the operator's `--bake` step.

Takes the station id.
Repo-declared fields are read from the labhost checkout `/data/kernel-hive` and every
answer prints the commit it was read at plus a DIRTY count — that checkout only
advances on an explicit `sync`, so it may lag `main` and says so. Every field
degrades to null with a `warning:` naming the missing path, never a failed call.

## Channels, in order of preference

1. **`labctl exec <tile> "<cmd>"` — real captured stdout + exit code.** The
   guest's exit code becomes yours. Wired today for `solaris` (warpd `E`
   verb), the ssh stations `alpine`/`tinycore`/`haiku`, and the kiosks
   `c64`/`atarist`/`apple2`/`amiga`. `irix` is declared (`exec_kind`
   `serial_e`) but needs MAME running, so with the station stopped it says so and
   exits 125. Other stations exit 2 with alternatives.
2. **In-guest agent (warpd family)** — pointer + exec over a hostfwd, under the
   `labctl` layer. Captured and live on `solaris`, `ninefront`, `win95`, and
   `win311`/`os2warp`/`templeos` over serial. Sources in
   `streamhost/guest-agents/`.
3. **QMP console driver** — `/root/cdrv.py`, what `labctl sh/type/key/shot`
   call. QMP send-key types uppercase and symbols correctly where the browser
   path mangles them.
4. **Screendump is the output channel** for GUI/no-network guests. Install and
   automation agents MUST verify via real framebuffer screenshots, never disk or
   log inference.
5. **SLIRP tricks** — the guest reaches the host at `10.0.2.2`. Serve files from
   labhost with a one-shot python http.server and fetch in-guest, starting the
   server and the guest fetch in ONE atomic ssh command (backgrounded servers
   die between sessions). Adding a hostfwd to an EXISTING `-netdev user` is
   device-set-safe; adding any `-device` is **not**, and is forbidden without a
   full checkpoint recapture.

## Traps

- **`labctl sh` is BLIND** — it types a line and presses Enter, capturing
  nothing. It is not a substitute for `exec`.
- **`labctl type` bypasses key pacing** and drops characters *while printing
  "ok"*. It is not a fair test of whether a station's keyboard works — see
  [`ADD-NEW-OS-PLAYBOOK.md` §5.1](ADD-NEW-OS-PLAYBOOK.md#51-keyboard-only-exhibits--pacing-layout-and-the-type-in-demo).
- **`labctl assert --settle` is a tautology on a paused station.** Every
  unwatched station is idle-paused, so it compares one paused frame with itself and
  passes. Measured on six stations: `changed_fraction 0.0`, exit 0, while
  `labctl health` reported `paused (idle-paused)`.
- **`labctl shot` on a stopped station exits 2 and writes no file.** That is
  correct fail-closed behaviour, not a broken station — start the station first.
- **`labctl reset`** is `loadvm golden`, and refuses stations without a checkpoint
  snapshot (`serenityos`, `toaruos`, `sailfishos`).
- **One station, one name.** A station's registry id, its `tileDir` and its `SH_TILE`
  are the same string, and `tiles-registry.py` fails the build if an entry
  breaks that. The last two exceptions — `aros`/`amigaos` and
  `solaris`/`solariscde` — were renamed on 2026-08-10. The serving plane still
  reads the daemon's identity from the station's own `signaling.json` rather than
  trusting the endpoint key, because the daemon is the authority on what it will
  verify a ticket against; that is a guard against drift, not against a naming
  scheme that no longer exists.
- Regenerate the capability matrix with `labctl gen` after any launcher or
  `tile.env` change. It only ever touches stations in
  `/data/vms/streamhost/tiles.json`, and it **hard-fails** if a declared station has
  no live station directory.
