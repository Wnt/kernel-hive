#!/bin/bash
# x11-runtime.sh — the IRIX tile launcher (issue #20). The FIRST non-QEMU
# streamhost tile: instead of a QEMU/dbus display it stands up an Xvfb and runs
# SGI IRIX 6.5 inside MAME (indy_4610), which streamhost captures via
# SH_CAPTURE=x11 + XTEST/Lua input (SH_INPUT_BACKEND=x11test).
#
# Installed byte-for-byte as /data/vms/streamhost/tiles/irix/x11-runtime.sh by
# scripts/streamhost-tile.sh --x11 (verbatim, like a bridge tile's launcher).
# ensure-tile-x11.sh execs it inside a 3 GiB qcap scope. Kill ONLY by pidfile.
#
# Adapted from the proven /data/vms/soltest/irix-mame/irix-launch.sh. The large
# binaries (2 GiB CHD, PROM roms, MAME sgi binary) are NOT in the
# repo — stage them with fetch-assets.sh; their locations are overridable below.
#
# The defaults are the PRODUCTION asset tree /data/vms/streamhost/assets/irix.
# NEVER point a live tile at /data/vms/soltest (the clone/experiment scratch
# area): agents rebuild and delete things there under a running exhibit.
#
# MODES
#   (no arg)      full launch: Xvfb + MAME + boot watchdog + liveness watchdog
#   --mame-only   restart just MAME on the existing Xvfb (used by the watchdog)
#   --bootwatch   run the boot watchdog loop in the foreground (internal)
#   --livewatch   run the guest-liveness watchdog in the foreground (internal)
set -u

D="$(cd "$(dirname "$0")" && pwd)" # tile runtime dir (writable: pidfiles/diff/nvram)
# Read-only media + toolchain (overridable; defaults = the production stage).
ASSETS="${IRIX_ASSETS:-/data/vms/streamhost/assets/irix}" # roms/, irix65.chd, uicfg/, nvram/
MAME_BIN="${IRIX_MAME:-/data/vms/streamhost/assets/irix/mame/sgi}"
# The golden disk image. irix65-apps-v3.chd is the exhibit build: SGI General
# Demos + accessx, root XFS grown, `chkconfig esp/sysevent off`, a
# DETERMINISTICALLY BARE desktop (Toolchest and icons, no windows — two cold
# boots from independent clones produced md5-identical framebuffers), and
# `/.sgisession` running `xset m 1/1 0` so the pointer is 1:1 from login,
# measured 0.995/0.993 against IRIX's ~2.75x/1.77x default. The earlier builds
# sit beside it for one-variable rollback via IRIX_GOLDEN.
GOLDEN="${IRIX_GOLDEN:-$ASSETS/irix65-apps-v3.chd}"

# ---- INSTANT RESTORE (issue #44) -------------------------------------------
# IRIX_STATE names a baked MAME savestate + its PAIRED disk image under
# IRIX_STATE_DIR; when both exist and the provenance matches the running MAME
# binary, start_mame boots by RESTORING (paired disk reflink + `-state`) in
# seconds instead of the ~390 s cold boot. Empty IRIX_STATE = cold boot,
# exactly as before. A savestate is only valid against the CHD captured in the
# same pause window and the binary that wrote it — a MAME rebuild orphans every
# state (registration-signature change), which the md5 guard turns from silent
# garbage into a loud cold-boot fallback. After two restore launches without a
# healthy guest (watchdog relaunches), the next launch cold-boots; livewatch
# clears the counter on its first successful pointer probe. Bake states with
# scripts/build-guests/irix/irix-savestate/bake-golden.sh.
STATE="${IRIX_STATE:-}"
STATE_DIR="${IRIX_STATE_DIR:-$ASSETS/state}"

# Capture mode. `x11` (default, and what the live tile ships) renders MAME into
# an Xvfb that streamhost grabs with SH_CAPTURE=x11. `shm` runs MAME with
# `-video none` — no window, no X server at all — and has its Newport device
# publish each finished frame into $SHM, which streamhost maps with
# SH_CAPTURE=shm. The x11 path costs 32-43% of host time in SDL texture upload +
# llvmpipe blit + X round trip and delivers a WINDOW-SCALED 1272x954 resample;
# the shm path deletes all of it and delivers the exact 1288x1024 emulated
# framebuffer. Pointer input must move with it (SH_INPUT_BACKEND=mamecmd), since
# with no window there is nothing for XTEST to inject into.
CAPTURE="${IRIX_CAPTURE:-x11}"

# Guest networking. `off` (the historical behaviour) leaves MAME's SEEQ 80C03
# with no host interface bound, and IRIX boots saying "IRIS's Internet address
# is the default. Using standalone network mode."  `on` attaches the emulated
# Ethernet to a HOST-ONLY /30 tap, which is the only kind of networking this
# exhibit may ever have: a 2003 IRIX with a root-owned Apache in it must not be
# reachable from — or able to reach — the LAN or the internet. `tapnet.sh` is
# what enforces that, and it runs on EVERY launch, which is what makes the link
# survive both a tile relaunch and a host reboot without a separate unit.
#
# MAME chooses its host interface from the machine CFG FILE, not a command-line
# option: `network_manager::config_load` reads the `<system><network><device>`
# node out of `<cfg_directory>/indy_4610.cfg` and calls `set_interface()` — a
# real apply path, unlike DEVICE_INPUT_DEFAULTS, which silently round-trips
# values back without applying them. That node is normally written by MAME's
# "Network Devices" UI; this tile runs `-video none` and has none, so the cfg is
# SEEDED before every launch, like the nvram dir: deliberate state, not drift.
#
# IRIX_NET_EGRESS (default off) is the second, separate decision: with it `on`
# the guest may DIAL OUT to the LAN and the internet, while nothing may dial IN.
# tapnet.sh holds the rules and the reasoning. There is NO host-side web proxy
# (dropped 2026-08-03): Netscape connects directly and fails on https://, and
# the golden's prefs were rewritten to match — prefs aimed at a proxy nobody
# runs break EVERY page load, including the ones the browser could serve.
NET="${IRIX_NET:-off}"
NET_EGRESS="${IRIX_NET_EGRESS:-off}"
TAP_IF="${IRIX_TAP_IF:-irixtap0}"
TAP_HOST_CIDR="${IRIX_TAP_HOST_CIDR:-172.31.20.1/30}"
TAP_GUEST_IP="${IRIX_TAP_GUEST_IP:-172.31.20.2}"
# What MAME reports as the emulated NIC's MAC. IRIX programs the SEEQ's station
# address itself from the PROM `eaddr`, so this only has to agree with that.
TAP_MAC="${IRIX_TAP_MAC:-08:00:69:12:34:56}"
TAPNET="${IRIX_TAPNET:-$D/tapnet.sh}"
CFGDIR="$D/cfg"

# Guest audio. `off` (default, the historical behaviour) keeps `-sound none`.
# `on` swaps in `-sound sdl -audiodriver disk` aimed at a named FIFO: SDL's
# "disk" backend write()s the mixed S16LE 2ch 48 kHz PCM to SDL_DISKAUDIOFILE,
# and the streamhost daemon (SH_AUDIO_SOURCE=fifo) is the CLOCK on the far
# end — paced reads of exactly 192,000 B/s; the pipe's backpressure paces SDL
# (SDL_DISKAUDIODELAY=0: SDL never sleeps, the pipe is the throttle). The
# launcher's side of that contract is armed in audio_up(). The FIFO path is
# read from the daemon's own SH_AUDIO_FIFO knob (like SH_SHM_PATH) so producer
# and consumer cannot disagree.
AUDIO="${IRIX_AUDIO:-off}"
AFIFO="${SH_AUDIO_FIFO:-$D/audio.fifo}"

# Native control plane (issue #45). `on` (default) has the mamectl OSD module
# baked into the MAME binary serve its mamectl/1 line protocol on $D/ctl.sock
# (MAME_CTL_SOCK): the daemon's mamesock input backend, this launcher's own
# liveness probes and labctl all speak to that socket, and the Lua agent is NOT
# loaded — MAME_CTL_SOCK set means no -autoboot_script (single-injector rule:
# two injectors fight over pacing budgets/accumulators). Rollback tiers:
# SH_INPUT_BACKEND=mamecmd re-arms the module's tail of the command file (the
# daemon writes it, the module consumes it — still one injector); IRIX_CTL=off
# is the deep rollback, restoring the Lua agent + command file with not one
# MAME argument or variable changed.
CTL="${IRIX_CTL:-on}"

DISP="${SH_X11_DISPLAY:-:40}"
GEOM="${IRIX_GEOMETRY:-1280x1024x24}"
SHM="${SH_SHM_PATH:-$D/fb.shm}"
CMD="${SH_X11_CMD_FILE:-$D/irix_cmd}"
AGENT="$D/irixagent.lua"
FBSTAT="$D/fbstat.py"
MODE="${1:-full}"

# --- boot watchdog tunables -------------------------------------------------
# A cold boot hangs on a permanently BLACK framebuffer roughly 2 times in 3
# (nondeterministic, reproduced on both the 256 MB and the stock MAME build from
# a byte-identical fresh disk.chd — see docs/history/irix-tile-issue20-handoff.md).
# The only reliable recovery is a relaunch, so the runtime watches its own
# framebuffer and retries. Detection is the REAL framebuffer, never log
# inference: a fully black root window (all channel means below BLACK_EPS) held
# for BLACK_HITS consecutive samples is the hang; a healthy boot is never black
# after the PROM splash paints at ~10 s.
WATCH_INTERVAL="${IRIX_WATCH_INTERVAL:-15}" # seconds between framebuffer samples
WATCH_GRACE="${IRIX_WATCH_GRACE:-60}"       # ignore black before this (MAME window not up yet)
WATCH_BLACK_HITS="${IRIX_WATCH_BLACK_HITS:-6}"
WATCH_DEADLINE="${IRIX_WATCH_DEADLINE:-1800}" # give up watching this attempt after
WATCH_ATTEMPTS="${IRIX_WATCH_ATTEMPTS:-5}"    # total boots incl. the first
BLACK_EPS="${IRIX_BLACK_EPS:-0.004}"
WLOG="$D/bootwatch.log"

# --- guest-liveness watchdog tunables ---------------------------------------
# A SECOND failure mode, and one the black-screen test cannot see: the guest
# dies (or its input channel does) while MAME keeps rendering a perfectly
# ordinary-looking frame forever. Seen twice on the exhibit as
# `PANIC: bad istack sp:8835afa8` — root-caused to the SGI MC truncating DMA
# page-table addresses above 128 MB and fixed by
# scripts/build-guests/mame-mc-dma-ptbase-mask.patch. This watchdog is the
# safety net BEHIND that fix, not the fix: it exists so no future guest-side
# death needs a human to notice it.
#
# Detection is a real ACTIVE PROBE, never a picture-classifier. Frame statistics
# cannot separate "dead" from "idle" — a bare 4Dwm desktop with no visitor is
# byte-static too, and this exhibit has already been burned once by a
# mean/stddev classifier calling healthy screens panics. So: when the frame has
# not changed for LIVE_STATIC_HITS samples (nobody is interacting), nudge the
# emulated pointer a few pixels through the SAME input channel a visitor's
# mouse uses and look again. A live guest redraws the cursor; a dead one does not.
# That also covers the input channel end to end (agent + ioport), which is what
# issue #43 originally suspected.
#
# The probe reads the CURSOR, not a whole-frame hash. `fbstat.py --sig` samples
# every 64th pixel, and the pointer is ~50 pixels: it can move the entire width
# of the screen without changing one sampled byte, so a signature comparison can
# call a perfectly healthy guest dead — and, the other way round, a blinking
# text caret changes the signature and hides a dead one. `fbstat.py --cursor`
# answers the question the probe is actually asking: did the pointer I just
# nudged move.
LIVE_INTERVAL="${IRIX_LIVE_INTERVAL:-30}"      # seconds between liveness samples
LIVE_GRACE="${IRIX_LIVE_GRACE:-600}"           # never probe during boot/login
LIVE_STATIC_HITS="${IRIX_LIVE_STATIC_HITS:-3}" # x INTERVAL of a frozen frame before probing
LIVE_PROBE_FAILS="${IRIX_LIVE_PROBE_FAILS:-3}" # consecutive dead probes before acting
# …and they must span at least this long. A LOGIN is the case that matters: xdm
# resets the X server, which re-opens and re-initialises the PS/2 mouse, and for
# a couple of minutes afterwards (the bare X root sits there for minutes before
# 4Dwm draws the Toolchest) injected motion legitimately does not move the
# cursor. `LIVE_GRACE` cannot cover it, because a visitor logs in whenever they
# like — hours after launch. Observed on the live tile 2026-08-03: two failed
# probes 90 s apart during a session start relaunched a perfectly healthy guest.
# A real death lasts forever, so requiring the evidence to span five minutes
# costs nothing and removes the whole transition class.
LIVE_DEAD_MIN="${IRIX_LIVE_DEAD_MIN:-300}"
LIVE_ATTEMPTS="${IRIX_LIVE_ATTEMPTS:-3}" # relaunches this watchdog may perform
LIVE_NUDGE="${IRIX_LIVE_NUDGE:-80}"      # probe amplitude, emulated mouse counts
# Cadence probe: a frame that keeps CHANGING for reasons unrelated to input — a
# blinking caret in the login field is the one that matters, and it is exactly
# what was on screen when a visitor last lost all input — would otherwise stop
# the static-frame rule from ever arming. So probe on a timer as well, but only
# while nobody is actually driving the tile (no visitor input since the last
# sample — see input_recent), so a visitor is never nudged mid-drag.
LIVE_PROBE_EVERY="${IRIX_LIVE_PROBE_EVERY:-600}"
LLOG="$D/livewatch.log"
# systemd unit whose liveness gates a relaunch. Set to "" to disable the check
# (clone rigs under /data/vms/soltest have no unit).
WATCH_UNIT="${IRIX_WATCH_UNIT-streamhost@$(basename "$D")}"

wlog() { echo "$(date '+%F %T') $*" >>"$WLOG"; }
# The liveness watchdog keeps its OWN log. It used to share bootwatch.log, and
# when the exhibit lost all input the first thing the investigation did was look
# for livewatch.log, not find one, and conclude the watchdog had never started —
# while it was in fact running and about to fire. A watchdog that cannot be
# shown to be alive is not a watchdog.
llog() { echo "$(date '+%F %T') $*" >>"$LLOG"; }

# Bring up the tap and seed the machine cfg that BINDS the emulated SEEQ to it.
# Both are re-done on every launch: the tap so a host reboot needs no other
# unit, the cfg because MAME rewrites it on a clean exit and would otherwise
# carry one run's state into the next (the nvram rule, other file).
net_up() {
  [ "$NET" = on ] || return 0
  if [ ! -f "$TAPNET" ]; then
    echo "FATAL: IRIX_NET=on but $TAPNET is missing" >&2
    return 1
  fi
  # Via `bash`, not exec-bit: --aux-file copies the file into the tile dir and
  # the mode it lands with is a umask away from being wrong.
  IRIX_NET_EGRESS="$NET_EGRESS" bash "$TAPNET" up "$TAP_IF" "$TAP_HOST_CIDR" "$TAP_GUEST_IP" || return 1
  mkdir -p "$CFGDIR"
  cat >"$CFGDIR/indy_4610.cfg" <<EOF
<?xml version="1.0"?>
<mameconfig version="10">
    <system name="indy_4610">
        <network>
            <device tag=":edlc" interface="0" mac="$TAP_MAC" />
        </network>
    </system>
</mameconfig>
EOF
}

# Arm the audio transport. Called by start_mame in whichever shell is about to
# launch MAME (the full launch AND a watchdog relaunch), because the
# exec {fd}<> below only matters through INHERITANCE: the background MAME gets
# a copy of the open O_RDWR fd in its own fd table, so the reader-of-last-
# resort lives exactly as long as the writer it protects — the launcher shell
# exiting afterwards closes only its own copy. That fd makes the daemon a
# replaceable part: SDL's blocking open() of the FIFO succeeds no matter which
# side starts first, and a daemon dying or restarting mid-run can never
# SIGPIPE-kill the exhibit — the pipe (F_SETPIPE_SZ'd to 16 KiB by the daemon,
# ~85 ms of audio) just fills and SDL's audio thread blocks while emulation
# continues (probed, not assumed).
audio_up() {
  [ -p "$AFIFO" ] || { rm -f -- "$AFIFO" && mkfifo "$AFIFO"; } || {
    echo "FATAL: IRIX_AUDIO=on but cannot create FIFO $AFIFO" >&2
    return 1
  }
  # Belt to the fd's braces: ignored dispositions survive exec, so MAME
  # inherits SIG_IGN for SIGPIPE and a vanished reader is an EPIPE write error
  # (absorbed by SDL), never a process-killing signal.
  trap '' PIPE
  # The holder fd: bash allocates one >= 10 and records it in $AUDIO_FD. O_RDWR
  # on a FIFO never blocks and counts as a reader. A watchdog shell relaunching
  # MAME closes the copy its previous start_mame left before opening anew.
  [ -n "${AUDIO_FD:-}" ] && exec {AUDIO_FD}>&-
  exec {AUDIO_FD}<>"$AFIFO"
}

kill_pidfile() { # $1 = pidfile; kill ONLY the recorded pid
  local pf="$1" p
  [ -f "$pf" ] || return 0
  p="$(cat "$pf" 2>/dev/null || true)"
  if [ -n "$p" ] && [ -e "/proc/$p" ]; then kill -9 "$p" 2>/dev/null || true; fi
  : >"$pf"
}

# True when MAME is SIGSTOPped — the daemon's idle auto-pause froze it because
# no visitor has been connected for SH_IDLE_PAUSE_SECS (streamhost idle.rs,
# SH_IDLE_PAUSE_PIDFILE points at mame.pid).
#
# BOTH watchdogs below must consult this before they act, because a deliberately
# frozen emulator wears the exact costume of a dead one: the framebuffer stops
# changing (bootwatch's black test, livewatch's static test) and injected
# pointer motion moves nothing (livewatch's probe, whose whole design is that a
# live guest redraws the cursor). Without this check the pauser and the watchdog
# fight: the daemon freezes an idle exhibit, the watchdog calls it dead and
# relaunches it, and the tile silently reboots itself on a timer forever while
# nobody is watching. The process state is read from the kernel rather than from
# any flag the daemon sets, so the two sides cannot disagree.
mame_stopped() {
  local p st
  p="$(cat "$D/mame.pid" 2>/dev/null || true)"
  [ -n "$p" ] || return 1
  # field 3 of /proc/pid/stat, read after the ')' so a comm with spaces or
  # parens in it cannot shift the columns. T = stopped, t = trace-stopped.
  st="$(sed -n 's/^.*) \([A-Za-z]\).*/\1/p' "/proc/$p/stat" 2>/dev/null || true)"
  [ "$st" = T ] || [ "$st" = t ]
}

# Writable per-tile disk, re-made from the golden on EVERY launch so each boot
# (and every reset, which is a relaunch) starts pristine.
#
# Why a copy and not `-diff_directory`: the golden is an UNCOMPRESSED CHD, and
# MAME opens such an image O_RDWR and never creates a diff — it mutated the
# golden in place for days (observed 2026-07-31: three silent md5 drifts; chmod
# 444 does not help because MAME runs as root). Locking the golden `chattr +i`
# does stop that, but MAME has no read-only fallback: it dies with
# "Unable to load image ...: Operation not permitted". So: golden immutable +
# a throwaway per-launch copy. `--reflink=always` makes that a ZFS block clone:
# 0.13 s for 2.24 GB, versus ~2 s when `auto` silently falls back to a real copy.
# nvram is re-seeded from the staged copy on EVERY launch, for the same reason
# the disk is: everything in it (eaddr, monitor=h, and the install guide's baked
# `date 0730120026`) was set deliberately, and none of it should drift. MAME
# rewrites the nvram directory when it exits cleanly, so a persisted copy would
# carry each run's clock into the next one and walk away from the baked value.
# Today that is masked because MAME is always SIGKILLed and never reaches its
# nvram save -- but irixagent.lua's EXIT verb calls machine:exit(), which does
# save. Re-seeding makes every boot start from the same known state instead of
# depending on how the last one happened to die.
start_mame() {
  local disk="$D/disk.chd" p pin=() restore="" starg=() tries
  # Optional CPU pin (IRIX_CPUS, e.g. "2,10" = one physical core + its SMT
  # sibling). The box is shared with build/benchmark agents, so the exhibit
  # keeps to its allotted cores instead of wandering the machine.
  [ -n "${IRIX_CPUS:-}" ] && pin=(taskset -c "$IRIX_CPUS")
  kill_pidfile "$D/mame.pid"
  # Instant-restore eligibility. Every guard is a LOUD cold-boot fallback: a
  # restore that cannot be proven valid must not be attempted, because a wrong
  # (state, disk, binary) triple loads, renders a plausible frame and dies —
  # the failure mode this tile's whole verification methodology exists for.
  if [ -n "$STATE" ]; then
    tries=$(cat "$D/.state-tries" 2>/dev/null || echo 0)
    if [ "$tries" -ge 2 ]; then
      echo "irix restore: $tries restore launches without a healthy guest — cold-boot fallback" >&2
    elif [ ! -f "$STATE_DIR/sta/indy_4610/$STATE.sta" ] || [ ! -f "$STATE_DIR/disk-$STATE.chd" ]; then
      echo "irix restore: state '$STATE' assets missing under $STATE_DIR — cold boot" >&2
    elif ! grep -q "^$(md5sum "$MAME_BIN" | cut -d' ' -f1) " "$STATE_DIR/provenance-$STATE.md5" 2>/dev/null; then
      echo "irix restore: MAME binary md5 not in provenance-$STATE.md5 (a rebuild orphans every state) — cold boot" >&2
    else
      restore="$STATE"
      starg=(-state_directory "$STATE_DIR/sta" -state "$STATE")
      echo $((tries + 1)) >"$D/.state-tries"
    fi
  fi
  rm -f -- "$disk"
  if [ -n "$restore" ]; then
    # The disk that was reflink-snapshotted in the same pause window the state
    # was saved in — the only disk this state is valid against.
    cp --reflink=always -- "$STATE_DIR/disk-$STATE.chd" "$disk"
  else
    cp --reflink=always -- "$GOLDEN" "$disk"
  fi
  chmod 644 -- "$disk"
  if [ -d "$ASSETS/nvram" ]; then
    rm -rf -- "$D/nvram"
    mkdir -p "$D/nvram"
    cp -r "$ASSETS/nvram/." "$D/nvram/"
  fi
  : >"$CMD"
  # Rotate the geometry trace so the log left behind is exactly the boot that
  # just failed — the watchdog relaunches into the same tile dir, and losing the
  # hung boot's trace is the one thing that would make it useless.
  [ -f "$D/geo.log" ] && mv -f "$D/geo.log" "$D/geo.log.prev"
  # MAME/IRIX, exec'd directly against the host rootfs: the sgi binary needs at
  # most GLIBC_2.38 / GLIBCXX_3.4.32 and the box ships 2.41 / 3.4.33, so the
  # private loader+library-path indirection it once needed on bookworm is gone.
  # With IRIX_CTL=off the Lua agent drives natkeyboard + PS/2
  # buttons from $CMD; on, the in-binary mamectl module owns all injection.
  #
  # -frameskip 6 renders 6 of every 12 frames (~36 Hz, not Newport's ~72). The
  # tile streams at SH_FPS=30, so the rest were thrown away; scan-out is ~31% of
  # runtime and costed per frame GENERATED, so skipping them buys ~+18% emulation
  # speed (69.4% -> 81.9% @2.5 GHz, measured) with emulated time unchanged.
  # Verified invisible: `ffmpeg mpdecimate` counts 300/300 unique frames at 30
  # fps with the guest animating. Do NOT raise it — fs7 has zero margin and fs8
  # drops 34% of frames stale. Cost: a change waits ~7 ms longer for capture.
  local vid=(-video soft -mouse -background_input)
  # In shm mode MAME has no window — and MUST NOT be pointed at a DISPLAY. SDL
  # still initialises its video subsystem, so a stale DISPLAY (there is no Xvfb
  # in this mode) makes it die with "Could not initialize SDL x11 not available".
  # Unset both and it uses the dummy path.
  local disp=("DISPLAY=$DISP" SDL_VIDEODRIVER=x11)
  if [ "$CAPTURE" = shm ]; then
    vid=(-video none)
    disp=(-u DISPLAY -u SDL_VIDEODRIVER)
    rm -f -- "$SHM"
    export IRIX_SHM_PATH="$SHM"
  fi
  # Networking is entirely additive: with IRIX_NET=off not one argument or
  # variable changes, so the no-network exhibit is byte-for-byte what it was.
  local net=() netenv=()
  if [ "$NET" = on ]; then
    net_up || return 1
    net=(-cfg_directory "$CFGDIR" -networkprovider taptun)
    netenv=("MAME_TAP_IFNAME=$TAP_IF")
  fi
  # Audio is additive the same way: with IRIX_AUDIO=off not one argument or
  # variable changes, and the silent exhibit is byte-for-byte what it was.
  local snd=(-sound none) sndenv=()
  if [ "$AUDIO" = on ]; then
    audio_up || return 1
    snd=(-sound sdl -audiodriver disk)
    sndenv=("SDL_DISKAUDIOFILE=$AFIFO" SDL_DISKAUDIODELAY=0)
  fi
  # The control plane is additive the same way: with IRIX_CTL=off the Lua agent
  # + command file launch is byte-for-byte what it was (the deep-rollback arm).
  local agent=(-autoboot_script "$AGENT" -autoboot_delay 0) ctlenv=()
  if [ "$CTL" = on ]; then
    # Single-injector rule (BINDING): socket armed => no -autoboot_script. Two
    # injectors fight over pacing budgets/accumulators.
    agent=()
    rm -f -- "$D/ctl.sock" # the module binds fresh; never adopt a stale socket
    ctlenv=("MAME_CTL_SOCK=$D/ctl.sock"
      "MAME_CTL_CURSOR_ITEMS=:vc2/0/m_cursor_x,:vc2/0/m_cursor_y,:vc2/0/m_enable_cursor")
    # Legacy tail ONLY under the mamecmd rollback arm (the daemon writes $CMD,
    # the module tails it — still one injector). mamesock leaves it unset: the
    # 1 kHz file poll costs ~0.8% of a core, and Stage 5 retires it.
    [ "${SH_INPUT_BACKEND:-}" = mamecmd ] && ctlenv+=("MAME_CTL_CMD_FILE=$CMD")
  fi
  env "${disp[@]}" "${netenv[@]}" "${sndenv[@]}" "${ctlenv[@]}" IRIX_CMD="$CMD" \
    IRIX_GEO_LOG="${IRIX_GEO_LOG:-$D/geo.log}" nohup \
    "${pin[@]}" \
    "$MAME_BIN" indy_4610 -bios b10 -rompath "$ASSETS/roms" -gio64_gfx xl24 \
    -hard1 "$disk" \
    -ioc2:rs232a pty \
    -nvram_directory "$D/nvram" -inipath "$ASSETS/uicfg" \
    "${net[@]}" \
    -skip_gameinfo "${vid[@]}" "${snd[@]}" \
    -frameskip "${IRIX_FRAMESKIP:-6}" \
    "${agent[@]}" \
    "${starg[@]}" \
    >"$D/mame.log" 2>&1 &
  p=$!
  echo "$p" >"$D/mame.pid"
  sleep 5
  [ -e "/proc/$p" ] || {
    echo "MAME FAILED:" >&2
    cat "$D/mame.log" >&2 || true
    return 1
  }
  # Did MAME actually attach to the tap? A tap has NO CARRIER until a process
  # opens it, so this is a direct observation rather than an inference — and it
  # catches the one silent failure this feature has: a MAME binary built without
  # mame-taptun-ifname-env.patch ignores MAME_TAP_IFNAME, opens upstream's
  # `tap-mess-0-0` instead, finds nothing, logs "Network interface 0 not found"
  # into its own log and runs on with no networking at all.
  if [ "$NET" = on ]; then
    if [ "$(cat "/sys/class/net/$TAP_IF/carrier" 2>/dev/null || echo 0)" = 1 ]; then
      echo "irix net: $TAP_IF carrier up — MAME is attached (guest $TAP_GUEST_IP)"
    else
      echo "WARNING: IRIX_NET=on but $TAP_IF has no carrier — MAME did not attach." >&2
      echo "         Check that $MAME_BIN carries mame-taptun-ifname-env.patch." >&2
    fi
  fi
  publish_serial "$p"
  echo "irix runtime up: mame pid=$p capture=$CAPTURE xvfb=$DISP shm=$SHM cmd=$CMD serial=$(cat "$D/serial.pts" 2>/dev/null) boot=${restore:+restore:$restore}${restore:-cold} ctl=$([ "$CTL" = on ] && echo "$D/ctl.sock" || echo off)"
}

# The exec channel (`labctl exec irix`, /root/irixexec.py, irixser/2 to
# irixagent.pl in the guest) rides `-ioc2:rs232a pty` == IRIX /dev/ttyd2. MAME
# never prints the slave's name, so it is scraped out of the emulator's fd table
# and published here as a CONVENIENCE ONLY — it goes stale on relaunch, so the
# client re-derives it from mame.pid first. The slave is put in raw -echo (a
# fresh pts defaults to ECHO ON, which would bounce every byte the guest sends
# straight back into it), and nothing else ever holds it open. `socket.` is NOT
# usable: MAME never re-accepts, so an exec client would work once per boot.
publish_serial() {
  local p="$1" f idx
  rm -f -- "$D/serial.pts"
  for f in $(printf '%s\n' /proc/"$p"/fd/* 2>/dev/null | sort -t/ -k5 -n); do
    [ "$(readlink "$f" 2>/dev/null || true)" = /dev/ptmx ] || continue
    idx="$(awk '/^tty-index:/ { print $2 }' "/proc/$p/fdinfo/$(basename "$f")" 2>/dev/null || true)"
    [ -n "$idx" ] || continue
    echo "/dev/pts/$idx" >"$D/serial.pts"
    stty -F "/dev/pts/$idx" raw -echo 2>/dev/null || true
    return 0
  done
  return 0
}

# Largest per-channel mean of the frame MAME published into $SHM, normalised
# 0..1 — the same number `identify -format %[fx:max(mean.r,...)]` prints for the
# x11 path, so IRIX_BLACK_EPS keeps its meaning across both modes. Every 64th
# pixel is plenty to decide "is it pure black" and keeps a sample that runs every
# 15 s forever cheap.
shm_max_channel_mean() {
  "$FBSTAT" "$SHM"
}

# True when the framebuffer is (near) pure black — the hang signature. Both
# capture modes sample the REAL framebuffer, never a log: x11 grabs the Xvfb
# root, shm reads the mapping MAME publishes (there is no X server to grab).
# Either way a failure to sample returns non-zero, i.e. "not black" — the
# watchdog must never relaunch merely because it could not look.
fb_is_black() {
  local png="$D/.bootwatch.png" m
  if [ "$CAPTURE" = shm ]; then
    m="$(shm_max_channel_mean)" || return 1
  else
    DISPLAY="$DISP" import -window root "$png" 2>/dev/null || return 1
    m="$(identify -format '%[fx:max(mean.r,max(mean.g,mean.b))]' "$png" 2>/dev/null)" || return 1
  fi
  [ -n "$m" ] || return 1
  awk -v m="$m" -v e="$BLACK_EPS" 'BEGIN { exit !(m < e) }'
}

# The watchdog loop. Owns nothing but the MAME pidfile; it refuses to act once
# the launch generation changes (a newer x11-runtime.sh took over) or the
# systemd unit is no longer active (stop-tile-x11.sh is tearing the tile down),
# so it can never fight the service or resurrect a stopped tile.
bootwatch() {
  local gen attempt=1 t0 t black
  gen="$(cat "$D/bootwatch.gen" 2>/dev/null || echo none)"
  while :; do
    t0=$(date +%s)
    black=0
    while :; do
      sleep "$WATCH_INTERVAL"
      [ "$gen" = "$(cat "$D/bootwatch.gen" 2>/dev/null || echo none)" ] || {
        wlog "generation changed — watchdog exiting"
        return 0
      }
      # Idle auto-pause froze MAME: a frozen framebuffer is not a hung boot.
      # Push t0 with it so paused time is not spent out of the deadline either —
      # the deadline bounds how long a BOOT is watched, and a paused guest is
      # not booting.
      if mame_stopped; then
        black=0
        t0=$((t0 + WATCH_INTERVAL))
        continue
      fi
      t=$(($(date +%s) - t0))
      if [ "$t" -ge "$WATCH_DEADLINE" ]; then
        wlog "attempt $attempt: deadline ${WATCH_DEADLINE}s reached, stop watching"
        return 0
      fi
      if fb_is_black; then
        [ "$t" -lt "$WATCH_GRACE" ] && continue
        black=$((black + 1))
        wlog "attempt $attempt: black frame $black/$WATCH_BLACK_HITS at t=${t}s"
        [ "$black" -ge "$WATCH_BLACK_HITS" ] && break
      else
        black=0
      fi
    done
    # Confirmed hang.
    if [ "$attempt" -ge "$WATCH_ATTEMPTS" ]; then
      wlog "black-screen hang on attempt $attempt; attempt budget exhausted, giving up"
      return 1
    fi
    if [ -n "$WATCH_UNIT" ] && ! systemctl is-active --quiet "$WATCH_UNIT"; then
      wlog "black-screen hang but $WATCH_UNIT is not active — not relaunching"
      return 0
    fi
    attempt=$((attempt + 1))
    wlog "black-screen hang confirmed; relaunching MAME (attempt $attempt/$WATCH_ATTEMPTS)"
    start_mame >>"$WLOG" 2>&1 || wlog "relaunch failed to start MAME"
  done
}

# A cheap "has this frame changed at all" signature of the REAL framebuffer,
# from whichever capture path is live. Empty output means "could not look", and
# the caller must treat that as alive — never as dead.
fb_sig() {
  local png="$D/.livewatch.png"
  if [ "$CAPTURE" = shm ]; then
    "$FBSTAT" --sig "$SHM" 2>/dev/null | awk '{print $2}'
  else
    DISPLAY="$DISP" import -window root "$png" 2>/dev/null || return 0
    identify -format '%#' "$png" 2>/dev/null
  fi
}

# Where the guest is drawing its pointer, as `x y npix`, or empty if it cannot
# be located (boot, black screen, or the x11 rollback path, which has no cheap
# equivalent and falls back to the frame signature).
fb_cursor() {
  [ "$CAPTURE" = shm ] || return 0
  "$FBSTAT" --cursor "$SHM" 2>/dev/null
}

# One mamectl/1 request against the module's control socket: connect, read the
# HELLO banner, send "1 <verb line>", print the OK payload (STAT's k=v line).
# Non-zero on ERR/timeout/absent socket — callers map that to their own
# fail-open semantics. Async EV lines that arrive before the ack are skipped.
ctl_verb() {
  python3 - "$D/ctl.sock" "$1" <<'PY'
import socket
import sys

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5.0)
    s.connect(sys.argv[1])
    f = s.makefile("rw")
    if not f.readline().startswith("HELLO mamectl/"):
        sys.exit(1)
    f.write("1 " + sys.argv[2] + "\n")
    f.flush()
    for line in f:
        t = line.split(None, 2)
        if t[:2] == ["1", "OK"]:
            print(t[2].strip() if len(t) > 2 else "")
            sys.exit(0)
        if t[:2] == ["1", "ERR"]:
            sys.exit(1)
    sys.exit(1)
except OSError:
    sys.exit(1)
PY
}

# Inject one probe nudge over whichever input channel is live. Send failures
# are swallowed on purpose: the probe's verdict is probe_alive's framebuffer
# compare — a nudge that could not be delivered (module dead, socket gone)
# moves nothing, which is exactly what the compare calls DEAD, the same way a
# file append to a dead Lua agent reads today.
probe_nudge() {
  if [ "$CTL" = on ]; then
    ctl_verb "MOVEP $1 $2" >/dev/null 2>&1 || true
  else
    echo "MOVEP $1 $2" >>"$CMD"
  fi
}

# Nudge the pointer and see whether the guest MOVES IT. Returns 0 (alive) on
# anything ambiguous, including a failed sample: this decides whether to reboot
# a live exhibit, so every uncertainty resolves to "leave it alone". The nudge is
# symmetric so the pointer ends where it started, and it goes out over the same
# channel the browser's mouse uses (the control socket; the command file with
# IRIX_CTL=off) — a dead injector, a wedged emulated PS/2 mouse and a dead
# guest all fail it, which is the point.
probe_alive() {
  local b1 b2 b3 kind=cursor
  b1="$(fb_cursor)"
  case "$b1" in '' | '-1 -1 0') kind=sig ;; esac
  [ "$kind" = cursor ] || b1="$(fb_sig)"
  [ -n "$b1" ] || return 0
  probe_nudge "$LIVE_NUDGE" "$LIVE_NUDGE"
  sleep 3
  [ "$kind" = cursor ] && b2="$(fb_cursor)" || b2="$(fb_sig)"
  probe_nudge "-$LIVE_NUDGE" "-$LIVE_NUDGE"
  sleep 3
  [ "$kind" = cursor ] && b3="$(fb_cursor)" || b3="$(fb_sig)"
  [ -n "$b2" ] && [ -n "$b3" ] || return 0
  if [ "$b2" != "$b1" ] || [ "$b3" != "$b2" ]; then
    llog "probe($kind) ALIVE: $b1 -> $b2 -> $b3"
    return 0
  fi
  llog "probe($kind) DEAD: $b1 unchanged across a +-$LIVE_NUDGE nudge"
  return 1
}

# True when a visitor drove the tile since the last liveness sample, so the
# cadence probe stands down (a mid-drag nudge is the failure mode). File arm:
# the command file grew ($1 = current size, $2 = previous). Socket arm: the
# module's STAT last_in_ms (ms since any injected input) is younger than one
# sample interval; an unreachable STAT counts as no input — the same verdict
# an untouched command file gives.
input_recent() {
  local ms
  if [ "$CTL" = on ]; then
    ms="$(ctl_verb STAT 2>/dev/null | tr ' ' '\n' | sed -n 's/^last_in_ms=\([0-9][0-9]*\)$/\1/p')"
    [ -n "$ms" ] && [ "$ms" -lt $((LIVE_INTERVAL * 1000)) ]
  else
    [ "$1" != "$2" ]
  fi
}

# The liveness loop. Same containment rules as bootwatch: it owns nothing but
# the MAME pidfile, stands down when the launch generation changes or the
# systemd unit goes inactive, and has a bounded relaunch budget.
livewatch() {
  local gen sig prev="" static=0 fails=0 attempt=1 beat=0 due why
  local cmdsz=0 prevsz=0 last_probe first_fail=0 span=0 paused=0
  gen="$(cat "$D/bootwatch.gen" 2>/dev/null || echo none)"
  llog "livewatch: armed, sleeping ${LIVE_GRACE}s grace (interval=${LIVE_INTERVAL}s" \
    "static=$LIVE_STATIC_HITS fails=$LIVE_PROBE_FAILS attempts=$LIVE_ATTEMPTS" \
    "nudge=$LIVE_NUDGE cadence=${LIVE_PROBE_EVERY}s)"
  sleep "$LIVE_GRACE"
  last_probe=$(date +%s)
  while :; do
    sleep "$LIVE_INTERVAL"
    [ "$gen" = "$(cat "$D/bootwatch.gen" 2>/dev/null || echo none)" ] || {
      llog "livewatch: generation changed — exiting"
      return 0
    }
    # Idle auto-pause froze MAME. Every signal this loop reads is then a lie:
    # the frame cannot change and a nudge cannot move a pointer whose emulator
    # is not running, which is verbatim the "dead guest" verdict. Stand down and
    # reset the evidence, so the first samples after a visitor resumes the tile
    # start a fresh case rather than completing one built while it was frozen.
    # Logged on the EDGES only. A silent stand-down would spend a whole
    # unvisited night looking exactly like a watchdog that had died — which
    # this file already learned the hard way is indistinguishable from the
    # absence of evidence — while a line every LIVE_INTERVAL would bury the
    # log. The pair of edges answers both questions: it was alive, and it knew.
    if mame_stopped; then
      [ "$paused" = 1 ] || llog "livewatch: MAME is SIGSTOPped (idle auto-pause) — standing down"
      paused=1
      static=0
      fails=0
      first_fail=0
      prev=""
      last_probe=$(date +%s)
      continue
    fi
    if [ "$paused" = 1 ]; then
      llog "livewatch: MAME resumed — watching again"
      paused=0
    fi
    sig="$(fb_sig)"
    [ -n "$sig" ] || continue
    prevsz="$cmdsz"
    cmdsz="$(stat -c %s "$CMD" 2>/dev/null || echo 0)"
    if [ "$sig" = "$prev" ]; then static=$((static + 1)); else
      static=0
      fails=0
    fi
    prev="$sig"
    # Heartbeat, so "was the watchdog running?" is answerable from this file
    # alone rather than from the absence of evidence.
    beat=$((beat + 1))
    if [ $((beat % 10)) -eq 0 ]; then
      llog "heartbeat: static=$static fails=$fails attempt=$attempt cmdbytes=$cmdsz"
    fi
    why=""
    [ "$static" -ge "$LIVE_STATIC_HITS" ] && why=frozen
    if [ -z "$why" ]; then
      due=$(($(date +%s) - last_probe))
      # Cadence probe only while nothing is being sent: a visitor mid-drag must
      # never be nudged, and if input IS flowing the frozen-frame rule covers it.
      [ "$due" -ge "$LIVE_PROBE_EVERY" ] && ! input_recent "$cmdsz" "$prevsz" && why=cadence
    fi
    [ -n "$why" ] || continue
    last_probe=$(date +%s)
    if probe_alive; then
      static=0
      fails=0
      first_fail=0
      # A live pointer is the health signal instant-restore trusts: reopen the
      # restore budget so a LATER relaunch may restore again.
      rm -f "$D/.state-tries"
      continue
    fi
    fails=$((fails + 1))
    [ "$first_fail" -ne 0 ] || first_fail=$(date +%s)
    span=$(($(date +%s) - first_fail))
    llog "livewatch: pointer probe produced no change ($why, $fails/$LIVE_PROBE_FAILS," \
      "dead for ${span}s of ${LIVE_DEAD_MIN}s)"
    static=0
    [ "$fails" -ge "$LIVE_PROBE_FAILS" ] || continue
    [ "$span" -ge "$LIVE_DEAD_MIN" ] || continue
    if [ "$attempt" -ge "$LIVE_ATTEMPTS" ]; then
      llog "livewatch: guest unresponsive but relaunch budget exhausted, giving up"
      return 1
    fi
    if [ -n "$WATCH_UNIT" ] && ! systemctl is-active --quiet "$WATCH_UNIT"; then
      llog "livewatch: guest unresponsive but $WATCH_UNIT is not active — not relaunching"
      return 0
    fi
    attempt=$((attempt + 1))
    llog "livewatch: guest unresponsive; relaunching MAME (attempt $attempt/$LIVE_ATTEMPTS)"
    wlog "livewatch: guest unresponsive; relaunching MAME (attempt $attempt/$LIVE_ATTEMPTS)"
    if [ "$CAPTURE" = x11 ]; then
      DISPLAY="$DISP" import -window root "$D/livewatch-dead-$attempt.png" 2>/dev/null || true
    fi
    start_mame >>"$LLOG" 2>&1 || llog "livewatch: relaunch failed to start MAME"
    fails=0
    first_fail=0
    prev=""
    static=0
    sleep "$LIVE_GRACE"
    last_probe=$(date +%s)
  done
}

case "$MODE" in
  --bootwatch)
    bootwatch
    exit $?
    ;;
  --livewatch)
    livewatch
    exit $?
    ;;
  --mame-only)
    start_mame
    exit $?
    ;;
esac

# ---- full launch -----------------------------------------------------------
# Fresh start: never leave a second Xvfb/MAME/watchdog behind. A fresh service
# start also gets a fresh instant-restore budget.
rm -f "$D/.state-tries"
kill_pidfile "$D/bootwatch.pid"
kill_pidfile "$D/livewatch.pid"
kill_pidfile "$D/mame.pid"
kill_pidfile "$D/xvfb.pid"
kill_pidfile "$D/proxy.pid" # left by the dropped web proxy; reap it once
# NOTE: no `rm -f $XSOCK` here — deleting $DISP's socket evicts whoever owns it,
# which, if it is not us, is someone else's running rig. xvfb-alloc reaps our
# own leftovers, and a truly stale socket is reclaimed by the X server itself.

# 1) Xvfb — the framebuffer streamhost captures. Not started at all in shm mode:
# MAME has no window there, and an idle X server is part of the cost being cut.
if [ "$CAPTURE" != shm ]; then
  # PINNED display: the streamhost service is configured with SH_X11_DISPLAY, so
  # this tile cannot take whatever number is free. It is still claimed through
  # xvfb-alloc, which makes the claim atomic and — the point — makes a taken
  # $DISP a LOUD failure. The old code started Xvfb, then accepted "the socket
  # exists" as proof it was up; that test is equally satisfied by SOMEONE ELSE'S
  # server, so a stale or foreign :40 silently became this tile's stream.
  XVFB_ALLOC_LIB="${XVFB_ALLOC_LIB:-/usr/local/bin/xvfb-alloc}"
  # shellcheck disable=SC1090,SC1091 # box copy of scripts/lib/xvfb-alloc.sh
  source "$XVFB_ALLOC_LIB" || {
    echo "FATAL: cannot source the display allocator $XVFB_ALLOC_LIB" >&2
    exit 1
  }
  xvfb_alloc --display "${DISP#:}" --screen "$GEOM" --no-trap \
    --tag "tile-irix" --pidfile "$D/xvfb.pid" --log "$D/xvfb.log" || {
    cat "$D/xvfb.log" >&2 || true
    exit 1
  }
fi

# 2) MAME/IRIX.
start_mame || exit 1

# 3) Boot watchdog — a new generation token invalidates any older watchdog.
date +%s%N >"$D/bootwatch.gen"
wlog "launch: watchdog armed (attempts=$WATCH_ATTEMPTS interval=${WATCH_INTERVAL}s hits=$WATCH_BLACK_HITS)"
nohup bash "$0" --bootwatch >>"$WLOG" 2>&1 </dev/null &
echo "$!" >"$D/bootwatch.pid"

# 4) Guest-liveness watchdog — the safety net behind the DRC soft-interrupt fix.
# Shares the same generation token, so it stands down with the boot watchdog.
wlog "launch: livewatch armed (grace=${LIVE_GRACE}s interval=${LIVE_INTERVAL}s static=$LIVE_STATIC_HITS fails=$LIVE_PROBE_FAILS attempts=$LIVE_ATTEMPTS) — log: $LLOG"
nohup bash "$0" --livewatch >>"$LLOG" 2>&1 </dev/null &
echo "$!" >"$D/livewatch.pid"
