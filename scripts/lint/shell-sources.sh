#!/usr/bin/env bash
# Emit the tracked shell scripts that are eligible for shfmt/shellcheck.
#
# EXCLUDES generated shell files (produced by scripts/tiles-registry.py). Those
# are verified by the generated-file drift gate (they must match the generator
# byte-for-byte); the generator's output is not hand-formatted, so linting them
# would fight the drift gate. Keep this list in lockstep with the GENERATED set
# in scripts/check-file-size.mjs and generated() in scripts/tiles-registry.py.
git ls-files '*.sh' \
  ':(exclude)scripts/build-guests/build-all.sh' \
  ':(exclude)streamhost/tiles-manifest.sh' \
  ':(exclude)streamhost/bring-up-all.sh'
