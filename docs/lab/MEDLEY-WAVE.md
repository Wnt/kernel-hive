## Interlisp Medley integration wave — 2026-09-09

Interlisp Medley (the Xerox PARC Lisp environment, 1987 release line, as
maintained by the Interlisp project) as a **host-native Tier 3 station with
no emulated machine**: the maiko Lisp VM is a stock X client under a pinned
Xvfb, x11 root capture, XTEST input. `--like amix` (the only other
`SH_CAPTURE=x11` + `x11test` station), minus amix's guest-X warp redirect.
Ran beside the `sculpt`, `domainos` and `lisa` waves (`WAVE-COORDINATION.md`,
landing lock via `wave.sh land`).

## Ledger — from `wave.sh alloc medley --retronet --x11warp`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 191 / 54191 / 191 |
| x11warp display | `:91` (loopback `6091`) — used as the station's **Xvfb** display; no guest X server exists |
| retronet address | `10.99.0.39` (reservation held as the uniqueness ledger only; no tap script committed) |
| retronet MAC | in `.wave.env` / box `local.env` only |
| retronet tap / chain | `medleyrn0` / `MEDLEYRN-IN` |
| ICQ UIN | `19100` (unused — no IM client exists for Medley) |
| sibling (`--like`) | `amix` |
| render orders | signal 83 / stationsManifest 81 / binding 93 / golden 81 / bringUp 93 (as scaffolded) |
| hardware tuple | `pizzaBoxE|crtC|keyboardA|paramMouseA` (scaffold refused amix's; first free near it) |
| device set | none — maiko `ldex -g 1024x768 -sc 1024x768 -noscroll -m 256 full.sysout`, Xvfb `1024x768x24`, `LDEKBDTYPE=X` |
| media | `github.com/Interlisp/medley` release `medley-260826-3a14c9aa_260319-9259716e`, file `medley-full-linux-x86_64-260826-3a14c9aa_260319-9259716e.tgz`, **185512952 bytes**, sha256 `9e163aaf87a30f0e14e721826172d22c680153bab597c57ef20f39bea3736f76`, MIT |

## Proven in the spine (wave session, alone)

- VOM's config (`dmachine/altolike/interlisp_medley_231103_config`) read for
  facts only: it runs `run-medley` from the 2023-11-03 build with
  `LDEDESTSYSOUT=lisp.virtualmem`; default geometry 1440x900. Nothing copied.
- Smoke boot on labhost, Xvfb `:91`, 1024x768: **Exec + Medley logo on the
  first 2 s frame**, byte-identical (bar caret blink) through 60 s.
- `/os/medley` published by `smoke-rig.sh medley --like amix --slot 191` with
  the x11 placeholder-QMP trick, then `stream.env` patched to `:91`,
  `x11test`, `SH_X11TEST_ABS=1 / BUTTONS=xtest / KEYS=1` (the daemon logged
  `abs=true buttons=xtest keys=true (103 scancodes resolved)`).
- Pointer: `xdotool mousemove 200 300` / `900 700` read back exactly; the
  click focused the Exec. Keyboard: `(PLUS 40 2)` echoed byte-perfect and
  evaluated (`smoke/typed.png`).

## Streams

Fork rules forbade subagents, so the wave session ran every stream itself
(Fable). File ownership as in §0; no 4-minute stops were needed because the
guest has no install, no golden bake and no device-set race.

| Stream | Owns | Model | Status |
|---|---|---|---|
| `build` | `tiles/medley.sh` (pinned fetch, sha256, atomic stage, Xvfb boot proof), `ASSETS-MANIFEST.md`, `os-media-catalog.md` row | Fable (in-session) | done |
| `golden` | launcher + fixture + registry runtime/reset truth; relaunch proof on the station dir | Fable (in-session) | done |
| `spa` | poster, hero (smoke frame), `keyboardProfiles.ts`, scene rows (scaffold), `museum`/`spa`/`demoProgram` | Fable (in-session) | done |
| `docs` | `docs/guests/medley.md`, `GUEST-TIERS.md`, release notes, `docs/README.md` | Fable (in-session) | done |

## Walls hit

- **`smoke-rig.sh` for an X-client station**: the placeholder QMP socket must
  be started with `setsid nohup … </dev/null >log 2>&1 &` inside `labrun`; a
  plain `&` keeps the ssh session's stdout open and `labrun` never returns
  (this wave lost one 5-minute timeout to it). Wall-table candidate.
- **The borrowed `stream.env` streams the SIBLING's display**: `--like amix`
  copies `SH_X11_DISPLAY=:72`, i.e. amix's live Xvfb, and the daemon happily
  serves it. Patch `SH_X11_DISPLAY`, `SH_X11_CMD_FILE`, `SH_INPUT_BACKEND`
  and add the three `SH_X11TEST_*` flags before trusting `/os/<id>`.
- **`stations-registry.py new --like amix` refuses without `--tuple`** (the
  distinct-tuple rule); it prints the free tuples, pick one.
- **validate enums**: `stream.pointer.method` for this route is `x11-xtest`
  (not a new name), `network.status` is `none`; `demoProgram.perCharMs` must
  be ≥ hold+gap (80 at 40/40).
- **Release asset naming**: the tarball is
  `medley-full-linux-x86_64-<rel>.tgz` where `<rel>` already starts with
  `medley-…` — the filename does NOT repeat the prefix. A guessed URL 404s.

Host-native X-client route facts for the `lisa` wave (LisaEm): same shape —
`--like amix --tuple …`, launcher = amix's minus the warp block, fixture
`SH_X11TEST_MOTION=xtest SH_X11TEST_ABS=1 SH_X11TEST_BUTTONS=xtest
SH_X11TEST_KEYS=1`, `xvfb_alloc --display <slot-100>`, reap by
`/proc/<pid>/exe` under the asset dir, `mame.pid` as the pidfile name.

## Landing

See the report; `station-land.sh medley` output is pasted there.

## Proofs (rule 9)

- `smoke/f2.png`, `f30.png` — boot ≤2 s, stable scene.
- `smoke/typed.png` — keyboard.
- `smoke/p1.png`, `p2.png` + xdotool readback — pointer two targets.
- Relaunch proof on the real launcher: see the report.
- `rn-verify.sh`: not applicable (no network plane; reservation only).
- IM: not applicable.

## OPEN items

- Network plane via maiko's nethub/TAP bridge → retronet `10.99.0.39`
  (FTP/telnet demo only; no browser exists). Next step: read maiko's
  `-N`/nethub docs in `maiko/docs`, add a `rn-tapnet.sh` from the template,
  prove with tcpdump on `medleyrn0`.
- Richer greet scene (Inspector/Sketch open at rest) — a local greet file
  under `assets/medley/greet/` passed as `MEDLEY_GREET`.

## Measured timeline

Filled from `session-timeline.py` in the report.

| Milestone | Wall clock (UTC) | Minute |
|---|---|---|
| `wave.sh alloc` / ledger | 18:13 | 0 |
| smoke frame (Exec up) | 18:19 | 6 |
| `/os/medley` viewable | 18:22 | 9 |
| `/os/medley` interactive (x11test flags) | 18:24 | 11 |

## Teardown

See the report.
