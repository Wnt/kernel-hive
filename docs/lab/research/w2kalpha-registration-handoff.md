# w2kalpha registration session — compact handover (2026-08-11)

**What this session did: took the verified-but-unregistered w2kalpha launcher
and made it the 60th production exhibit — registered, deployed, LIVE, all
pushed.** Operator directive mid-session: skip the checkpoint-polish work (Active
Desktop / 1:1 mouse) and go straight to registration. Entry point for the
whole w2kalpha effort remains [`w2kalpha-HANDOFF.md`](w2kalpha-HANDOFF.md);
the canonical station doc is now [`docs/guests/w2kalpha.md`](../../guests/w2kalpha.md).

## End state (all verified, framebuffer-proven)

- `streamhost@w2kalpha` **active** on labhost — the only running station in the
  otherwise-paused fleet. Slot **140**, udp **54140** (in relay range
  54080–54200). `check-stream-tickets.py`: `ok w2kalpha accepts its ticket`.
- Daemon maps the 1280×1024 shm framebuffer and holds the ctlsock input
  connection. `labctl gen`/`ls` know the station.
- **Reset proven**: `serve/reset-tile.sh w2kalpha` → OK → service restart →
  fresh reflink of the checkpoint → desktop (~80 s). This is the UI button path.
- UI bundle + the THREE runtime documents deployed (`serve/tiles.json`,
  `webroot/gallery-manifest.json`, `serve/golden-manifest.json`).
- Repo `main` pushed: `97ce80b` (registration, 23 files), `4d79d21`
  (tiles.json harvest), `41a1bd0` (doc updates). Box checkout fast-forwarded.
- **NOT yet verified: a real browser session** (input via gallery → daemon →
  guest). Headless-provable parts all pass; the click-through is the
  operator's (house rule: hand over the URL, don't drive a browser).

## What was created (repo)

- `registry/stations/w2kalpha.json` — modelled on irix (x11/shm/mamesock),
  archetype `putty-lcd`, era 1999, accent DEC maroon `#862633`, orders:
  sig 57 / man 55 / bind 62 / mus 55 / gold 55 / bring 62 / group 7 (fleet
  maxima +1; recent waves append at the tail). `reset.keyboard=PASS`,
  `reset.mouse=UNVERIFIED` (honest — see warts).
- `streamhost/stations/w2kalpha/{x11-runtime.sh,pumps.py,station.env.fixture}` —
  launcher ports the proven manual launcher to the **shared x11-runtime
  contract**: es40's pid goes in `mame.pid` (ensure-station-x11.sh liveness =
  pid alive AND shm non-empty; stop-station-x11.sh kills the same names),
  kill-by-pidfile, per-launch `work/` + reflink of the checkpoint. pumps.py now
  self-exits on ANY serial-socket error. Fixture keeps
  `SH_IDLE_PAUSE_SECS=0` deliberately (es40 anchors guest RPCC to wall
  clock; SIGSTOP pausing = clock-discontinuity wedge risk).
- `registry/posters/w2kalpha.md` + `spa/public/posters/w2kalpha/desktop.webp`
  (validator REQUIRES both for any enabled production station). Hero = live
  capture of System Properties: 5.00.2128, DEC-221264, Clipper/Tsunami,
  512 MB, "Registered to: Kernel Hive".
- `docs/guests/w2kalpha.md` — media, device set, checkpoint lineage, launcher
  contract, input verbs, the proven polish sequence, rollback.
- UI hand-managed wiring: `keyboardProfiles.ts` (`w2kalpha: 'windows'`),
  `machines.ts` (`towerD|crtE` — a pair nothing else holds; keyboardH/
  paramMouseG), `machineIdentity.ts` (badge `ALPHASERVER ES40`).
- Emitter + generator now write `SH_X11_CMD_FILE=${TILE}_cmd` instead of a
  hardcoded `irix_cmd` (byte-identical for irix).
- `AGENTS.md` count → 62 entries / 60 production.

## Machinery knowledge earned this session (generalizes beyond w2kalpha)

- **`stations-registry.py new` scaffold rolls back** if the entry is incomplete
  (its own template lacks `stream.pointer`) — author the JSON by hand from
  irix/nt4 and let `validate` drive the TODO list.
- **Enabled production stations fail validation without a poster + hero**
  (`registry/posters/<id>.md`, `spa/public/posters/<id>/desktop.webp`).
- **Museum copy is lint-gated**: vitest `RIG_WORDS` rejects
  MAME/QEMU/emulat*/framebuffer/… in `lineage`/`blurb`/`arch`. Write the
  placard as the real machine.
- **The pre-push gate runs verify-box-sync** — deployment is a PREREQUISITE
  of pushing a mirrored-file change. Reconcile with
  `scripts/dev/box-sync-push.sh --all-drift --apply` (repo→labhost rows) and
  `scripts/dev/harvest.sh` (labhost→rows like the live tiles.json — refuses to
  run on main; use a review branch, merge --ff-only back).
- **Single-station emit on labhost** (no full-sweep risk): ship the kit files to
  `/data/vms/streamhost/build/streamhost/`, then run
  `scripts/streamhost-station.sh --tile <t> … --host-ip "$(sed -n
  's/^SH_HOST_IP=//p' /data/vms/streamhost/stations/irix/station.env)"` — the kit
  has no `registry/local.env`, and `--host-ip` beats the placeholder.
- **A new station needs its versioned daemon dir**:
  `/usr/local/lib/streamhost/stations/<t>/{current,previous}` symlinks (copy
  irix's targets; the fleet is per-station canaried, not auto-promoted).
- **`serve-https-spa.sh deploy`** ships bundle + serving plane + all three
  runtime manifests in one go; `manifests` alone for registry-only changes.

## Warts + gotchas (the next session's landmines)

1. **Active Desktop Recovery shows on EVERY cold boot** (3/3 today) — and
   reset=relaunch means every visitor/reset sees it. The keyboard-only fix
   was proven end-to-end on a throwaway copy: Win+R `desk.cpl` → Ctrl+Tab×3
   (Web tab, checkbox already focused) → Space → Enter → **No** to the
   "wallpaper needs Active Desktop" prompt (the checkpoint's wallpaper is
   web-rendered — the polish pass must also set wallpaper None/BMP or the
   prompt recurs). Then mouse accel → None, clean shutdown, re-capture
   `nt.img`, restage, flip `reset.mouse` after a MOVEA/DOWN1 proof.
2. **es40's ctlsock is single-client.** With the daemon attached, a second
   client's connect() queues forever (HELLO timeout). Consequence: direct
   `ctltest.py`/labctl-style socket driving requires `systemctl stop
   streamhost@w2kalpha` first — or add multi-client accept to the fork
   (small, worthwhile; irix's MAME module supports it and its watchdog
   probes depend on that pattern).
3. **Open-loop pointer is unusable until the checkpoint is 1:1**: a MOVEA to
   (522,141) pinned the cursor to the top-left corner (Windows accel
   amplifies the synthesized deltas). Keyboard is the drive channel.
   Key names are Bochs-style from `ctlsock.h field_to_bxkey`: `Left Win`,
   `Left Ctrl`, `Cursor Up`, `Enter`, `Space`, `Tab`, `F1`… Tools:
   `/data/vms/sandbox/ALPHA-nt/uibench/{ctltest.py,shmread.py}`.
4. es40 serial ports **21964/21965** are the production station's claim (listen
   bind in `assets/w2kalpha/es40.cfg`) — scratch clones must renumber.
5. The station dir emit leaves `SH_INPUT_BACKEND` duplicated in station.env (emit
   + fixture) — harmless (last wins, same value), same as irix.

## Remaining work queue (priority order, from the operator's framing)

1. **Checkpoint polish + re-capture** (the wart-remover; sequence proven, ~1 h).
2. **ctlsock multi-client** (unblocks labctl/watchdog-style probes while live).
3. Post-restore RPCC re-anchor → instant-resume reset (<5 s vs 80 s) — the
   operator's original vision; prime suspect documented in HANDOFF §bug.
4. Guest telnet channel (needs emulated NIC), de-bloat, PGO final rebuild.
5. Optional polish: boot video (`scripts/coldboot/`), demoProgram/type-in.

## Fleet/labhost state left behind

w2kalpha active (intentional — it IS the deliverable); everything else
inactive as found. Hero-capture es40 killed by pidfile (exe-verified); old
hand-made `w2kalpha-runtime.sh`/`station.env`/pidfiles replaced by the emitted
set; labhost `/tmp` scratch removed; `.presync-*` backups left beside the synced
registry mirrors (delete when satisfied); nothing created under
`/data/vms/sandbox` (only read the existing uibench tools).
