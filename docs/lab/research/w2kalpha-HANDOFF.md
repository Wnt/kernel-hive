# w2kalpha — consolidated session handoff (context-compaction entry point)

**Written 2026-08-11.** Single entry point for the w2kalpha (Windows 2000 RC2
for Alpha, es40 emulator) work. Detailed docs, read in this order:

- [`w2kalpha-gallery-integration.md`](w2kalpha-gallery-integration.md) — the
  gallery tile: what's built/verified, exact remaining registration steps.
- [`alpha-nt-optimization-handoff.md`](alpha-nt-optimization-handoff.md) — the
  emulator-optimization working handoff (queue, bench harness, epochs).
- [`alpha-nt-add.md`](alpha-nt-add.md) §10 — the optimization results log
  (A/B numbers, the 24h-mission 2× record).
- [`es40-tuning-research.md`](es40-tuning-research.md) — GitHub/web tuning
  research digest (ali_usb, idle_nap, savestate facts, de-bloat list).

## Two headline results, both PROVEN

1. **2× desktop-interaction throughput.** Computer Management launch (MMC +
   snap-ins: disk IO + CPU) 24.4 s → 10.3 s = **2.37×** (n=8, cold boot per
   iteration, framebuffer-timed). Fork commit `0e22e9f`.
2. **X11 wrapper removed.** es40 runs fully headless (no X server, no window,
   `SDL_VIDEODRIVER=dummy`), publishing its framebuffer to shared memory and
   taking input over a socket — the MAME-IRIX capture shape. Fork commits
   `66c5b2f` (shm) + `849039a`/`6986997` (input).

Plus: guest raised to **1280×1024**; the dev rig is **retired** (its working
disk was corrupted STOP 0x7B by restore-onto-mutated-disk during testing —
the golden is a separate clean snapshot, unaffected).

## Where everything lives

- **kernel-hive repo** `/home/wnt/kernel-hive`, pushed `main` (`1139acb`).
- **es40 fork** `github.com/Wnt/es40`, local clone `~/es40`, pushed `main`
  (`6986997`). Push flow (box can't auth to github): `git push origin
  main:refs/heads/sync`; on box `cd /data/vms/soltest/ALPHA-nt/es40src &&
  git merge --ff-only sync && git branch -d sync`.
- **Box** `ssh lab '<cmd>'` (root). es40 src/build:
  `/data/vms/soltest/ALPHA-nt/es40src` (`cd src && make -j6`, ccache).
- **Tile (production)**: assets `/data/vms/streamhost/assets/w2kalpha/`
  (es40 `fde680f2`, clean 1280×1024 `nt.img`, `rom/`, `es40.cfg`, `w2k.iso`,
  `root/` lib tree); runtime `/data/vms/streamhost/tiles/w2kalpha/`
  (`w2kalpha-runtime.sh`, `tile.env` — SH_CAPTURE=shm,
  SH_INPUT_BACKEND=mamesock, SH_PORT=54199, SH_RESET_MODE=relaunch,
  `pumps.py`).
- **Golden lineage**: `/data/vms/soltest/ALPHA-nt/milestones/m5-1280/`
  {nt.img, autosave.axp, flash.rom, es40.cfg}. The staged tile asset nt.img
  is a copy of m5-1280.
- **Harness** (scratchpad + box `uibench/`): `uibench.sh` (CM-launch metric,
  crop-RMSE detect), `shmread.py` (IFB1 shm → PNG), `ctltest.py` (mamectl
  client, has TYPE). Xvfb `:93` is uibench-private.

## Fork commits (all pushed, all verified)

| commit | what | verified |
|---|---|---|
| `6a525d1` | media-mailbox lock-free poll | −24.7% boot |
| (configure) | `-O3` adopted | +2.4% kernel |
| `0e22e9f` | JIT: deliverability-gated int kicks + chain-granular IRQ drain + **compile-on-2nd-encounter** (`m_cold_seen`) | **2.37×** CM launch |
| `ab75e70`,`d73e4dc` | savestate fixed + menu-5 save-and-exit + `ES40_RESTORE` | restore→desktop |
| `66c5b2f` | shm framebuffer export (`src/gui/shmfb.h`, `ES40_SHM_PATH`) | pixel-exact, X-free |
| `849039a`,`6986997` | mamectl/1 input socket (`src/gui/ctlsock.h`, `ES40_CTL_SOCK`) | keyboard opens Start menu |

## Tile: DONE + VERIFIED

The tile **runtime** works end to end: `w2kalpha-runtime.sh` cold-boots es40
headless from the golden (reflink copy per launch) to a **1280×1024 desktop
published on shm in ~80 s**, mamectl socket accepts input, keyboard reaches
the guest. Reset mode = **relaunch (cold boot)** — a restored guest paints
new dialogs only partially (post-restore fragility); cold boot renders
everything.

## Remaining work — status and benefit

| item | status | benefit | notes |
|---|---|---|---|
| **Golden guest-polish + re-capture** | **needed for a clean live tile** (deferred by operator 2026-08-11; the recovery page showed on 3/3 cold boots that day — every visitor/reset sees it until this lands) | removes the flaky "Active Desktop Recovery"; 1:1 mouse makes the open-loop pointer pixel-exact. The keyboard-only fix sequence was PROVEN on a throwaway copy over the socket (Win+R `desk.cpl` → Ctrl+Tab×3 → Space → Enter → **No** to the "wallpaper needs Active Desktop" prompt — the golden's wallpaper is web-rendered, switch it to None/BMP or the prompt recurs); see docs/guests/w2kalpha.md | On a cold golden, via socket keyboard (dialogs render on cold boot): desk.cpl → Web tab → uncheck "Show Web Content"; main.cpl → Motion → Acceleration None (or `HKCU\Control Panel\Mouse` MouseSpeed=0, Threshold1/2=0). Clean shutdown, re-capture `nt.img`, restage. Then verify: MOVEA lands pixel-exact, DOWN1/UP1 selects an icon. Do this in a scratch copy, not the production asset. |
| **Register the tile (task #9)** | **DONE 2026-08-11 — LIVE** | the actual live exhibit | Registered as the 60th production tile: `registry/tiles/w2kalpha.json` (slot 140, udp 54140), tracked `streamhost/tiles/w2kalpha/{x11-runtime.sh,pumps.py,tile.env.fixture}` conforming to the ensure/stop-tile-x11 contract (es40 pid in `mame.pid`), poster + hero, `docs/guests/w2kalpha.md`, SPA scene/keyboard/identity wiring. Deployed, `streamhost@w2kalpha` active; verified: ticket accepted, 1280×1024 desktop on shm, reset-tile.sh relaunch → fresh boot. Repo `main` 97ce80b+4d79d21. NOTE: es40's ctlsock is **single-client** — while the daemon is attached, direct `ctltest.py`/labctl socket probes time out (stop the unit first, or add multi-client accept to the fork). |
| **post-restore-under-load wedge** | open bug | unlocks instant-resume (<5 s) reset instead of ~80 s cold boot — the operator's original vision | An instant-resumed guest wedges under load / partial-paints dialogs. Prime suspect: wall-clock RPCC + interval-timer baselines (`cc_last_sync`, `next_timer_fire`, `tick_last_fire` — std::chrono members OUTSIDE `state`) are not re-anchored to the restored `state.cc` in `CAlphaCPU::RestoreState`, so the guest sees a clock discontinuity. Candidate fix: re-anchor them on restore. |
| **guest telnet channel** | not started | text-driven load scenarios (operator-requested); faster than screenshot/keystroke driving | W2K built-in Telnet Server over the emulated `dec21143`. Guest networking first. |
| **ali_usb removal** | not started | lowers guest idle CPU | Remove `ali_usb` from es40.cfg — W2K's System process pegs a core polling the emulated USB (upstream es40 issues #114/#169). Device-set change → do BEFORE any golden re-bake; then verify idle CPU drop. |
| **guest de-bloat** | not started | marginal idle/interactive gain, faster boot | Disable Indexing Service, Task Scheduler, transition effects, screensaver; keep pagefile. See `es40-tuning-research.md`. Fold into the golden-polish pass. |
| **idle_nap (WTINT)** | optional | ~idle CPU only | Upstream `cpuN.idle_nap`; unverified whether W2K's HAL issues WTINT. Operator declared idle-sleep a **non-goal** (tile pauses when unwatched) — low priority. |
| **LTO / PGO final packaging** | measured | PGO +10%, LTO null | Apply PGO as a final rebuild step, not the dev loop. es40.O2/O3/pgo/lto control binaries preserved on the box. |

## Key gotchas (do not relearn)

- es40 **blocks on startup until BOTH serial ports have a client** — always
  launch `pumps.py` alongside es40.
- The fast-flag commit added a **virtual to `CDisk`** → clean-rebuild across
  it (stale objects are vtable-broken).
- **Kill only** via `clone-guard kill-pidfile` or a verified `/proc/<pid>/exe`
  match — never `pkill -f` (matches your own ssh).
- **Framebuffer is the only proof** a guest reacted — verify via shm/
  screenshot, never logs.
- Bench numbers are **epoch-bound** (host load + turbo); only compare within
  an epoch, and run A/B arms as concurrent pairs.
- A **forked session** ("Implement Alpha Windows emulator optimizations ⑂…")
  was spawned to explain remaining-task status; it's read-only/idle and does
  not see this session — coordinate via ListAgents/SendMessage if reviving it.
