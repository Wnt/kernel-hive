# Kernel Hive lab — access map & operating rules

**This file is the canonical brief for every coding agent working on this repo**
— Claude Code, Google Jules, a human reading over their shoulder.
`CLAUDE.md` is a one-line pointer here; keep the content in this file so no
agent gets a stale copy.

Single-box Proxmox home-lab ("living computer museum"): the canonical registry
currently derives **39 lineup entries: 37 production streamhost tiles and 2
showcase posters** (`python3 scripts/tiles-registry.py count`).
streamed by the Rust `streamhost` daemon to a React SPA. Repo:
https://github.com/Wnt/kernel-hive (private; this dir is the git root).

## Placeholder values — read this before trusting an address in these docs

Every IP, hostname and domain in this repo's docs and committed config is a
**scrubbed placeholder**, not the operator's real value: `192.0.2.10` /
`192.0.2.11` (RFC 5737 TEST-NET-1, the box + CT950), `198.51.100.x`
(TEST-NET-2, a separate VLAN), `203.0.113.x` (TEST-NET-3, the forwarder VPS),
`labhost`/`labhost.lan`, `example.com`/`gallery.example.com`/
`tunnel.example.com`, MAC `02:00:00:00:00:01`, disk serial
`EXAMPLE0000000000`. Do not `ssh`/`curl` a literal placeholder expecting it to
resolve, and do not "fix" one — it is not wrong, it is not yours.

The real values for an actual deployment live **only** in gitignored,
operator-supplied files, never in the repo: `registry/local.env` (template at
`registry/local.env.example`) supplies `SH_HOST_IP`, sourced by
`streamhost/scripts/streamhost-tile.sh` at tile.env emit time unless
`--host-ip`/`$SH_HOST_IP` overrides it; SSH keys, PKI material, API tokens
(`uptoken`, `unifitoken`) and `spa/src/data/credentials.ts` are the other
gitignored operator-local categories (see `.gitignore`). An unchanged
placeholder builds and boots but is unreachable — tiles advertise an
unroutable address in `signaling.json`. Never commit real addresses,
hostnames, MACs, serials or domains back into the repo.

## Reaching the lab box

- `ssh lab` — **the one door**, from a LAN workstation and from a cloud agent
  VM alike. On the LAN it is an alias in `~/.ssh/config` → `root@192.0.2.10`
  (`labhost`, FQDN `labhost.lan`), key `~/.ssh/lab_key`, ControlPersist
  multiplexing on. Use this, not raw IPs.
- **Running in a cloud VM (Google Jules, Claude cloud sessions)?** Same
  `ssh lab`, different plumbing: it resolves to a public TCP port on the
  forwarder VPS that the box dials OUT to, so no port is open on the home WAN.
  `scripts/cloud-agents/jules-setup.sh` wires it up from the `LAB_SSH_*`
  environment variables; the full design, the env-var list, and how to revoke
  access live in [`docs/lab/CLOUD-AGENTS.md`](docs/lab/CLOUD-AGENTS.md). If
  `ssh lab` fails, read that doc before working around it — there is no second
  route in, and the tiles cannot be verified without one.
- SPA: `https://192.0.2.10:8443` (scripts/serve/osgallery-https-server.py;
  restart via `scripts/serve/restart-https.sh` on the box). That address is
  LAN-only; from a cloud VM reach it through the box
  (`ssh lab 'curl -sk https://127.0.0.1:8443/…'`) or an `ssh -L` forward.
- **Public gallery**: the same server also runs a session-gated listener on
  loopback `:8081`, published at `https://gallery.example.com` through the
  forwarder edge (passkeys; UDP relay over WireGuard for the QUIC video). The
  LAN origin above is unchanged and still open — see
  [`docs/PUBLIC-GALLERY.md`](docs/PUBLIC-GALLERY.md). **Consequence for tile
  work:** every tile now runs with `SH_SESSION_KEY`, so a WebTransport session
  must present a signed ticket. Use the `path` from `/signal/<tile>.json`
  verbatim — a hardcoded `/wt` is refused (`SESSION_REJECTED` in the journal).

## The machines, and how you authenticate to each

Everything in the lab hangs off one physical host. There is no second entry
point: you reach the host, and from the host you reach everything else.

| Machine | What it is | How you get a shell / run a command |
|---|---|---|
| **`labhost`** — 192.0.2.10, the box | Proxmox VE host. Owns the tiles, the streamhost daemon, the HTTPS SPA origin, `/data`, and every experiment dir. | `ssh lab '<cmd>'` as root. This is the only door — from the LAN and from a cloud agent VM alike. |
| **Tiles** (~30 guests) | The museum exhibits: raw QEMU/MAME/emulator processes under `streamhost@<tile>`, **not** Proxmox VMs — they never appear in `qm list`. | `ssh lab 'labctl exec <tile> "<cmd>"'` for real captured stdout + exit code; `labctl sh` (blind console), `labctl shot` (framebuffer), `labctl type/key`. Per-tile transport (warpd / ssh / serial bridge) is in the `tiles.json` matrix — `labctl ls` prints it. |
| **CT 950 `osgallery-dev`** — 192.0.2.11 | The LAN dev workstation container (node/npm, Playwright, the shared VNC headed browser for e2e). Has **no `/data` mount** — host-side checks must run on the host. | `ssh lab 'pct exec 950 -- <cmd>'`. |
| **Other guests/containers on the box** | Not the gallery. Unrelated projects share this hardware. **Leave them alone.** | `pct`/`qm` from the box if you ever genuinely need to — you should not. |
| **`vm-control`** — `tunnel.example.com` | The small public VPS running the forwarder that publishes the cloud-agent SSH port. Infrastructure, not a work target. | Not needed for repo work; see `docs/lab/CLOUD-AGENTS.md`. |

`ssh lab` is a plain SSH command channel, so it behaves exactly as it does for
any other agent: **stdout and stderr stay separate, and the guest's exit code is
your exit code.** Complex one-liners work verbatim — quoting, pipelines,
`nsenter` into a netns, heredocs, multi-megabyte output. E.g.

```bash
ssh lab 'cd /data/vms/soltest/criu-slirp-8b2f/irix &&
  nsenter --net=/run/netns/cs8b2firix python3 gtel.py 172.31.20.2 root "uname -a"'
```

`labctl exec` propagates the *guest's* exit code the same way, so a failing
command inside a tile fails your command too.

Before assuming a tile is broken, check whether it is simply **stopped**:
`ssh lab 'labctl ls'`. The fleet is routinely quiesced during measurement
campaigns, and `ssh lab 'systemctl start streamhost@<tile>'` during someone
else's timing run corrupts their numbers — check for in-flight work
(`ps -eo pcpu,comm --sort=-pcpu | head`) before starting anything.

## Tiles (guest VMs)

- Live tiles: `/data/vms/streamhost/tiles/<tile>/` — each has
  `qemu-streamhost.sh` (launcher, documents the exact device set), `qmp.sock`,
  `tile.env`, golden qcow2 with an internal `golden` snapshot
  (`loadvm golden` = reset; `savevm golden` = re-bake; device set must match).
- Daemon: one `streamhost@<tile>` systemd service per tile; source in
  `streamhost/`, built ON the box with cargo. The production-roster manifest is
  generated from `registry/tiles/`; derive its count with
  `python3 scripts/tiles-registry.py count`. Emit
  invocations: `streamhost/tiles-manifest.sh`; ordered boot:
  `streamhost/bring-up-all.sh`.

### Driving a guest (in order of preference)

**CT950 has no `/data` mount.** Host-side checks such as `check-assets.sh` must
run on the host over `ssh lab`, not inside CT950.

0. **`labctl` — the unified box CLI (start here).** Source of truth
   `scripts/labctl` == box `/usr/local/bin/labctl` (keep byte-identical). Only
   ever touches tiles in the capability matrix `/data/vms/streamhost/tiles.json`
   (per-tile: pointer_mode, warpd/ssh/exec ports, `exec_kind`, golden, notes;
   regenerate with `labctl gen` after any launcher/tile.env change). Run all via
   `ssh lab '<cmd>'`:
   - `labctl ls` — matrix + live service state (EXEC column shows the port).
   - `labctl exec <tile> "<cmd>"` — **REAL captured stdout + exit code.** Wired
     today for: `solariscde` (warpd `E` verb → `/root/gexec.py 57790`), the
     ssh tiles `alpine`/`tinycore`/`haiku` (gallery key, users root/tc/user on
     ports 5881/5882/5807), and the bridge tiles c64/atarist/apple2/amiga
     (bridge key, root on ports 5814/5816/5817/5818). e.g.
     `labctl exec solariscde "uname -a"` → `SunOS…`, exit 0; failing cmds
     propagate the guest exit code. `irix` is declared too (`exec_kind`
     `serial_e`, no port): irixser/2 over MAME `-ioc2:rs232a pty` to a Perl
     agent baked into the `irix65-apps-v7.chd` golden, host client
     `/root/irixexec.py`; it needs MAME running, so with the tile stopped it
     says so and exits 125. Other tiles error (exit 2) with
     alternatives — no exec channel yet. Bridge tiles run in permanent 3GiB
     qcap scopes (relaunch: systemd-run --scope -p MemoryMax=3G); the daemon's
     SH_QEMU_RSS_GUARD_MB (default +2G growth) bounds display backlog at the
     source, the cap is the outer net. All four live (shm/backlog fixed 07-12).
   - `labctl sh <tile> "<cmd>"` — BLIND console line (types + Enter, NO capture).
   - `labctl shot <tile> [out.png]` — screendump → PNG (default `/tmp/<tile>.png`).
   - `labctl type/key <tile> …` — send text / key chords (qcodes).
   - `labctl reset <tile>` — `loadvm golden` (refuses tiles without a golden
     snapshot: serenityos/toaruos/sailfishos). `labctl gen` — rebuild the matrix.
1. **In-guest agent (warpd family)** — pointer + exec over a hostfwd, under the
   `labctl` layer. Solaris: `127.0.0.1:57790` → guest `:7777`
   (`/opt/warpd/warpd.py`, protocol `M/P/R/B/C/D/U/W` pointer + `E <cmd>` exec;
   host client `/root/gexec.py <port> <cmd>`; see
   `streamhost/guest-agents/solaris/README.md`). Warpd agents are BAKED + LIVE
   on six tiles: solariscde, ninefront (:57793), win95 (:57791), and
   win311/os2warp/templeos over serial (sources in `streamhost/guest-agents/`).
2. **QMP console driver** — `/root/cdrv.py <qmp.sock>` on the box (what
   `labctl sh/type/key/shot` call): `sh "<cmd>"` (types a shell line via
   deterministic send-key), `type`, `key <qcodes>`, `abs x y`, `click x y`,
   `dump /tmp/x.ppm`. QMP send-key types correctly (uppercase/symbols) where the
   browser path mangles them.
3. **Screendump = the output channel** for GUI/no-network guests:
   `labctl shot` (or `cdrv dump` → PPM→PNG) → scp → Read. Install/automation
   agents MUST verify via real framebuffer screenshots, never disk/log inference.
4. **SLIRP tricks** — guest reaches host at `10.0.2.2`; serve files from the
   box with a one-shot python http.server and fetch in-guest. Start server +
   guest fetch in ONE atomic ssh command (backgrounded servers die between
   sessions). Solaris NIC is `e1000g1` (10.0.2.15/24). Adding a hostfwd to the
   EXISTING `-netdev user` is device-set-safe (loadvm golden still matches);
   adding any `-device` is NOT — forbidden without a full golden re-bake.

### Clones / experiments

- NEVER experiment on live tiles. Clone under `/data/vms/soltest/`:
  `launch-clone.sh <N>` (Solaris), or copy the tile launcher + a copy of its
  golden qcow2, swap qmp.sock/pidfile, keep the SAME device set (loadvm golden
  requires exact device match), add your own hostfwd port.
- Namespace everything (unique dirs, VMIDs, sockets, ports) for concurrent
  agents; kill VMs ONLY by their pidfile — never pkill by name.
- **HARD guard — `clone-guard`** (`scripts/lib/clone-guard.sh` == box
  `/usr/local/bin/clone-guard`, byte-identical): every clone kill/stop MUST go
  through it. `clone-guard kill-pidfile <pf>` kills ONLY a pidfile confined to
  `/data/vms/soltest/` whose PID is not a production QEMU; `check-launcher <sh>`
  refuses a launcher that embeds a live-tile path or the
  `${D:-/data/vms/streamhost/tiles/…}` default footgun that caused the
  solariscde breach; `assert-path/assert-unit/assert-vmid` fail-closed on any
  production target. `record-boot.sh`/`bootrec-lib.sh` route through it
  automatically. New clone helpers MUST `source /usr/local/bin/clone-guard` (or
  call the CLI). See `docs/lab/clone-guard.md`.

### Shared resources: claim atomically, fail loudly, tear down

Four separate incidents in one campaign were the same bug — **a shared global
that breaks silently under concurrency and still reports success**:

- an Xvfb rig picked `:77` by hand, its own server died ("already running"), the
  `[ -S /tmp/.X11-unix/X77 ]` check passed against a **sibling's** socket, and
  it drove and screenshotted someone else's display for ~12 minutes;
- another rig `rm -f`'d that socket first, evicting the rightful owner;
- an iptables chain with a shared name was flushed by a second rig, and the
  first one's taps came up with **no rules while printing "host-only"**;
- two rigs held the same host IP; a third lost the xtables lock and installed
  nothing while returning success.

So, for anything shared — displays, taps, host IPs, iptables chains, core pairs,
ports, VMIDs, dataset names:

1. **Claim it atomically, and make the claim itself the proof.** `xvfb-alloc`
   (`docs/lab/xvfb-alloc.md`) claims through the X server's own socket bind;
   `tapnet.sh claim` uses `mkdir`; `iptables -w 15` takes the xtables lock.
   Never check-then-create.
2. **Namespace it per rig.** Chain names, tap names, netns names, veth names and
   work dirs all carry the rig's unique tag, so two rigs cannot flush, delete or
   overwrite each other's state.
3. **Fail loudly instead of falling back.** "It exists" is not "it is mine". A
   resource you did not create is a non-zero exit, never a silent adoption.
4. **Assert quiescence before a measurement window** and record what you
   asserted — occupancy on your own core pair, no foreign emulator processes, no
   competing rigs. See `docs/lab/MEASUREMENT-METHODOLOGY.md`.

### Teardown is part of "done", and must be stated in the report

An agent that reports done while its clones are still running has not finished.
Ten orphaned clones once sat at 85% CPU for an hour, poisoning every sibling's
numbers; another was found still running after its agent reported success. A
`perf stat -- …` wrapper is a classic cause — the recorded `$!` is *perf*, not
the emulator, so killing it leaves the guest alive.

- Kill only via `clone-guard kill-pidfile`, and **verify afterwards** that
  nothing named after the run survived (resolve the real process, not the
  wrapper).
- Release every claim you took: displays, taps, chains, core pairs.
- The final report states teardown explicitly — what was released, and the check
  that proved it. "Done" without that line is not done.

## Debugging playbooks — reach for these BEFORE iterating blind

Each of these exists because a session burned hours re-deriving it. They are
listed here because a tool nobody can find is not a tool.

| Symptom | Read / run |
|---|---|
| **IN FLIGHT (2026-08-05)**: pen taps register as tiny drags on IRIX | [`docs/lab/PEN-TAP-PLAN.md`](docs/lab/PEN-TAP-PLAN.md) — agreed plan + the measurements behind it. Root cause: quantisation thresholds are in GUEST px while a hand wobbles in physical space (3.13 guest px per CSS px on IRIX) |
| Pen/touch input: what did the BROWSER actually see? | `ssh lab 'python3 /data/vms/streamhost/serve/pen-trace.py --since-min 15'` — the raw pointer stream, pushed from the tab every 2 s and decoded into gestures (no foreground tab, no eval round-trip) |
| Pointer, tap, drag or double-click "feels wrong" | [`docs/lab/INPUT-DEBUGGING.md`](docs/lab/INPUT-DEBUGGING.md) — which of the three code paths a press takes (a STYLUS is not the touch path), the three telemetry sources, the warpd button-guard, and `tests/e2e-live/pen-doubletap-probe.mjs` to reproduce without the hardware |
| A tile streams then "freezes", or refuses to connect | `ssh lab 'python3 /data/vms/streamhost/serve/check-stream-tickets.py'` — proves every tile accepts the ticket the gateway mints for it. Catches SPA-id vs `SH_TILE` divergence (`solaris`/`solariscde`, `aros`/`amigaos`) |
| Public gallery, passkeys, invites, device links | [`docs/PUBLIC-GALLERY.md`](docs/PUBLIC-GALLERY.md). **Never `rm auth-state.json`** — it is the account database and passkeys cannot be regenerated; `scripts/serve/reset-auth.sh` is the guarded path |
| Guest did or did not react | `labctl shot <tile>` — the framebuffer is the only proof. Never infer from logs |
| Adding a new OS tile — anywhere from sourcing media to the acceptance matrix | [`docs/lab/ADD-NEW-OS-PLAYBOOK.md`](docs/lab/ADD-NEW-OS-PLAYBOOK.md) — the end-to-end procedure, and the traps each step has already sprung (golden bake hygiene, emulator window vs captured root, the SPA scene files a registry entry does NOT generate) |
| Typed characters vanish, or arrive scrambled, on an old machine | Playbook [§5.1](docs/lab/ADD-NEW-OS-PLAYBOOK.md#51-keyboard-only-exhibits--pacing-layout-and-the-type-in-demo). An emulator samples input once per emulated FRAME, so the release→press GAP is what must survive: measured on mpf2, 0 ms → 0/16 keys land, 16 ms → 16/16. Set `SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS` from the frame period (2 frames shipped). `labctl type` bypasses that pacing and drops characters while printing "ok" — it is not a fair test |
| A fix appears not to have taken effect | The tile may run an OLD binary: streamhost deploys are per-tile canaries via `current` under `/usr/local/lib/streamhost/tiles/<tile>/` and the fleet is not promoted automatically. SPA edits need the bundle rsynced to `/data/vms/streamhost/serve/webroot/`; a launcher or X-geometry change needs the golden RE-BAKED |

**A tile's SPA id is not always its `SH_TILE`.** `tiles.json` is keyed by the
id the SPA uses; the daemon runs under its own. Anything that must agree with the
daemon reads the identity from the tile's `signaling.json`, never the endpoint
key.

**`pkill -f <pattern>` from `ssh lab` can kill your own session** — the remote
shell's command line contains the pattern, so it matches itself and the
connection dies with exit 144, which reads like a network fault. Kill by pidfile,
or resolve the PID first (`ss -lntpH "sport = :PORT"`). **The same self-match
ruins process SCANS**: a `for p in /proc/*/cmdline; do grep <pattern>` loop also
matches the shell running it — it once reported 9 stray processes when the true
answer was 0. Resolve each hit through `/proc/<pid>/exe` and check the binary.

## Hard guardrails

- riscos/windows11 are showcase-only SPA exhibits (their neko/RDP backends are
  gone; VM 900 was deleted — old protection removed 2026-07-08). During
  measurement-quiesce windows the only essential guests are CT950 (the Claude
  dev box) and the tile(s) under test — everything else may be stopped and
  restored.
- Integrate continuously: merge work to `main` early and **always `git push
  origin main`** after landing commits (keep `origin` in sync; don't sit on local
  commits). Never echo/log
  `~/Downloads/humanify-token`.
- Secrets are gitignored: `uptoken`, `unifitoken`, `docs/gallery-credentials.md`,
  `scripts/serve/pki/` (carry the matched `rootCA.key` + `rootCA.pem` pair for CA
  trust continuity), `spa/src/data/credentials.ts` — keep out of the repo.
- Always use the latest STABLE release of tools/ISOs/images.

## Building

- **Rust daemon**: edit `streamhost/streamhost/src/*` locally → rsync to box →
  `cargo build --release` there → install → restart affected
  `streamhost@<tile>` services. One-shot from the Mac:
  `scripts/dev/build-deploy.sh [tile…|--all|--changed-only]` (rsync + build +
  restart + ffmpeg-child smoke check; `--check` = cargo check only, `--no-restart`
  = build only, `-n` = dry-run). The release binary is SHARED by all registry
  production tiles, so
  bare `build-deploy.sh` restarts EVERY tile — pass an explicit low-traffic tile
  (e.g. `helenos`) when verifying.
- **Guest agents**: cross-toolchains live ON the box —
  `i686-w64-mingw32-gcc` (Win32/Win9x), OpenWatcom **1.9** (DOS/Win16/OS2;
  `/root/watcom`; V2's runtime crashes on Warp 4 GA), Solaris agents are Python
  2.6 in-guest.
- **SPA**: `spa/` (Vite/React); built bundle deployed to the box webroot
  (see `scripts/serve/`). Live-box Playwright e2e suite: `tests/e2e-live/`
  (needs the lab box; never run in CI).

## Code quality gate — green before done

**Every agent** (Jules sessions, Claude subagents) whose branch is
intended to merge to `main` MUST make the full CI quality gate green **before
reporting "done".** An agent that cannot get the gate green reports **BLOCKED**
(with the failing command + output), not done — red is not done, and "it's a
small change" is not an exemption. You owe the gate only for the language(s) your
branch touches, **plus** the two cross-cutting gates every branch owes. Canonical
commands (full reference: `docs/lab/AGENT-CI-EXIT-RULE.md`; enforced by
`.github/workflows/quality.yml` `static` job + the `rust`/`spa`/`tile-registry`
jobs):

- **TS/JS** — `cd spa && npx eslint . --max-warnings=0 && npx knip` (+ `npm run build`)
- **Rust** — `cd streamhost && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings` (+ `cargo test --workspace`)
- **Python** — `ruff check scripts && ruff format --check scripts`
- **Bash** — `shfmt -d $(git ls-files '*.sh') && shellcheck $(git ls-files '*.sh')`
- **file-size budget (all)** — `node scripts/check-file-size.mjs --strict`
  (per-dialect line caps; `size-exclusions.json` is a bidirectional ledger — a
  file that drops under its hard cap FAILS until its stale exclusion is deleted)
- **generated-file drift (all)** — `make tile-registry-check` (never hand-edit a
  generated file; edit the registry source + `make tile-registry-generate`)

Mirror it locally before pushing with `.claude/hooks/pre-push-gate.sh` (enable:
`ln -sf ../../.claude/hooks/pre-push-gate.sh .git/hooks/pre-push`). Strict on
hygiene/debt and file growth, pragmatic on style; Python-2.6 in-guest agents are
runtime-exempt from the modern budget.

## Docs to consult

- `docs/README.md` — index of the whole docs tree.
- **NVMe migration** — completed 2026-07-15; the Mac-session bootstrap is documented
  in `docs/lab/MIGRATION-MAC-RUNBOOK.md` (historical runbook), baseline
  `docs/history/migration-reference.md`.
- `docs/lab/MASTER-REPRODUCE.md` — full NVMe rebuild;
  `docs/lab/REMOTE-PROVISIONING-NOTES.md` — bare-metal gotchas;
  `scripts/build-guests/<os>.sh` — per-guest golden builders; per-guest
  notes in `docs/guests/<os>.md`.
- `streamhost/docs/` — daemon design, bridge protocol, latency/encoder
  notes, and the SH_* env-knob reference (CONFIG.md).
- `scripts/README.md` — index of ops tooling incl. box-sync pairs.
