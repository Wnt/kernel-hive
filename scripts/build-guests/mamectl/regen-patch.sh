#!/bin/bash
# Regenerate ../mame-ctlsock.patch, byte-compatible with the house a/b -p1
# format the original was written in.
#
# The patch has two kinds of hunk and they come from different places:
#   - the three UPSTREAM files the module has to touch, as a/ (pristine) ->
#     b/ (edited). Both copies are needed because the edit is a diff against
#     stock MAME, and keeping the pristine side here means the patch can be
#     regenerated without a MAME checkout;
#   - the module's OWN sources, emitted whole against /dev/null straight from
#     src/, which is their single source of truth. They are deliberately NOT
#     duplicated under b/ -- two copies of a 2900-line file in one repo is an
#     invitation to edit the wrong one.
set -euo pipefail
cd "$(dirname "$0")"

OUT=../mame-ctlsock.patch
: >"$OUT"

emit() { # emit <relpath> [new]
  local rel="$1" old="a/$1" new="b/$1"
  if [ "${2:-}" = "new" ]; then
    old=/dev/null
    new="$1" # module sources: straight from the source of truth
  fi
  printf 'diff -ruN mame-src-pristine/%s mame-src/%s\n' "$rel" "$rel" >>"$OUT"
  diff -u --label "a/$rel" --label "b/$rel" "$old" "$new" >>"$OUT" && {
    echo "no diff for $rel" >&2
    exit 1
  }
  true
}

emit scripts/src/osd/modules.lua
emit src/osd/modules/lib/osdobj_common.cpp
emit src/emu/save.cpp
emit src/osd/modules/ctlsock/ctlsock.h new
emit src/osd/modules/ctlsock/ctlsock.cpp new

wc -l "$OUT"
