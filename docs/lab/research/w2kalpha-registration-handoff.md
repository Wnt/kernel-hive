# w2kalpha registration session — compact handover (2026-08-11)

**What this session did: took the verified-but-unregistered w2kalpha runtime
and made it the 60th production exhibit — registered, deployed, LIVE, all
pushed.** Operator directive mid-session: skip the golden-polish work (Active
Desktop / 1:1 mouse) and go straight to registration. Entry point for the
whole w2kalpha effort remains [`w2kalpha-HANDOFF.md`](w2kalpha-HANDOFF.md);
the canonical tile doc is now [`docs/guests/w2kalpha.md`](../../guests/w2kalpha.md).

## End state (all verified, framebuffer-proven)

- `streamhost@w2kalpha` **active** on the box — the only running tile in the
  otherwise-quiesced fleet. Slot **140**, udp **54140** (in relay range
  54080–54200). `check-stream-tickets.py`: `ok w2kalpha accepts its ticket`.
- Daemon maps the 1280×1024 shm framebuffer and holds the ctlsock input
  connection. `labctl gen`/`ls` know the tile.
- **Reset proven**: `serve/reset-tile.sh w2kalpha` → OK → service restart →
  fresh reflink of the golden → desktop (~80 s). This is the SPA button path.
- SPA bundle + the THREE runtime documents deployed (`serve/tiles.json`,
  `webroot/gallery-manifest.json`, `serve/golden-manifest.json`).
- Repo `main` pushed: `97ce80b` (registration, 23 files), `4d79d21`
  (tiles.json harvest), `41a1bd0` (doc updates). Box checkout fast-forwarded.
- **NOT yet verified: a real browser session** (input via gallery → daemon →
  guest). Headless-provable parts all pass; the click-through is the
  operator's (house rule: hand over the URL, don't drive a browser).

## What was created (repo)

- `registry/tiles/w2kalpha.json` — modelled on irix (x11/shm/mamesock),
  archetype `putty-lcd`, era 1999, accent DEC maroon `#862633`, orders:
  sig 57 / man 55 / bind 62 / mus 55 / gold 55 / bring 62 / group 7 (fleet
  maxima +1; recent waves append at the tail). `reset.keyboard=PASS`,
  `reset.mouse=UNVERIFIED` (honest — see warts).
- `streamhost/tiles/w2kalpha/{x11-runtime.sh,pumps.py,tile.env.fixture}` —
  launcher ports the proven manual runtime to the **shared x11-runtime
  contract**: es40's pid goes in `mame.pid` (ensure-tile-x11.sh liveness =
  pid alive AND shm non-empty; stop-tile-x11.sh kills the same names),
  kill-by-pidfile, per-launch `work/` + reflink of the golden. pumps.py now
  self-exits on ANY serial-socket error. Fixture keeps
  `SH_IDLE_PAUSE_SECS=0` deliberately (es40 anchors guest RPCC to wall
  clock; SIGSTOP freezing = clock-discontinuity wedge risk).
- `registry/posters/w2kalpha.md` + `spa/public/posters/w2kalpha/desktop.webp`
  (validator REQUIRES both for any enabled production tile). Hero = live
  capture of System Properties: 5.00.2128, DEC-221264, Clipper/Tsunami,
  512 MB, "Registered to: Kernel Hive".
- `docs/guests/w2kalpha.md` — media, device set, golden lineage, runtime
  contract, input verbs, the proven polish sequence, rollback.
- SPA hand-managed wiring: `keyboardProfiles.ts` (`w2kalpha: 'windows'`),
  `machines.ts` (`towerD|crtE` — a pair nothing else holds; keyboardH/
  paramMouseG), `machineIdentity.ts` (badge `ALPHASERVER ES40`).
- Emitter + generator now write `SH_X11_CMD_FILE=${TILE}_cmd` instead of a
  hardcoded `irix_cmd` (byte-identical for irix).
- `AGENTS.md` count → 62 entries / 60 production.

## Machinery knowledge earned this session (generalizes beyond w2kalpha)

- **`tiles-registry.py new` scaffold rolls back** if the entry is incomplete
  (its own template lacks `stream.pointer`) — author the JSON by hand from
  irix/nt4 and let `validate` drive the TODO list.
- **Enabled production tiles fail validation without a poster + hero**
  (`registry/posters/<id>.md`, `spa/public/posters/<id>/desktop.webp`).
- **Museum copy is lint-gated**: vitest `RIG_WORDS` rejects
  MAME/QEMU/emulat*/framebuffer/… in `lineage`/`blurb`/`arch`. Write the
  placard as the real machine.
- **The pre-push gate runs verify-box-sync** — deployment is a PREREQUISITE
  of pushing a mirrored-file change. Reconcile with
  `scripts/dev/box-sync-push.sh --all-drift --apply` (repo→box rows) and
  `scripts/dev/harvest.sh` (box→rows like the live tiles.json — refuses to
  run on main; use a review branch, merge --ff-only back).
- **Single-tile emit on the box** (no full-sweep risk): ship the kit files to
  `/data/vms/streamhost/build/streamhost/`, then run
  `scripts/streamhost-tile.sh --tile <t> … --host-ip "$(sed -n
  's/^SH_HOST_IP=//p' /data/vms/streamhost/tiles/irix/tile.env)"` — the kit
  has no `registry/local.env`, and `--host-ip` beats the placeholder.
- **A new tile needs its versioned daemon dir**:
  `/usr/local/lib/streamhost/tiles/<t>/{current,previous}` symlinks (copy
  irix's targets; the fleet is per-tile canaried, not auto-promoted).
- **`serve-https-spa.sh deploy`** ships bundle + serving plane + all three
  runtime manifests in one go; `manifests` alone for registry-only changes.

## Warts + gotchas (the next session's landmines)

1. **Active Desktop Recovery shows on EVERY cold boot** (3/3 today) — and
   reset=relaunch means every visitor/reset sees it. The keyboard-only fix
   was proven end-to-end on a throwaway copy: Win+R `desk.cpl` → Ctrl+Tab×3
   (Web tab, checkbox already focused) → Space → Enter → **No** to the
   "wallpaper needs Active Desktop" prompt (the golden's wallpaper is
   web-rendered — the polish pass must also set wallpaper None/BMP or the
   prompt recurs). Then mouse accel → None, clean shutdown, re-capture
   `nt.img`, restage, flip `reset.mouse` after a MOVEA/DOWN1 proof.
2. **es40's ctlsock is single-client.** With the daemon attached, a second
   client's connect() queues forever (HELLO timeout). Consequence: direct
   `ctltest.py`/labctl-style socket driving requires `systemctl stop
   streamhost@w2kalpha` first — or add multi-client accept to the fork
   (small, worthwhile; irix's MAME module supports it and its watchdog
   probes depend on that pattern).
3. **Open-loop pointer is unusable until the golden is 1:1**: a MOVEA to
   (522,141) pinned the cursor to the top-left corner (Windows accel
   amplifies the synthesized deltas). Keyboard is the drive channel.
   Key names are Bochs-style from `ctlsock.h field_to_bxkey`: `Left Win`,
   `Left Ctrl`, `Cursor Up`, `Enter`, `Space`, `Tab`, `F1`… Tools:
   `/data/vms/soltest/ALPHA-nt/uibench/{ctltest.py,shmread.py}`.
4. es40 serial ports **21964/21965** are the production tile's claim (listen
   bind in `assets/w2kalpha/es40.cfg`) — scratch clones must renumber.
5. The tile dir emit leaves `SH_INPUT_BACKEND` duplicated in tile.env (emit
   + fixture) — harmless (last wins, same value), same as irix.

## Remaining work queue (priority order, from the operator's framing)

1. **Golden polish + re-capture** (the wart-remover; sequence proven, ~1 h).
2. **ctlsock multi-client** (unblocks labctl/watchdog-style probes while live).
3. Post-restore RPCC re-anchor → instant-resume reset (<5 s vs 80 s) — the
   operator's original vision; prime suspect documented in HANDOFF §bug.
4. Guest telnet channel (needs emulated NIC), de-bloat, PGO final rebuild.
5. Optional polish: boot video (`scripts/coldboot/`), demoProgram/type-in.

## Fleet/box state left behind

w2kalpha active (intentional — it IS the deliverable); everything else
inactive as found. Hero-capture es40 killed by pidfile (exe-verified); old
hand-made `w2kalpha-runtime.sh`/`tile.env`/pidfiles replaced by the emitted
set; box `/tmp` scratch removed; `.presync-*` backups left beside the synced
registry mirrors (delete when satisfied); nothing created under
`/data/vms/soltest` (only read the existing uibench tools).
