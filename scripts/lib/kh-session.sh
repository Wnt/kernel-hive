#!/usr/bin/env bash
# kh-session.sh — ONE identity per working session, sourced by every tool.
#
# Every rig dir, display, VMID, socket, claim and staging slot on labhost is
# tagged with $KH_SESSION so that "whose is this?" is a lookup (`labctl who`),
# not /proc forensics (2026-08-17: ~9 min / 20 tool calls per hunt).
#
# Resolution order (first hit wins):
#   1. $KH_SESSION already exported
#   2. .kh-session file at the git toplevel (written by scripts/dev/wt.sh)
#   3. the git branch name when the checkout is a worktree (not main)
#   4. $CLAUDE_JOB_DIR basename (background jobs)
#   5. <hostname>-<user>  (fallback: not unique, and `labctl who` says so)
#
# Value charset is [a-z0-9-], max 24 chars: it lands in dir names, unit
# names, Xvfb display registry keys and JSON.
#
# usage:  . scripts/lib/kh-session.sh   (exports KH_SESSION)
#         scripts/lib/kh-session.sh     (prints it)

kh_session_sanitize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//' | cut -c1-24
}

kh_session_resolve() {
  local top branch v
  if [ -n "${KH_SESSION:-}" ]; then
    kh_session_sanitize "$KH_SESSION"
    return
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ] && [ -f "$top/.kh-session" ]; then
    v="$(head -1 "$top/.kh-session")"
    [ -n "$v" ] && {
      kh_session_sanitize "$v"
      return
    }
  fi
  branch="$(git -C "${top:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -n "$branch" ] && [ "$branch" != "main" ] && [ "$branch" != "HEAD" ]; then
    kh_session_sanitize "$branch"
    return
  fi
  if [ -n "${CLAUDE_JOB_DIR:-}" ]; then
    kh_session_sanitize "job-$(basename "$CLAUDE_JOB_DIR")"
    return
  fi
  kh_session_sanitize "$(hostname -s 2>/dev/null || echo host)-${USER:-u}"
}

KH_SESSION="$(kh_session_resolve)"
export KH_SESSION

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  printf '%s\n' "$KH_SESSION"
fi
