#!/usr/bin/env bash
# =============================================================================
# build-guests/lib/bridge-suite.sh — sourceable resolver for the gradual
# bookworm -> trixie migration of the emulator-bridge guest base.
#
# WHY THIS EXISTS. The lab host is Debian 13 (trixie); the shared bridge guest
# base is still Debian 12 (bookworm) and ~29 stations overlay it read-only. The
# base cannot be migrated in one shot -- every overlay would have to be rebuilt,
# re-baked and re-accepted on the same day, and several stations need real work
# first (docs/lab/BRIDGE-TRIXIE-MIGRATION.md). So TWO bases coexist and each
# station declares which one it is built on, in registry/bridge-suites.json.
#
# The bookworm base keeps its ORIGINAL path (/data/vms/bridge/bridge-base.qcow2)
# so every existing overlay's recorded backing file stays valid byte-for-byte.
# The trixie base is a NEW file beside it. Nothing about an unmigrated station
# changes.
#
# USAGE (from any build script):
#
#   # shellcheck disable=SC1091
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-suite.sh"
#
#   suite="$(bridge_suite_for atarist)"          # -> bookworm | trixie
#   base="$(bridge_base_for "$suite")"           # -> /data/vms/bridge/...qcow2
#   chroot="$(bridge_mame_chroot_for "$suite")"  # -> ABI-matched MAME chroot
#
# Every function FAILS LOUDLY (non-zero + stderr) on an unknown station, an unknown
# suite, or a malformed ledger. There is deliberately no silent fallback: a
# build that cannot tell which Debian it is targeting must not guess, because
# the failure mode is a binary that loads on the host and dies in the guest with
# `GLIBC_2.xx not found` only once the station is live.
#
# OVERRIDE for experiments: set BRIDGE_SUITE=trixie in the environment to force
# a suite for one build without editing the ledger. Intended for a clone under
# /data/vms/soltest/ while migrating a station; never for a production re-bake --
# the ledger and the box must agree, and scripts/dev/bridge-suite-status.sh is
# what proves they do.
# =============================================================================

bridge_suite_ledger() {
  # The ledger lives in the repo, next to registry/local.env. Resolve it from
  # this file's own location so the caller's cwd is irrelevant.
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  echo "$dir/registry/bridge-suites.json"
}

# _bridge_suite_query <verb> [arg…]
# Internal. Uses python3 (always present on the box and in CI) rather than jq,
# which is not a declared dependency anywhere else in build-guests/. Verbs are
# a fixed, explicit set -- deliberately not an eval'd expression, so a caller
# typo is a clean "unknown verb" instead of an arbitrary lookup that silently
# yields the wrong path.
#
# Prints the value and exits 0, or prints a diagnostic to stderr and exits 1.
# A missing key is ALWAYS an error, never an empty string, because "" would
# otherwise flow into a qemu-img backing-file argument.
_bridge_suite_query() {
  local ledger
  ledger="$(bridge_suite_ledger)"
  [ -f "$ledger" ] || {
    echo "bridge-suite: ledger not found: $ledger" >&2
    return 1
  }
  python3 - "$ledger" "$@" <<'PY'
import json
import sys

path, verb, args = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, ValueError) as exc:
    sys.exit(f"bridge-suite: cannot parse {path}: {exc}")

for key in ("defaultSuite", "suites", "tiles"):
    if key not in doc:
        sys.exit(f"bridge-suite: {path} is missing required key {key!r}")
suites, tiles = doc["suites"], doc["tiles"]

if verb == "default":
    print(doc["defaultSuite"])
elif verb == "suites":
    print("\n".join(sorted(suites)))
elif verb == "has-suite":
    # Exit status IS the answer; print nothing.
    sys.exit(0 if args[0] in suites else 1)
elif verb == "tile-suite":
    if args[0] not in tiles:
        sys.exit(f"bridge-suite: tile {args[0]!r} is not in the ledger")
    print(tiles[args[0]])
elif verb == "field":
    suite, field = args
    if suite not in suites:
        sys.exit(f"bridge-suite: unknown suite {suite!r}")
    if field not in suites[suite]:
        sys.exit(f"bridge-suite: suite {suite!r} has no {field!r}")
    value = suites[suite][field]
    print("true" if value is True else "false" if value is False else value)
elif verb == "tiles":
    wanted = args[0] if args else None
    print("\n".join(sorted(t for t, s in tiles.items() if wanted in (None, s))))
else:
    sys.exit(f"bridge-suite: unknown verb {verb!r}")
PY
}

# bridge_suite_list — every suite name the ledger defines, one per line.
bridge_suite_list() {
  _bridge_suite_query suites
}

# bridge_suite_default — the suite a station gets when the ledger does not name it.
bridge_suite_default() {
  _bridge_suite_query default
}

# bridge_suite_for <tile> — the suite this station's overlay is built on.
# BRIDGE_SUITE in the environment wins, for experiment clones only.
bridge_suite_for() {
  local tile="${1:?bridge_suite_for: tile id required}" suite
  if [ -n "${BRIDGE_SUITE:-}" ]; then
    bridge_suite_assert "$BRIDGE_SUITE" || return 1
    echo "$BRIDGE_SUITE"
    return 0
  fi
  suite="$(_bridge_suite_query tile-suite "$tile")" || {
    echo "  Add '$tile' to registry/bridge-suites.json (bridge tiles only)," >&2
    echo "  or pass BRIDGE_SUITE= explicitly for an experiment clone." >&2
    return 1
  }
  bridge_suite_assert "$suite" || return 1
  echo "$suite"
}

# bridge_suite_assert <suite> — non-zero unless the ledger defines this suite.
bridge_suite_assert() {
  local suite="${1:?bridge_suite_assert: suite required}"
  _bridge_suite_query has-suite "$suite" || {
    echo "bridge-suite: unknown suite '$suite' (known: $(bridge_suite_list | tr '\n' ' '))" >&2
    return 1
  }
}

# _bridge_suite_field <suite> <field>
_bridge_suite_field() {
  local suite="${1:?}" field="${2:?}"
  bridge_suite_assert "$suite" || return 1
  _bridge_suite_query field "$suite" "$field"
}

# bridge_base_for <suite> — path of that suite's frozen base qcow2 on the box.
bridge_base_for() { _bridge_suite_field "$1" base; }

# bridge_mame_chroot_for <suite> — the chroot whose glibc/libstdc++ ABI matches
# that suite's guest, i.e. where a MAME/emulator binary destined for it must be
# built. On trixie this is the same generation as the host, so a host build
# would also work; the chroot keeps the build reproducible either way.
bridge_mame_chroot_for() { _bridge_suite_field "$1" mameChroot; }

# bridge_genericcloud_url_for <suite> — upstream Debian genericcloud qcow2.
bridge_genericcloud_url_for() { _bridge_suite_field "$1" genericcloudUrl; }

# bridge_debian_version_for <suite> — "12" / "13", for prose and assertions.
bridge_debian_version_for() { _bridge_suite_field "$1" debianVersion; }

# bridge_suite_is_frozen <suite> — true when rebuilding that base would break
# live overlays. Guards `bridge-base.sh --suite bookworm`.
bridge_suite_is_frozen() {
  local frozen
  frozen="$(_bridge_suite_field "$1" frozen)" || return 1
  [ "$frozen" = "true" ]
}

# bridge_suite_tiles [suite] — station ids, all of them or only those on <suite>.
bridge_suite_tiles() {
  if [ $# -eq 0 ]; then
    _bridge_suite_query tiles
  else
    bridge_suite_assert "$1" || return 1
    _bridge_suite_query tiles "$1"
  fi
}
