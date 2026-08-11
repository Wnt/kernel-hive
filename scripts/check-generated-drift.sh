#!/usr/bin/env bash
# scripts/check-generated-drift.sh — the generated-file drift gate.
#
# Every generated artifact (see generated() in scripts/tiles-registry.py) must be
# byte-identical to what its typed registry source + templates produce right now.
# The RENDERED artifacts (rendered(): the serve JSONs, the public lineup, the
# registry aggregate) are deliberately absent — they are never committed, so
# there is no second copy to drift. `make tile-registry-check` proves they still
# render.
# This catches a generated file that has gone stale vs its source/template — the
# exact failure that bites during re-bakes and station edits.
#
# Authoritative check: `make tile-registry-check` renders every output in memory
# and byte-compares it against the tree (non-mutating — safe in a pre-push hook).
#
# With --regen it additionally regenerates on disk and asserts
# `git diff --exit-code` over the generated paths — the literal
# "regenerate leaves the tree byte-clean" form CI runs on a clean checkout.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Generated artifacts, kept in lockstep with generated() in scripts/tiles-registry.py.
GENERATED_PATHS=(
  streamhost/tiles-manifest.sh
  streamhost/bring-up-all.sh
  scripts/build-guests/build-all.sh
  spa/src/three/archetypeRegistry.ts
  spa/src/data/posterIndex.ts
  spa/src/data/demoPrograms.ts
  spa/src/data/keyboards.ts
  registry/generated/labctl-declarations.json
)

echo "== generated-file drift: make tile-registry-check (byte parity) =="
make tile-registry-check

if [[ "${1:-}" == "--regen" ]]; then
  echo "== generated-file drift: regenerate + git diff --exit-code =="
  make tile-registry-generate >/dev/null
  if ! git diff --exit-code -- "${GENERATED_PATHS[@]}"; then
    echo "DRIFT: generated artifacts changed after 'make tile-registry-generate'." >&2
    echo "       Run 'make tile-registry-generate' and commit the result." >&2
    exit 1
  fi
fi

echo "generated-file drift gate: OK"
