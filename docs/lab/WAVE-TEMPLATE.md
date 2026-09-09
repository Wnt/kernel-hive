# Wave brief template — copy this for `docs/lab/<ID>-WAVE.md`

Every new-station wave is a branch named `<id>` plus this doc, committed in the
spine (`ADD-NEW-OS-PLAYBOOK.md` §0, minute 0–3) right after
`scripts/dev/wave.sh alloc <id> [--retronet] [--x11warp]` and
`stations-registry.py new <id> --like <sibling> --production --slot auto`.
Fill the sections below with what those two commands actually printed and
measured — never a guess, never copied from another wave's numbers. Delete
this header line and the bracketed prompts when you copy it.

Read first: `ADD-NEW-OS-PLAYBOOK.md` §0, `AGENTS.md`, and for a
1990s/early-2000s guest the wall table at the end of §0 — most walls this
wave hits already have a fix recorded there.

## <Full OS name> integration wave — <date>

One line: what OS/release, what desktop, what tier, and which sibling
`--like` copies from. Name the coordination context if this wave runs beside
others (`WAVE-COORDINATION.md`, the landing lock via `wave.sh land`).

## Ledger — from `wave.sh alloc <id> --retronet --x11warp`

| Field | Value |
|---|---|
| slot / UDP port / VMID | |
| x11warp display | `:<slot-100>` (loopback `6<slot-100>`) |
| retronet address | `10.99.0.N` |
| retronet MAC | `52:54:00:52:4e:<N hex>` |
| retronet tap / chain | `<id>rn0` / `<ID>RN-IN` |
| ICQ UIN | `<slot>00` |
| sibling (`--like`) | |
| render orders (signal/stationsManifest/binding/golden/actionMap/bringUp) | as scaffolded — copy verbatim, do not hand-edit |
| device set | body/monitor/keyboard/mouse tuple, storage bus, NIC(s) — must be DISTINCT from the sibling's tuple |
| media | upstream URL, pinned version, measured byte size + sha256 (`stat -c "%n %s"`, `sha256sum`) |

## Proven in the spine (coordinator, alone)

What the spine actually established before the streams launched: the smoke
boot, the media staging, anything measured about the install path (PIO vs
DMA, `-smp`, accelerator) that the golden stream needs to know before it
starts.

## Streams

Each: `scripts/dev/wt.sh new <id>-<stream> --from <id>`, commit on its own
branch, push, report the branch. Hard stop at 4 minutes except `golden`,
which owns the device-set-complete bake (tap NIC + slirp `restrict=on` +
x11warp, all present in ONE bake — see §0's "Done means").

| Stream | Owns | Model | Status |
|---|---|---|---|
| `build` | `scripts/build-guests/tiles/<id>.sh`, `ASSETS-MANIFEST.md`, `os-media-catalog.md` rows | | |
| `golden` | bake + restore proof + x11warp two-target proof + `rn-onboard.sh`/`rn-verify.sh` + an IM client signed in (`docs/lab/retronet/ICQ-CLIENTS.md`) | | |
| `spa` | poster, hero, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa`/`demoProgram` | | |
| `docs` (after golden reports) | `docs/guests/<id>.md` incl. §Checkpoint, `GUEST-TIERS.md`, release notes, `docs/README.md` | | |

## Walls hit (if any)

For each wall: what step, what the framebuffer showed, the theories raced
(`scripts/dev/rig-clone.sh new <id> <theory>`, `fb-wait.py`), which theory
won and why, and whether it belongs in §0's wall table (a NEW mechanism)
or is specific to this guest (belongs in `docs/guests/<id>.md`).

## Landing

`scripts/dev/station-land.sh <id> --golden <staged.qcow2>` — paste its
step-by-step output. Note anything it stopped on and how it was resolved.

## Proofs (the framebuffer is the only proof — rule 9)

- `labctl shot <id>` before/after a key send
- x11warp two-target warp+readback (`x11warp-probe.py`)
- `rn-verify.sh <id>` (tap UP on `vmbr-rn`, unit active, reservation in CT
  951's `dhcp.env`, MAC on the bridge fdb)
- IM client visible in the scene, HiveBot reachable (after the coordinator's
  one-time `seed_contacts.py ssi --apply`)
- **IM client reconnects after `labctl reset <id>`** — not just signed in at
  bake time. `loadvm golden` restores the checkpoint with the OLD TCP socket,
  already dropped server-side, so the client must notice and re-log in, not
  sit on stale state. `labctl reset <id>` → wait up to 4 min AWAKE (wake
  lease) → `labctl shot <id>` shows the client ONLINE, not signed off or a
  login dialog, AND `rn-verify.sh <id> --icq <uin> --since <reset-ts>` finds a
  NEW login line in the gateway journal (the frame alone lies: suse64's client
  showed "Online" while the gateway rejected it). If it does not reconnect
  unassisted (Gaim 1.0, GtkICQ 0.60), the station needs the autorecon plugin
  or a restart wrapper (as slackware's micq and suse64's GtkICQ do) before
  this counts as done; the same path fires after every idle pause, since the
  gateway reaps a session that sends no keepalives — note which case this station is in the report

## OPEN items

Anything not proven inside this wave's budget — a client that would not
sign in, a browser not yet proven against `search.retronet`, a golden not
yet baked. Say what the next wave needs to pick this up, not just "TODO".

## Measured timeline

Run `scripts/dev/session-timeline.py` on this session's transcript after
landing; do not estimate. One row per milestone with wall-clock and minutes
from the operator's message (or from `wave.sh alloc`, whichever started the
clock).

| Milestone | Wall clock | Minute |
|---|---|---|
| `wave.sh alloc` / ledger committed | | |
| `/os/<id>` viewable (smoke-rig.sh) | | |
| streams merged | | |
| landed (`station-land.sh` done) | | |

## Teardown (part of "done" — rule 8)

What was released and the check that proved it: smoke rig down, stream
sandboxes removed (`wt.sh rm <id>-<stream>`), claims re-homed from
`$KH_SESSION` to the station session (`labctl who <id>`).
