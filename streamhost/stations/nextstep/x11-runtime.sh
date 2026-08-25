#!/bin/bash
# x11-runtime.sh — the nextstep station launcher. HOST-NATIVE Previous.
#
# Despite the historical filename there is NO X here, and no QEMU: the daemon's
# ExecStartPre (streamhost/scripts/ensure-station-x11.sh) execs `$BASE/x11-runtime.sh`
# by that fixed name for every SH_STATION_RUNTIME=x11 station, so the name is a
# contract, not a description. This one runs the museum's fork of **Previous**
# (github.com/Wnt/previous, branch kernel-hive) as a COLOUR NeXTstation under
# SDL's dummy video and audio drivers — no X server, no window, no kiosk guest —
# and publishes its three planes straight to the daemon:
#
#   frames   PREVIOUS_SHM_PATH  -> SH_CAPTURE=shm     (IFB1, real dirty rect)
#   input    PREVIOUS_CTL_SOCK  -> SH_INPUT_BACKEND=mamesock (mamectl/1 verbatim)
#   audio    PREVIOUS_AUDIO_FIFO-> SH_AUDIO_SOURCE=fifo (48k s16le stereo)
#
# RESET IS A CRIU RESTORE. NeXTSTEP's root is UFS and a hard-killed one is not
# to be trusted, and there is no vmstate snapshot to `loadvm` — so
# `SH_RESET_MODE=relaunch` (systemctl restart streamhost@nextstep) lands here,
# and a launch restores the golden CRIU image against its PAIRED disk instead of
# cold-booting. A cold boot is the bounded fallback only, and it is a DEGRADED
# exhibit (see COLD BOOT, below), which is why the budget is loud.
#
# Everything here is namespaced through env so a bring-up rig can run the same
# file against a clone; nothing defaults to a live path except $BASE, which
# systemd sets by station name.
#
#   x11-runtime.sh            full launch (restore if possible, else cold boot)
#   x11-runtime.sh --cold     force a cold boot (bring-up / re-bake)
#   x11-runtime.sh --config   write cfg/previous.cfg and exit (bake tooling)
set -u

D="$(cd "$(dirname "$0")" && pwd)" # the station's runtime dir
BASE="${NEXTSTEP_BASE:-$D}"
ASSETS="${NEXTSTEP_ASSETS:-/data/vms/streamhost/assets/nextstep}"
BIN="${NEXTSTEP_BIN:-$ASSETS/previous}"
ROM="${NEXTSTEP_ROM:-$ASSETS/Rev_2.5_v66.BIN}"
COLD_DISK="${NEXTSTEP_COLD_DISK:-$ASSETS/NS33.dd}"
STATE="${NEXTSTEP_STATE:-golden}" # empty = always cold boot
STATE_DIR="${NEXTSTEP_STATE_DIR:-$ASSETS/state}"
# Everything the EMULATOR creates or writes lives in one directory owned by the
# unprivileged account; everything root installs (this script, the keymap,
# rn-tapnet.sh, station.env) stays root-owned one level up. The station dir
# itself is never chowned: it is on a root ExecStartPre path, and an account
# that can replace a file in it owns the box.
RUN="$BASE/run"
DISK="$RUN/disk.dd"
# Previous has NO command-line option for its config file: `sConfigFileName` is
# always $HOME/.config/previous/previous.cfg (configuration.c, File_MakePathBuf),
# and a `-c <file>` argument is accepted by getopt and then ignored. Worse, when
# that file does NOT exist main.c falls into the interactive config dialog, which
# under SDL's dummy video driver is an event loop nobody can ever answer: the
# process lives, the control socket listens, no memory is ever mapped and no
# frame is ever published. So HOME is the run dir and the config goes exactly
# where Previous will look for it.
CFG="$RUN/.config/previous/previous.cfg"
PIDFILE="$BASE/mame.pid" # the name ensure/stop-station-x11.sh use
LOG="$RUN/previous.log"

# The three planes. Read the daemon's own knobs so producer and consumer cannot
# disagree, exactly as the MAME stations do.
# fb.shm and audio.fifo sit in the station dir, where the emit puts SH_SHM_PATH
# and where every other station keeps them; the emulator cannot create files
# there (it is not allowed to write a directory on a root ExecStartPre path), so
# the launcher creates them and hands them over by owner. ctl.sock is the one
# the emulator must BIND itself, and binding needs a writable directory: $RUN.
SHM="${SH_SHM_PATH:-$BASE/fb.shm}"
CTL="${SH_MAMECTL_SOCK:-$RUN/ctl.sock}"
AFIFO="${SH_AUDIO_FIFO:-$BASE/audio.fifo}"

# The unprivileged account the emulator runs as. This is NOT hygiene theatre:
# SDL3's dummy video driver still opens /dev/input/event* and /dev/input/mouse0
# for its evdev input source, and **criu cannot dump a character-device fd** —
# `Can't dump file 4 of that type [20660] (chr 13:65)`, and `--external dev[…]`
# does not rescue an already-open one. Those nodes are root:input 0660, so an
# account outside the `input` group simply never opens them and the checkpoint
# becomes possible. Same shape as MAME's `/dev/snd/seq` + `-midiprovider none`
# (scripts/build-guests/irix/irix-criu/README.md).
RUNAS="${NEXTSTEP_USER:-nsexhibit}"

# The retronet link. A VETH PAIR in a private netns, not a tap: criu cannot dump
# a tap whose fd lives outside the dump set. rn-tapnet.sh is idempotent BY
# REQUIREMENT — it is the post-restore hook as well as the first-time setup.
NET="${NEXTSTEP_NET:-on}"
RN_NS="${RN_NS:-nextstep-rn}"
RN_VETH_OUT="${RN_VETH_OUT:-nextrn0}"
RN_VETH_INN="${RN_VETH_INN:-nextrn1}"
TAPNET="${NEXTSTEP_TAPNET:-$BASE/rn-tapnet.sh}"

# Machine. The DECIDED configuration is a non-Turbo NeXTstation Color, 32 MB,
# stock Rev 2.5 v66 ROM — docs/lab/research/nextstep-color-machine.md. bNBIC and
# the 8 MB bank quantum are FORCED by Previous on NEXT_STATION; they are written
# out as the corrected values so the file on disk is the truth.
MACHINE="${NEXTSTEP_MACHINE:-2}"
COLOR="${NEXTSTEP_COLOR:-TRUE}"
BANK="${NEXTSTEP_BANK_MB:-8}"
# The guest's MAC. Every Previous instance ships 00:00:0f:00:f3:02, so a second
# host-native NeXT on this bridge without a custom MAC is a guaranteed L2
# collision. bUseCustomMac rewrites the low three bytes of the ROM image and
# recomputes its checksum, which is what makes this safe; the NeXT OUI stays.
MAC3="${NEXTSTEP_MAC3:-82}"
MAC4="${NEXTSTEP_MAC4:-78}"
MAC5="${NEXTSTEP_MAC5:-25}"

# Injector pacing. PREVIOUS_CTL_BTN_HOLD is a FLOOR on how long a button stays
# down, because a ~12 ms press on this hardware is sampled away entirely. It is
# also a CEILING on double-click: two presses cost 2*hold, and NeXTSTEP stops
# calling them a double click somewhere near half a second, so the fork's own
# 400 ms default makes a visitor unable to open anything from the File Viewer.
# 200 ms is the measured middle: single clicks land, double clicks open.
BTN_HOLD="${PREVIOUS_CTL_BTN_HOLD:-200}"
# Set by the launch path: 1 when this launch restored the golden, 0 on a cold
# boot. arm_standby reads it.
LAUNCHED_RESTORE=0
STANDBY_DELAY_S="${NEXTSTEP_STANDBY_DELAY_S:-8}"

msg() { echo "nextstep: $*"; }
die() {
  echo "nextstep: FATAL $*" >&2
  exit 1
}

# ---------------------------------------------------------------- config ----
write_cfg() {
  mkdir -p "$(dirname "$CFG")"
  cat >"$CFG" <<EOF
[Log]
nTextLogLevel = 1
nAlertDlgLogLevel = 0
bConfirmQuit = FALSE
bConsoleWindow = FALSE

[ConfigDialog]
bShowConfigDialogAtStartup = FALSE

[Screen]
nMode = 0
bFullScreen = FALSE
bShowStatusbar = FALSE
bShowTitlebar = FALSE

[Keyboard]
bSwapCmdAlt = FALSE
nKeymapType = 0

[Mouse]
bEnableAutoGrab = FALSE
bEnableMapToKey = FALSE
bEnableMacClick = FALSE
bUseRawMotion = FALSE
fLinScale = 1.0
fExpScale = 1.0

[Tablet]
nTabletType = 2

[Sound]
bEnableMicrophone = FALSE
bEnableSound = TRUE

[Memory]
nMemoryBankSize0 = $BANK
nMemoryBankSize1 = $BANK
nMemoryBankSize2 = $BANK
nMemoryBankSize3 = $BANK
nMemorySpeed = 3

[Boot]
nBootDevice = 1
bEnableDRAMTest = FALSE
bEnablePot = FALSE
bEnableSoundTest = FALSE
bEnableSCSITest = FALSE
bLoopPot = FALSE
bVerbose = FALSE
bExtendedPot = FALSE
bVisible = TRUE

[HardDisk]
szImageName0 = $DISK
nDeviceType0 = 1
bDiskInserted0 = TRUE
bWriteProtected0 = FALSE
nWriteProtection = 0

[MagnetoOptical]
bDriveConnected0 = FALSE
bDriveConnected1 = FALSE

[Floppy]
bDriveConnected0 = FALSE
bDriveConnected1 = FALSE

[Ethernet]
bEthernetConnected = $([ "$NET" = on ] && echo TRUE || echo FALSE)
bTwistedPair = TRUE
nHostInterface = 1
szInterfaceName = $RN_VETH_INN
bNetworkTime = FALSE

[ROM]
szRom040FileName = $ROM
bUseCustomMac = TRUE
nRomCustomMac0 = 0
nRomCustomMac1 = 0
nRomCustomMac2 = 15
nRomCustomMac3 = $MAC3
nRomCustomMac4 = $MAC4
nRomCustomMac5 = $MAC5

[Printer]
bPrinterConnected = FALSE

[System]
nMachineType = $MACHINE
bColor = $COLOR
bTurbo = FALSE
bNBIC = FALSE
bADB = FALSE
nSCSI = 1
nRTC = 0
nCpuLevel = 4
nCpuFreq = 25
bCompatibleCpu = TRUE
bRealtime = TRUE
nDSPType = 2
bDSPMemoryExpansion = TRUE
n_FPUType = 68040
bCompatibleFPU = TRUE
bMMU = TRUE
EOF
}

# ----------------------------------------------------------------- user ----
ensure_user() {
  id "$RUNAS" >/dev/null 2>&1 && return 0
  msg "creating the unprivileged emulator account $RUNAS"
  useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$RUNAS" ||
    die "could not create $RUNAS"
  id -nG "$RUNAS" | tr ' ' '\n' | grep -qx input &&
    die "$RUNAS is in group 'input'; SDL would open /dev/input and criu could not dump it"
}

# ------------------------------------------------------------------ kill ----
# Resolve by /proc/<pid>/exe, NEVER by cmdline: a cmdline sweep matches this
# very script and, over ssh, the session running it (AGENTS.md rule 5).
reap() {
  local d p e n=0
  for d in /proc/[0-9]*; do
    p="${d#/proc/}"
    e="$(readlink "$d/exe" 2>/dev/null)" || continue
    e="${e% (deleted)}"
    [ "$e" = "$BIN" ] || continue
    # A standby emulator is SIGSTOPped and would never run to handle TERM.
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
    for _ in $(seq 40); do
      [ -e "/proc/$p" ] || break
      sleep 0.25
    done
    [ -e "/proc/$p" ] && kill -KILL "$p" 2>/dev/null || true
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] && msg "reaped $n previous publisher(s)"
  rm -f "$PIDFILE"
  return 0
}

# ------------------------------------------------------------------- net ----
net_up() {
  [ "$NET" = on ] || return 0
  RN_NS="$RN_NS" bash "$TAPNET" up || die "rn-tapnet.sh up failed"
}

# criu installs its own CRIU chain inside the netns for the duration of a dump or
# restore and removes it on the way out. An ABORTED restore leaves it behind and
# the guest is then silently network-dead behind a perfectly healthy desktop.
sweep_criu_chain() {
  [ "$NET" = on ] || return 0
  [ -e "/run/netns/$RN_NS" ] || return 0
  local t
  for t in iptables ip6tables; do
    nsenter --net="/run/netns/$RN_NS" "$t" -S 2>/dev/null | grep -q '^-N CRIU' || continue
    nsenter --net="/run/netns/$RN_NS" "$t" -D INPUT -j CRIU 2>/dev/null || true
    nsenter --net="/run/netns/$RN_NS" "$t" -D OUTPUT -j CRIU 2>/dev/null || true
    nsenter --net="/run/netns/$RN_NS" "$t" -F CRIU 2>/dev/null || true
    nsenter --net="/run/netns/$RN_NS" "$t" -X CRIU 2>/dev/null || true
    msg "swept a leftover CRIU $t chain in netns $RN_NS"
  done
}

# --------------------------------------------------------------- restore ----
# Every guard below is a LOUD cold-boot fallback. A restore that cannot be
# proven valid must not be attempted: golden + binary + device set are ONE
# combination, and a wrong triple restores, renders a plausible frame and is
# wrong in ways no health check sees.
restore_eligible() {
  local s="$STATE_DIR/$STATE" tries
  [ -n "$STATE" ] || return 1
  tries="$(cat "$BASE/.state-tries" 2>/dev/null || echo 0)"
  if [ "$tries" -ge 2 ]; then
    msg "restore: $tries restore launches without a healthy guest — COLD BOOT fallback"
    return 1
  fi
  if [ ! -d "$s/img" ] || [ ! -f "$s/disk-golden.dd" ]; then
    msg "restore: state '$STATE' assets missing under $s — COLD BOOT"
    return 1
  fi
  if ! grep -q "^$(md5sum "$BIN" | cut -d' ' -f1) " "$s/provenance.md5" 2>/dev/null; then
    msg "restore: emulator md5 not in $s/provenance.md5 (a rebuild orphans every image) — COLD BOOT"
    return 1
  fi
  return 0
}

do_restore() {
  local s="$STATE_DIR/$STATE" p
  echo $(($(cat "$BASE/.state-tries" 2>/dev/null || echo 0) + 1)) >"$BASE/.state-tries"
  sweep_criu_chain
  # The PAIRED disk — the reflink taken inside the very freeze window the memory
  # image was written in. A mismatched (memory, disk) pair is invisible to criu,
  # to the guest and to fsck, so safety is construction, never detection.
  rm -f "$DISK"
  cp --reflink=always "$s/disk-golden.dd" "$DISK" || die "paired disk reflink failed"
  chown "$RUNAS" "$DISK"
  # …and the log, whose SIZE criu validates on every regular-file fd.
  cp "$s/previous.log" "$LOG" 2>/dev/null || : >"$LOG"
  chown "$RUNAS" "$LOG"
  # NEVER delete and re-create $SHM here. The restored process keeps its old
  # mapping, so a fresh file at the same path restores fine and streams a FROZEN
  # PICTURE FOREVER — the header is written only on the emulator's own mmap path,
  # which restore bypasses.
  rm -f "$PIDFILE"
  # criu OWNS the veth pair across a restore: it was dumped as
  # `--external veth[inner]:outer`, and restore RE-CREATES it. Delete the pair
  # net_up just built, or the re-creation fails with EEXIST; net_up runs again
  # afterwards to re-enslave, re-address and re-arm the guard chain on the bare
  # host end (~90 ms, idempotent by requirement).
  local ext=()
  if [ "$NET" = on ]; then
    ip link del "$RN_VETH_OUT" 2>/dev/null || true
    ext=(--external "veth[$RN_VETH_INN]:$RN_VETH_OUT")
  fi
  criu restore -D "$s/img" -o restore.log -d --shell-job --file-locks \
    --manage-cgroups=ignore --join-ns "net:/run/netns/$RN_NS" \
    "${ext[@]}" --pidfile "$PIDFILE" || {
    msg "restore FAILED:"
    grep -iE '^Error' "$s/img/restore.log" 2>/dev/null | tail -8 >&2
    sweep_criu_chain
    return 1
  }
  p="$(cat "$PIDFILE")"
  # criu restores the process in its job-control stop — it was SIGSTOPped for the
  # bake and it comes back that way. Nothing else wakes it.
  kill -CONT "$p" 2>/dev/null || true
  # criu deletes and re-creates the veth pair, with a new ifindex, and the host
  # end comes back BARE: no bridge port, no guard chain. ~90 ms, idempotent.
  net_up
  # The golden was baked with the HOST side of the NIC closed, because criu
  # cannot dump libpcap's AF_PACKET socket. Reopen it now, against the veth
  # rn-tapnet.sh has just re-established. The guest never knew.
  for _ in $(seq 1 20); do
    [ -S "$CTL" ] && break
    sleep 0.5
  done
  # One verb through the control socket both re-opens the NIC and VETS the
  # restore: a mamectl verb is acknowledged by the EMULATION thread after it has
  # been applied, so an OK here means the restored 68k is actually running its
  # queue, not merely that a process exists. That is what clears the restore
  # budget; a restore that never gets this far leaves the counter standing and
  # the third launch cold-boots, loudly.
  # FBSYNC first, and unconditionally: criu never copies the shm mapping but DOES
  # carry the publisher's private diff shadow, so a restored emulator believes
  # the reader is already showing the baked frame and republishes nothing --
  # leaving whatever was on screen when the process was killed streaming
  # forever, under a live guest whose cursor still moves. One whole-frame
  # publish costs 3.7 MB and closes it.
  python3 "$BASE/ctl.py" "$CTL" FBSYNC || msg "WARNING: FBSYNC failed — the stream may show the PRE-RESET picture"
  if [ "$NET" = on ]; then
    if python3 "$BASE/ctl.py" "$CTL" NETUP; then
      rm -f "$BASE/.state-tries"
    else
      msg "WARNING: NETUP failed — the guest is restored but OFFLINE, and the restore is NOT vetted"
    fi
  else
    if python3 "$BASE/ctl.py" "$CTL" PING; then
      rm -f "$BASE/.state-tries"
    else
      msg "WARNING: the restored guest did not answer PING — restore NOT vetted"
    fi
  fi
  msg "restored state=$STATE pid=$p"
  return 0
}

# ------------------------------------------------------------- cold boot ----
# A cold boot is NOT the exhibit. NeXTSTEP's SummaGraphics kernel server is
# loaded by the /etc/rc.local hook the disk carries, but nothing puts the
# digitiser into stream mode on a plain boot — only /NextAdmin/InstallTablet.app
# does (measured on the colour slab, 2026-08-25) — so a cold-booted station has
# a DEAD-RECKONED pointer that is exact only at ~50 px/s. It also takes ~135 s.
# The golden carries the enabled tablet in both the guest and the emulator, which
# is why restore is the reset and this is only the bounded fallback.
do_cold() {
  msg "COLD BOOT (degraded: relative pointer until the golden is re-baked)"
  rm -f "$DISK"
  cp --reflink=auto "$COLD_DISK" "$DISK" || die "cold disk copy failed"
  chown "$RUNAS" "$DISK"
  : >"$LOG"
  chown "$RUNAS" "$LOG"
  # A COLD boot starts a fresh publisher, so the mapping is re-created from
  # scratch and handed over by owner. On the RESTORE path this must never
  # happen: criu keeps the restored process's old mapping, and a fresh file at
  # the same path restores fine and streams a frozen picture forever.
  rm -f "$SHM" "$CTL"
  install -o "$RUNAS" -m 640 /dev/null "$SHM"
  write_cfg
  chown -R "$RUNAS" "$RUN/.config"
  [ -p "$AFIFO" ] || {
    rm -f "$AFIFO"
    mkfifo -m 660 "$AFIFO"
  }
  chown "$RUNAS" "$AFIFO"
  local pre=()
  [ "$NET" = on ] && pre=(nsenter --net="/run/netns/$RN_NS")
  env -u DISPLAY -u SDL_VIDEODRIVER \
    HOME="$RUN" \
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    PREVIOUS_SHM_PATH="$SHM" \
    PREVIOUS_CTL_SOCK="$CTL" \
    PREVIOUS_AUDIO_FIFO="$AFIFO" \
    PREVIOUS_CTL_BTN_HOLD="$BTN_HOLD" \
    nohup "${pre[@]}" \
    setpriv --reuid="$RUNAS" --regid="$RUNAS" --clear-groups \
    --inh-caps=+net_raw,+net_admin --ambient-caps=+net_raw,+net_admin \
    "$BIN" >>"$LOG" 2>&1 &
  local p=$!
  echo "$p" >"$PIDFILE"
  sleep 5
  [ -e "/proc/$p" ] || {
    echo "PREVIOUS FAILED TO START:" >&2
    tail -30 "$LOG" >&2 || true
    return 1
  }
  msg "cold boot started pid=$p"
  return 0
}

# ----------------------------------------------------------------- ready ----
wait_planes() {
  local i
  for i in $(seq 1 60); do
    [ -S "$CTL" ] && [ -s "$SHM" ] && return 0
    sleep 1
  done
  msg "WARNING: ctl socket or framebuffer never appeared"
  return 1
}

# The daemon's idle pauser owns standby once it is serving, but it cannot pause
# during its own start-up grace, and an unwatched emulator burns a whole core.
# Freeze the guest ourselves shortly after launch; the first visitor session's
# unconditional cont (streamhost idle.rs) wakes it.
arm_standby() {
  [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] || return 0
  # Only after a RESTORE. A restore lands on the finished scene, so freezing it
  # 8 s later is exactly the QEMU fleet's `-loadvm golden -S`. A COLD boot is
  # 135 s of NeXTSTEP booting, and freezing that at 8 s means the fallback guest
  # makes no progress at all until someone visits — turning a slow exhibit into
  # a black one. (The daemon's own 60 s idle pause still applies to both.)
  [ "$LAUNCHED_RESTORE" = 1 ] || return 0
  [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ] || return 0
  (
    sleep "$STANDBY_DELAY_S"
    local p e
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    e="$(readlink "/proc/$p/exe" 2>/dev/null || true)"
    [ "${e% (deleted)}" = "$BIN" ] || exit 0
    kill -STOP "$p" 2>/dev/null || true
  ) >/dev/null 2>&1 &
}

# ------------------------------------------------------------------ main ----
case "${1:-}" in
  --config)
    write_cfg
    echo "$CFG"
    exit 0
    ;;
  --cold) STATE="" ;;
  "") : ;;
  *) die "unknown argument: $1" ;;
esac

[ -x "$BIN" ] || die "no emulator binary at $BIN"
ensure_user
mkdir -p "$RUN/.config/previous"
chown -R "$RUNAS" "$RUN" "$RUN/.config"
chmod 750 "$RUN"
# The emulator has to be able to TRAVERSE the station dir to reach $RUN. The
# live station dir is already 0755; a sandbox clone is typically 0700, and the
# symptom there is not "denied" anywhere useful — it is Previous logging
# `bind/listen … Permission denied` for the control socket and running on
# happily with no input plane at all. Execute-only grants no listing and no read.
chmod o+x "$BASE"

# …and be able to READ the immutable assets. This check exists because the
# failure without it is silent and expensive: Previous logs nothing about the
# ROM it cannot open, never maps memory, and sits at 1% of a core forever with
# a live control socket and no framebuffer — which reads exactly like a guest
# that is booting slowly.
as_runas() { setpriv --reuid="$RUNAS" --regid="$RUNAS" --clear-groups "$@"; }
for f in "$BIN" "$ROM" "$COLD_DISK"; do
  as_runas test -r "$f" || die "$RUNAS cannot read $f (check the o+x bits on every directory above it)"
done
reap
net_up
[ -p "$AFIFO" ] || {
  rm -f "$AFIFO"
  mkfifo -m 660 "$AFIFO"
}
chown "$RUNAS" "$AFIFO" 2>/dev/null || true

if restore_eligible && do_restore; then
  LAUNCHED_RESTORE=1
else
  do_cold || die "cold boot failed"
fi
wait_planes || true
arm_standby
msg "up: pid=$(cat "$PIDFILE" 2>/dev/null) shm=$SHM ctl=$CTL audio=$AFIFO net=$NET/$RN_NS reset=criu:$STATE"
