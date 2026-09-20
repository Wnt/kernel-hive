#!/usr/bin/env bash
# wt-live-pids.sh — list processes rooted (by cwd) under a wt.sh sandbox dir,
# excluding the scan's own process ancestry.
#
# WHY. wt.sh rm's live-process check runs itself via labrun/ssh, so its own
# invocation chain is a real process sitting in /proc with a cwd the caller
# may well have set to the very sandbox being torn down (the normal workflow
# is `cd $repo` right after `wt.sh new`, per its own "next: cd $repo" hint).
# CT950 is an LXC container with its own PID namespace, so a pid the caller
# computes locally (e.g. $$) is NOT the number this scan sees for that same
# task on labhost's side (a process cannot learn its own host-visible pid —
# that is a deliberate namespace boundary) — passing $$ across does not work,
# confirmed by tracing a live repro: `caller $$=2148906` locally corresponded
# to host-visible pid 1776532, not the pid a caller-side computation could
# ever predict. And walking the SCAN's own ancestor chain doesn't reach it
# either — labrun's ssh is a fresh network connection, not a fork of it, so
# they share no ancestor short of pid 1 (see scripts/dev/wt.sh's own $$
# ancestry, an unrelated branch through `claude`/`screen`/`lxc-start`).
#
# So this scan excludes by WHAT a candidate is, not who spawned it: a bare
# shell or the ssh transport itself is never the "live work" rule 4 exists to
# protect (a running emulator, build or editor) — it is inherently this
# check's own delivery mechanism, or an idle `cd`'d shell with nothing at
# stake beyond what the uncommitted-changes check (wt.sh's own next check)
# already covers. Reproduced live 2026-09-20: `wt.sh rm` on an idle sandbox,
# reached only by `cd $repo && wt.sh rm <name>`, reported exactly a
# bash/bash/ssh triple and refused every attempt; a raw scan moments later
# (after that invocation's own transient ssh session had closed) found
# nothing — proof the "live processes" were the check's own passage, not a
# guest. A genuine live guest (qemu-system-*, mame, cargo, an editor, ...)
# has a different exe and is still reported.
#
# Resolves processes via /proc/<pid>/cwd and /proc/<pid>/exe ONLY, never a
# cmdline grep (AGENTS.md rule 5 — a cmdline substring match can catch this
# very ssh session, or a bystander's, and instruct a caller to kill it).
#
# usage: wt-live-pids.sh <sandbox-root> <name>
# stdout: one line per live pid found: "<pid> <exe> cwd=<cwd>"
set -uo pipefail

root="${1:?sandbox root required}"
name="${2:?sandbox name required}"
d="$root/$name"
# Where labrun leaves the script it ships; overridable so the selftest can
# simulate the delivery chain without writing to /run.
labrun_dir="${KH_LABRUN_DIR:-/run/kh-labrun}"

# This scan's own ancestor chain (its sshd session and whatever spawned it) —
# cheap, harmless self-protection for the rare case the remote side's own
# cwd happens to match (e.g. an inherited $HOME under the sandbox).
declare -A skip=()
pid=$$
while [ -n "$pid" ] && [ "$pid" != 0 ] && [ -z "${skip[$pid]:-}" ]; do
  skip[$pid]=1
  ppid="$(awk '/^PPid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)"
  [ -n "$ppid" ] && [ "$ppid" != "$pid" ] || break
  pid="$ppid"
done

for p in /proc/[0-9]*; do
  pid="${p#/proc/}"
  [ -n "${skip[$pid]:-}" ] && continue
  cwd="$(readlink "$p/cwd" 2>/dev/null)" || continue
  case "$cwd" in
    "$d" | "$d"/*)
      exe="$(readlink "$p/exe" 2>/dev/null)"
      case "$exe" in
        # The ssh transport is never the work rule 4 protects -- it IS this
        # check's own passage to the box.
        */ssh | */sshd | */sshd-session) continue ;;
        # A shell is only excluded when it is demonstrably a labrun-shipped
        # script: bash keeps the script it is executing on fd 255, and labrun
        # leaves that script under /run/kh-labrun/<session>/. Excluding every
        # shell instead would delete a sandbox out from under a running
        # `bash build-mame-native.sh` -- a real 30-minute build observed on
        # 2026-09-20 -- whenever it sat between compiler invocations with no
        # non-shell child to give it away. Identity by fd, never a cmdline
        # grep (AGENTS.md rule 5).
        */bash | */sh | */dash)
          script="$(readlink "$p/fd/255" 2>/dev/null)"
          case "$script" in
            "$labrun_dir"/*) continue ;;
          esac
          ;;
      esac
      echo "$pid $exe cwd=$cwd"
      ;;
  esac
done
