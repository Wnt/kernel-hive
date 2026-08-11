#!/usr/bin/env bash
# Emit the shell scripts that are eligible for shfmt/shellcheck.
#
# SCOPE depends on the CONTEXT, and the difference is load-bearing (the same
# split as scripts/check-file-size.mjs --committed):
#
#   (no flag)     tracked ∪ staged ∪ (untracked ∧ not-ignored)
#                 pre-commit, direct invocation, CI. A tracked-only list means a
#                 BRAND NEW script is unlinted right up until the commit that
#                 makes it tracked, so its first CI run is its first lint — a
#                 silent pass before the commit, a red `main` after it.
#   --committed   tracked ∪ staged, i.e. the state being pushed. The pre-push
#                 hook uses this (and narrows further to the pushed range):
#                 blocking a push on a SIBLING agent's untracked in-flight file
#                 is a failure the pusher cannot fix, and an unfixable gate
#                 teaches SKIP_GATE=1.
#
# `--others --exclude-standard` honours .gitignore, .git/info/exclude and the
# global excludes, so node_modules/, build output and scratch dirs stay
# invisible. On a clean CI checkout every variant is the tracked set.
#
# EXCLUDES generated shell files (produced by scripts/stations-registry.py). Those
# are verified by the generated-file drift gate (they must match the generator
# byte-for-byte); the generator's output is not hand-formatted, so linting them
# would fight the drift gate. Keep this list in lockstep with the GENERATED set
# in scripts/check-file-size.mjs and generated() in scripts/stations-registry.py.
set -euo pipefail

MODE=(--cached --others --exclude-standard)
case "${1:-}" in
  --committed) MODE=(--cached) ;;
  "") ;;
  *)
    echo "shell-sources: unknown argument: $1" >&2
    exit 2
    ;;
esac

git ls-files "${MODE[@]}" '*.sh' \
  ':(exclude)scripts/build-guests/build-all.sh' \
  ':(exclude)streamhost/stations-manifest.sh' \
  ':(exclude)streamhost/bring-up-all.sh' |
  sort -u
