# mamectl (issue #45 Stage 1) — build orders for the build/validation phase

MOVEA ENGINE V2 (2026-08-04, patch md5 2586a68e3347e6b14918e4d391fdb894, dev
binary lab:/data/vms/soltest/movea-v2-build/sgi-v2 md5
ca6fbe85ec936e0665d37ed83a8f3969): the closed loop is replaced by dead-
reckoned open loop + settle-time delta verification (belief B fed by every
move_rel count, screen-clamped; reading consulted ONLY at settle,
MAME_CTL_SETTLE_WINDOWS [3] windows after the last count; shortfall
= issued - measured delta, > 2 px => adjust B and re-issue, capped 2
rounds/epoch then gaveup-accept; absolute re-anchor only when post-settle
|T - reading| <= 1 px; static target + nothing in flight => NEVER issues).
MAME_CTL_MOVEA_TRIES is now accepted-but-inert. STAT adds bel= and bias=.
Signature-neutral: proven against sgi-ctl2 under identical flags
(e4307541/3845 both) and reproduces the Stage-1 smoke values exactly.

SMOKE CONFIG CORRECTION: the 2236991a/3897 "PROM-only" smoke config is
`indy_4610 -rompath <assets/roms> -ioc2:rs232a pty -video none -sound none`
(DEFAULT gfx = xl24; the +52 entries over bare 3845 are the rs232a pty, NOT
a gfx difference). Bare default-gfx PROM-only = ed3a6488/3845; bare xl8 =
e4307541/3845. SDLMAME defaults cfg/nvram under /root/.mame when
-nvram_directory is not given — the smoke dirs' local nvram/ dirs are decoys.

Written by the module-writer subagent; BUILT AND SMOKE-TESTED 2026-08-04 by
the build subagent; ADVERSARIALLY REVIEWED + two Lua-parity fixes landed the
same day (patch now 2222 lines, md5 90f75dda3e1762cd0866e791db832c39; fixed
dev binary lab:/data/vms/soltest/mamectl-dev/sgi-ctl2 md5
893272bbe5343b722cbacb6f8ade2c3e, build log mamectl-build4.log — sgi-ctl is
the PRE-review binary, superseded):

Review fixes (both rebuilt, smoke-verified on smoke2/, and proven
signature-neutral — the pre-fix binary under the IDENTICAL flag set reports
the same sig/entries as the fixed one):

R1. KEY coalesce now matches Lua's `(kwant[name] or 0) == val`: a field
    never enqueued counts as RELEASED, so the session's first `KEY 0`
    coalesces ("OK coalesced", live-verified) instead of burning a KEY_GAP
    pacing slot on a no-op edge and skewing counters vs the Lua arm.
R2. on_frame now runs the Lua agent_tick order verbatim (esc -> probe ->
    clicks -> poll): before this, a file-parsed CLICK took its press edge
    one frame earlier than the Lua agent, and PROBE-vs-click set_button
    precedence within a frame was inverted.

NOTE the savestate signature depends on the MACHINE CONFIG too: smoke runs
with `-bios b10 -gio64_gfx xl24` (the production flag set) report
sig=ed3a6488 entries=3845, while the earlier PROM-only smoke/V4 skeleton
(default gfx) reported 2236991a/3897. Both are fine — compare signatures
only across runs with the same flag set; production's own signature lands
at the Stage-1 rebake regardless.

Build-phase fixes (both live in the regenerated
patch, `regen-patch.sh` in this dir rebuilds it byte-stably from a/ + b/):

1. `move_paced(..., ack_ref ack = ack_ref())` — GCC 12 rejects a default
   argument that constructs a nested class with default member initializers
   while the enclosing class is incomplete; replaced with a forwarding
   overload (a member-function body IS a complete-class context).
2. STARTUP SIGSEGV (real, caught only at smoke): the FRAME notifier first
   fires from INSIDE running_machine::start() — video_manager's startup
   calls frame_update before natkeyboard() exists — so setup() crashed the
   process before the first prompt. on_frame now defers setup and all
   engine work until machine_phase::RUNNING. (The Lua agent had that
   guarantee for free: emu.register_periodic only fires once running.)

Build evidence: chroot build clean (logs at
lab:/data/vms/soltest/mamectl-dev/mamectl-build[123].log), ctlsock.o
compiles warning-free even under -Werror. Smoke on a PROM-only boot
(lab:/data/vms/soltest/mamectl-dev/smoke/): HELLO parsed by mctl-probe.py,
STAT ver=1 with ticks==mtime*1000 (1 kHz timer true), sig=2236991a
entries=3897 == the Stage-0 V4 skeleton signature exactly (9-entry covenant
holds), MOVEP OK, FROB -> ERR badverb exit 2, KEYDUMP 128 rows. Dev binary
for validation: lab:/data/vms/soltest/mamectl-dev/sgi-ctl2 md5
893272bbe5343b722cbacb6f8ade2c3e (post-review; sgi-ctl 4272f8d2… is the
pre-review build, kept for provenance). Final patch re-verified freestanding
(dry-run on the restored pristine tree, again after the review fixes).

## What exists now

- `scripts/build-guests/mame-ctlsock.patch` — patch #14, appended LAST in
  `irix-mame-stack.sh`. Freestanding: dry-run-applies clean on the PRISTINE
  pinned tree (verified 2026-08-04 against lab
  `/data/vms/soltest/trixie-chroot/build/mame` at 8f21e978, git-clean).
  Touches: `scripts/src/osd/modules.lua` (2 build lines),
  `src/osd/modules/lib/osdobj_common.cpp` (include + unconditional
  `ctlsock_init(machine)` at the end of `osd_common_t::init`),
  `src/emu/save.cpp` (loud validate_header reason line), and adds
  `src/osd/modules/ctlsock/ctlsock.{h,cpp}`. No overlap with any of the other
  13 patches (grep-verified), so pristine-apply == post-stack-apply.
- `streamhost/tiles/irix/irixagent.lua` — stale-XTEST header corrected; file
  stays as the rollback arm.
- Local patch build tree (a/ pristine, b/ patched, module sources):
  `<this dir>/a`, `<this dir>/b`, `<this dir>/src/osd/modules/ctlsock/`.

## Coordination (BINDING)

The build chroot is now `lab:/data/vms/soltest/trixie-chroot` (fresh
debootstrap trixie + gcc-14, 2026-08-04; same compiler generation as the box,
so chroot builds are representative of shipping builds). Its pinned tree
`/build/mame` (8f21e978, kept git-clean between builds) is SHARED — bisect
workflows may still use it. Before building there: wait until
`ssh lab 'ps -eo pcpu,comm --sort=-pcpu | head'` shows no make/cc1plus in the
chroot, and prefer a namespaced copy under `/data/vms/soltest/` for anything
destructive. NEVER build in a live tile directory.

`bookworm-chroot` (gcc-12) is retired **for the IRIX build** but is NOT
deletable: `scripts/build-guests/build-mame-mpf2.sh` builds there on purpose, so
that binary's glibc/libstdc++ ABI matches the Debian 12 bridge base it runs
inside (`scripts/build-guests/bridge-base.sh` — frozen at bookworm, four
overlays depend on it byte-for-byte). Deleting the chroot breaks that build.
Any future bridge-hosted MAME target has the same constraint.

## Build

Canonical reproducer (fresh clone, applies the whole stack incl. #14):

    scripts/build-guests/build-mame-irix.sh [work-dir]

Incremental on the pinned chroot tree (after the stack is applied) — the
PROVEN trixie-chroot flag set (2026-08-04 cold build clean, smoke
sig=2236991a/3897 confirmed):

    chroot /data/vms/soltest/trixie-chroot /bin/bash -c \
      'cd /build/mame && make SUBTARGET=sgi SOURCES=src/mame/sgi/indy_indigo2.cpp \
       REGENIE=1 USE_QTDEBUG=0 TOOLS=0 -j16'

- `USE_QTDEBUG=0` mandatory on the box (no qmake6).
- `NOWERROR=1` RETIRED with the bookworm chroot: it only papered over a
  gcc-12 -Wrestrict false positive in mips3.cpp state_string_export, and the
  gcc-14 trixie chroot passes -Werror clean without it. Re-add only if you
  ever build with gcc-12 again.
- `REGENIE=1` once after any modules.lua change: genie re-runs automatically
  on the lua change itself, but if the PREVIOUS genie pass ran with different
  flags (e.g. without NOWERROR), the stale flag set stays baked into the
  generated makefiles until REGENIE forces a regen.
- The osd_modules genie project compiles everything listed in modules.lua for
  the SDL OSD; no per-target wiring needed.

## Enabled-arm env (clone validation)

The module object + timer are UNCONDITIONAL (one signature both arms). The
listener/engines need, on the CLONE launcher only:

    MAME_CTL_SOCK=<clone-dir>/ctl.sock
    MAME_CTL_CURSOR_ITEMS=:vc2/0/m_cursor_x,:vc2/0/m_cursor_y,:vc2/0/m_enable_cursor
    # optional: MAME_CTL_CMD_FILE=<clone-dir>/irix_cmd   (legacy tail; ONLY
    #   with the Lua agent OFF — single-injector rule)
    # defaults already correct: PTR_PORTS=:hle_ps2_mouse, CAL -31/-31,
    #   MOVE_STEP/WINDOW 120/40ms, KEY_HOLD/GAP 100/50ms, TRIES 40,
    #   SCREEN 1288x1024, STAT_PERIOD 15

Interlock (Stage 2 lands the x11-runtime.sh assertion, but the rule binds
NOW on clones): `MAME_CTL_SOCK` set => launch WITHOUT `-autoboot_script
irixagent.lua`. Two injectors fight over pacing budgets/accumulators.

## Verification orders (Stage-0 verdict §4, all BINDING)

1. **Signature (V4 re-run on the real module).** Expect: enabled and disabled
   arms report the SAME `sig=`/`entries=` (STAT and the setup/exit stderr
   lines carry both); entries delta vs an unpatched build = exactly +9 (the
   one persistent timer); an OLD golden vs the new binary fails LOUD with
   `state header check failed: Incompatible save file (signature X, expected
   Y)` (the save.cpp hunk guarantees the reason line) and falls back to cold
   boot; cross-loads en<->dis both directions succeed.
2. **Golden-trace differential** — `scripts/build-guests/irix-ctl/`
   (goldtrace-record.py both arms, goldtrace-compare.py). The corpus already
   encodes the two BINDING cases: post-restore first-MOVEA, and the
   deterministic (300,500) chooser give-up settling ~(186,386) — the module
   must REPRODUCE the give-up (bug-for-bug), expected giveups delta 3.
3. **Kbd-matrix re-latch (V6 residual).** V6 proved the button port only; run
   the same set_value+frame_update check on the `:ioc2:kbd:ms_naturl:P*`
   ports (the corpus KEY chords cover this observably via fb signatures).
4. **A/B latency** — `irix-ctl/ab-latency.py` per the corrected §10 protocol:
   paired interleaved arms, ONE binary + ONE golden, N>=100/arm, deltas only
   (fb.shm publish gap 33-43 ms dominates absolutes). BEFORE baseline (idle
   chooser): p50 44.1 / p95 54.7 ms. Gates: A1 median >=5 ms, p95 >=10 ms
   improvement; A2 from the module's STAT receipt->apply histogram
   (h_lt1..h_ge100, semantics: receipt -> drain pickup/apply, pacing
   excluded); A4 speed within 1 pp, module CPU <=1% of a core.
5. **Post-restore transient gone.** After LOADST (and after a startup -state
   restore) the module re-seeds the accumulator from the restored
   hle_ps2_mouse m_mouse_x/y save items and slams the analog fields to it
   (`reseeds=` in STAT increments). The Lua arm still rings for seconds there
   — the RIG must keep its pre-seed slam + stability gate for the lua arm.
6. **SAVEST/LOADST.** immediate_save/load only (schedule_* BANNED — they
   resume() a paused machine). ~12 s stop-the-world for the 44 MB state:
   client ack timeout >=60 s (`mctl-probe.py --timeout 60`); an EV-STATS gap
   during the save is expected. SAVEST while RUNNING may ERR busy (pending
   anonymous timers) — PAUSE first, that is the bake flow anyway.
7. **Paused pump.** While paused, verbs are serviced by the frame drain only:
   pickup ~40-50 ms. Never conclude "dead" from 50 ms of paused silence.

## Wire quick-reference (for smoke tests)

    printf '1 PING\n'  | ... # or: scripts/build-guests/irix-ctl/mctl-probe.py <sock> PING
    HELLO mamectl/1 <build> indy_4610 caps=natkbd,savest,shot,relatch[,movea][,tail] screen=1288x1024
    seq VERB args -> seq OK [data] | seq ERR code text ; seq "-" = no reply
    EV STATS ... / EV MOVEA <seq> converged|gaveup <ex> <ey> / EV LOADED <name> / EV PAUSED / EV RESUMED
    STAT data: k=v single line incl. giveups= (int, cumulative), movea_mode=closed|open,
      h_lt1..h_ge100 (histogram), sig=/entries= (V4 probe), last_in_ms=, reseeds=

Ack semantics: MOVE/POST/CODE/edges ack on apply; MOVEP acks when its queue
entry fully drains; MOVEA acks on accept + completes via EV MOVEA; KEY acks
when its edge applies (hold/gap-paced, so a burst acks over ~0.15 s/key);
CLICKn acks at its release edge; SAVEST/LOADST ack on completion; SYNC acks
when mq/kq/click queues are empty (deliberately does NOT wait for MOVEA
convergence or actions deferred behind it).

## Deploy sequence after validation (design §9 — ONE rebake, front-loaded)

1. Land patch + evidence; build the shipping binary via build-mame-irix.sh.
2. Deploy to the tile with `MAME_CTL_SOCK` UNSET (disabled arm: Lua/file path
   verbatim, zero behavior change).
3. Run `scripts/coldboot/irix-record-boot.sh` ONCE (streamhost@irix stopped;
   ~10 min) — new binary md5 => the md5 provenance guard orphans the old
   golden regardless, and the new golden settles the +9-entry signature.
4. Keep the outgoing binary as `sgi.prev-<md5>`.
   Every later stage (streamhost mamesock, labctl ctl, bake modernization) is
   a host-side env/config flip — no further rebakes; both rollback tiers keep
   the golden loadable (proven V4 cross-loads).

## Known open items (NOT in this patch)

- `shmpng.py --cursor` + out.png early-return bug (Stage-0 order #5): repo
  fix owed during Stage 1, ruff-gated — not part of the C++ patch.
- x11-runtime.sh launcher interlock assertion + stale-ctl.sock pre-clean:
  Stage 2 (with the mamesock cutover), not this patch.
- Compile pass: expect fixes; keep them inside the patch file and re-run the
  pristine dry-run (`patch -p1 --dry-run -f`) after every edit — the
  freestanding property is a gate, not a hope.
- If the compiler rejects anything around `emu_file probe(searchpath ? ...)`
  or `util::core_file::open`, see machine.cpp handle_saveload / video.cpp
  snapshot code for the exact house idiom on this tree.
