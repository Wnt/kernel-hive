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
- **Idle auto-pause eats a hand-driven proof.** With no visitor attached the
  daemon SIGSTOPs maiko after 60 s (`[idle] no sessions for 60s -> guest
  paused`, `State: T`), so an `xdotool type` on `:91` changes nothing and a
  naive proof reads as "keyboard dead". Hold the wake lease first
  (`touch /run/streamhost/wake/medley.lease`, TTL 90 s) and wait for
  `State: S` — same trap as the QMP stations' "probe with a wake lease" row,
  now proven on an X-client station too.
- **`maiko` refuses a bare positional sysout** when run outside
  `run-medley`: it wants `LDESRCESYSOUT` in the environment (the usage text
  says so). Both the launcher and the builder export it.
- **Release asset naming**: the tarball is
  `medley-full-linux-x86_64-<rel>.tgz` where `<rel>` already starts with
  `medley-…` — the filename does NOT repeat the prefix. A guessed URL 404s.

Host-native X-client route facts for the `lisa` wave (LisaEm): same shape —
`--like amix --tuple …`, launcher = amix's minus the warp block, fixture
`SH_X11TEST_MOTION=xtest SH_X11TEST_ABS=1 SH_X11TEST_BUTTONS=xtest
SH_X11TEST_KEYS=1`, `xvfb_alloc --display <slot-100>`, reap by
`/proc/<pid>/exe` under the asset dir, `mame.pid` as the pidfile name.

## Landing

`scripts/dev/station-land.sh medley` (no `--golden`: the "golden" is the
release sysout in `assets/medley`), run detached with its log polled
(`/data/vms/sandbox/medley/land.log`). First attempt stopped at step 4: the
tileWiring visitor-copy test rejected the word "emulated" in the blurb;
reworded, retested, relaunched. Second attempt: window taken at once (no
queue), main fast-forwarded to `8a6450aa` (merge of origin/main `f757e84c`),
gate green (eslint+knip, vitest, shfmt+shellcheck on 3 files, size budget,
generated drift, box state), `box-deploy --apply`, smoke rig withdrawn,
`station-up` (`re-emitted with --pin-machine`, unit active, LISTENING udp/54191,
5 runtime docs carry `medley`, `POST /restore/medley -> 200`), 11 claims
re-homed, SPA built with the Instana key and deployed, `sculpt`'s
dark-launch overlay re-applied, window released. `== LANDED medley` at
18:34 UTC.

## Proofs (rule 9)

- `smoke/f2.png`, `f30.png` — boot ≤2 s, stable scene.
- `smoke/typed.png` — keyboard.
- `smoke/p1.png`, `p2.png` + xdotool readback — pointer two targets.
- Launcher relaunch proof on a rig on `:91` (`rig/launch1.png`,
  `dirty.png`, `launch2.png`): launch1 == launch2 pixel-identical, dirty
  differs at the Exec prompt; second launch reaped the first through
  `/proc/<pid>/exe`; ~6 s wall.
- Landed station: `medley-up.png` / `medley-landed.png` (labctl shot) show
  the Exec with the time-of-day greeting.
- Live station keys + pointer under a wake lease (`live/typed2.png`):
  `(+ 40 2)` → `42` in the Exec; `xdotool getmouselocation` 900,700 exact.
- Live `labctl reset medley`: new maiko pid (3823782 → 3855955), pristine
  Exec back; the only pixels that differ from the pre-reset frame are the
  greet's greeting ("Good evening." → "Hi.") and the status-bar clock.
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

From file mtimes and git timestamps (the fork's transcript is the
coordinator's, so `session-timeline.py` measures the parent, not this wave).
Clock zero = `wave.sh alloc` (18:13:39 UTC); the coordinator's fork spawn was
~2 min earlier.

| Milestone | Wall clock (UTC) | Minute |
|---|---|---|
| `wave.sh alloc` / `.wave.env` | 18:13:39 | 0 |
| smoke frame: Exec up on `:91` (`f2.png`) | 18:15:38 | 2 |
| keyboard + two-target pointer proofs (`typed.png`, `p2.png`) | 18:21:57 | 8 |
| `/os/medley` published (smoke rig `signaling.json`) | 18:23:08 | 9.5 |
| `/os/medley` interactive (x11test flags) | 18:24 | 11 |
| ledger + everything committed (`869f3d80`) | 18:31:36 | 18 |
| main pushed (`8a6450aa`) | 18:32:35 | 19 |
| `station-up` shot / `== LANDED` | 18:34:10 / 18:34:18 | 21 |
| live reset + wake-lease proofs done | 18:38 | 25 |

## Teardown

- Smoke rig: withdrawn by `station-land` (`smoke-rig.sh --down`); its maiko,
  Xvfb and the placeholder-QMP python were killed by pidfile beforehand.
- Rig dir `/data/vms/sandbox/medley/rig` removed.
- No stream sandboxes were created (single-session wave).
- Check: a `/proc/*/exe` sweep for `assets/medley` or `sandbox/medley` finds
  exactly one process, the station's maiko (pid 3855955 after the reset);
  `kh-claim ls` shows every medley claim held by session `medley`, the
  station session.
- Media staged at `/data/vms/sandbox/medley/media/` (tarball + unpacked copy,
  185 MB + 400 MB) and the build dir `build/` are kept as the wave's
  provenance; delete with the sandbox.
