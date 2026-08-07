#!/usr/bin/env bash
# scripts/lib/local-env.sh — sourceable helper: load registry/local.env.
#
# This repo was scrubbed for public release: real operator values (LAN IP,
# hostname, public domains) were replaced with RFC 5737 / documentation
# placeholders (192.0.2.10, labhost, example.com, ...). Every tool keeps that
# placeholder as its DEFAULT so a fresh public clone works and
# `make tile-registry-check` stays deterministic. The operator's real values
# live only in the gitignored `registry/local.env` on the box (copy of
# `registry/local.env.example`) and are picked up at run/deploy time only.
#
# Precedence (highest wins): explicit CLI flag or a pre-set environment
# variable > registry/local.env > the tool's own placeholder default.
#
# Usage: source this file near the top of a script — before or after CLI flag
# parsing, order does not matter, because it only fills in a variable that is
# still UNSET. A CLI flag that already assigned the variable, or a pre-set
# environment variable, is never overwritten. Apply the usual
# `${VAR:-placeholder}` fallback afterward for the no-local.env case.
#
#   # shellcheck disable=SC1091
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/local-env.sh"
#   HOST="${HOST:-192.0.2.10}"
#
# Missing registry/local.env is NOT an error: this is a no-op on a fresh
# public clone, and every existing "${VAR:-default}" fallback still applies.

_local_env_repo_root() {
  # Walk up from this file's directory to find the repo root (contains
  # registry/local.env.example). Works regardless of the caller's cwd.
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  echo "$dir"
}

local_env_load() {
  local repo_root local_env key val line
  repo_root="$(_local_env_repo_root)"
  local_env="$repo_root/registry/local.env"
  [ -f "$local_env" ] || return 0

  # Parse simple KEY=VALUE lines ourselves (rather than a bare `.` source) so
  # a variable a caller already set — CLI flag or pre-set env var — is never
  # clobbered: registry/local.env only fills in what is still unset.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '' | '#'*) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    # Trim surrounding whitespace from the key.
    key="$(echo "$key" | tr -d '[:space:]')"
    [ -n "$key" ] || continue
    if [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done <"$local_env"
  return 0
}

local_env_load
