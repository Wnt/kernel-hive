#!/usr/bin/env bash
# build-guests/lib/media-cache.sh — the persistent install-media archive.
#
# WHAT IT IS: a content-addressed, never-evicting store of every external build
# input, on its own ZFS dataset (`data/media-archive`, mounted
# /data/media-archive, quota 150 G). The rule it exists to enforce is one
# sentence: WE MUST NEVER NEED TO RE-FETCH AN INSTALL MEDIUM FROM ITS ORIGINAL
# SOURCE. Half these sources are already gone — every trailing-edge.com host is
# offline, and it is the archive that essentially every DEC howto links to.
#
# WHAT DEFECT IT REPLACES: `curl -fsSL -o X "$URL" || true`. That pattern is in
# lib/bridge-base.sh five times, and it is the actual bug — a rotted URL is
# silent and NON-FATAL, so a base built from a dead mirror reports success, the
# emulator media is simply absent, and the tile goes black weeks later with
# every log healthy. `media_cache_require` is the replacement, and its contract
# is the inversion of that:
#
#     cache hit                     -> use it, no network at all
#     cache miss, fetch ok          -> verify the pin, store it, use it
#     cache miss AND fetch fails    -> FAIL LOUDLY. Never a warning, never `|| true`.
#
# RELATIONSHIP TO docs/lab/ASSETS-MANIFEST.md: the manifest stays the INDEX OF
# RECORD — license class, provenance, the reasoning about redistribution. This
# store holds bits and the minimum metadata needed to find them again, and
# cross-references the manifest by hash. It does not duplicate the manifest, and
# a blob here is not a licence to redistribute anything: the classes in the
# manifest still govern (most of this is preservation-source and is a publish
# blocker).
#
# NEVER AUTO-EVICT. There is deliberately no LRU, no TTL, no size-based prune,
# and no `media_cache_rm`. This is an archive. Deletion is an explicit human act
# — see the CLI in check-media-cache.sh and the README written into the dataset.
#
# Usage (sourced):
#     . "$(dirname "$0")/../lib/media-cache.sh"
#     media_cache_require <pin> <dest> <label> [url…]
#         pin   sha256:<hex> or md5:<hex>  (content address is ALWAYS sha256)
#     media_cache_put <file> [label] [note]      # adopt an existing local file
#     media_cache_have <sha256> / media_cache_path <sha256>
set -uo pipefail

MEDIA_ARCHIVE_ROOT="${MEDIA_ARCHIVE_ROOT:-/data/media-archive}"

_mc_log() { echo "[media-cache] $*"; }
_mc_err() { echo "[media-cache] ERROR: $*" >&2; }

# _mc_sha256 <file>
_mc_sha256() { sha256sum -- "$1" 2>/dev/null | awk '{print $1}'; }
_mc_md5() { md5sum -- "$1" 2>/dev/null | awk '{print $1}'; }

# _mc_check_pin <file> <pin> — verify a sha256:/md5: pin. Empty pin => refuse:
# an unpinned blob cannot be verified on the way back out either, and this store
# exists precisely so that what we restore is what we archived.
_mc_check_pin() {
  local f="$1" pin="$2" algo want got
  if [ -z "$pin" ]; then
    _mc_err "no hash pin given for $f — refusing to archive an unverifiable blob"
    return 2
  fi
  algo="${pin%%:*}"
  want="${pin#*:}"
  case "$algo" in
    sha256) got="$(_mc_sha256 "$f")" ;;
    md5) got="$(_mc_md5 "$f")" ;;
    *)
      _mc_err "unknown hash algorithm '$algo' in pin '$pin'"
      return 2
      ;;
  esac
  [ "$got" = "$want" ] || {
    _mc_err "hash mismatch for $f: $algo want $want, got $got"
    return 1
  }
  return 0
}

# media_cache_path <sha256> — the content address. Two-level fan-out so a single
# directory never holds thousands of entries.
media_cache_path() {
  local h="$1"
  printf '%s/blobs/%s/%s' "$MEDIA_ARCHIVE_ROOT" "${h:0:2}" "$h"
}
media_cache_index_path() { printf '%s/index/%s.json' "$MEDIA_ARCHIVE_ROOT" "$1"; }
media_cache_have() { [ -s "$(media_cache_path "$1")" ]; }

# media_cache_verify <sha256> — the blob is present AND still hashes correctly.
media_cache_verify() {
  local h="$1" p
  p="$(media_cache_path "$h")"
  [ -s "$p" ] || return 1
  [ "$(_mc_sha256 "$p")" = "$h" ]
}

# media_cache_put <file> [label] [note] [url] — archive a file. Idempotent: an
# identical blob already present is left alone (it is mode 0444 and we do not
# rewrite it). Prints the sha256.
media_cache_put() {
  local f="$1" label="${2:-$(basename "$1")}" note="${3:-}" url="${4:-}" h p idx
  [ -s "$f" ] || {
    _mc_err "media_cache_put: $f is missing or empty"
    return 1
  }
  h="$(_mc_sha256 "$f")"
  [ -n "$h" ] || {
    _mc_err "media_cache_put: could not hash $f"
    return 1
  }
  p="$(media_cache_path "$h")"
  mkdir -p "$(dirname "$p")" "$MEDIA_ARCHIVE_ROOT/index"
  if [ -s "$p" ]; then
    _mc_log "already archived: $label ($h)"
  else
    # Write to a temp name in the SAME directory and rename: a reader can then
    # only ever see a complete blob, never a half-copied one.
    cp -- "$f" "$p.tmp.$$"
    chmod 0444 "$p.tmp.$$"
    mv -- "$p.tmp.$$" "$p"
    _mc_log "archived $label -> $h ($(stat -c %s "$p") bytes)"
  fi
  idx="$(media_cache_index_path "$h")"
  # The index entry accumulates every name/url a blob has been seen under, so a
  # file archived twice under different names stays findable by both.
  python3 - "$idx" "$h" "$p" "$label" "$note" "$url" <<'PY'
import json, os, sys, time
idx, h, path, label, note, url = sys.argv[1:7]
d = {"sha256": h, "size": os.path.getsize(path), "labels": [], "urls": [],
     "notes": [], "first_seen": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
if os.path.exists(idx):
    try:
        d.update({k: v for k, v in json.load(open(idx)).items() if k in d})
    except Exception:
        pass
for key, val in (("labels", label), ("urls", url), ("notes", note)):
    if val and val not in d[key]:
        d[key].append(val)
os.makedirs(os.path.dirname(idx), exist_ok=True)
tmp = idx + ".tmp"
json.dump(d, open(tmp, "w"), indent=1, sort_keys=True)
os.replace(tmp, idx)
PY
  printf '%s' "$h"
}

# media_cache_require <pin> <dest> <label> [url…] — THE resolver. See the
# contract in the header. Returns non-zero (and says why) if it cannot produce a
# verified <dest>; callers must NOT append `|| true`.
media_cache_require() {
  local pin="$1" dest="$2" label="$3"
  shift 3
  local algo want h p url tmp rc
  algo="${pin%%:*}"
  want="${pin#*:}"

  # A sha256 pin IS the content address, so a hit needs no fetch and no guess.
  if [ "$algo" = sha256 ] && media_cache_verify "$want"; then
    mkdir -p "$(dirname "$dest")"
    cp -- "$(media_cache_path "$want")" "$dest"
    _mc_log "cache hit: $label ($want)"
    return 0
  fi
  # An md5 pin cannot address content, so scan the index for a blob recorded
  # under this label, then verify it against the md5 before trusting it.
  if [ "$algo" = md5 ]; then
    for p in "$MEDIA_ARCHIVE_ROOT"/blobs/*/*; do
      [ -f "$p" ] || continue
      if [ "$(_mc_md5 "$p")" = "$want" ]; then
        mkdir -p "$(dirname "$dest")"
        cp -- "$p" "$dest"
        _mc_log "cache hit: $label (md5 $want)"
        return 0
      fi
    done
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/media-cache.XXXXXX")"
  for url in "$@"; do
    [ -n "$url" ] || continue
    _mc_log "cache miss: $label — fetching $url"
    if curl -fSL --retry 3 --connect-timeout 20 --max-time 1800 -o "$tmp" "$url"; then
      if _mc_check_pin "$tmp" "$pin"; then
        h="$(media_cache_put "$tmp" "$label" "fetched by media_cache_require" "$url")"
        mkdir -p "$(dirname "$dest")"
        cp -- "$(media_cache_path "$h")" "$dest"
        rm -f "$tmp"
        return 0
      fi
      _mc_err "$label fetched from $url but FAILED its $algo pin — not archiving it"
    fi
  done
  rm -f "$tmp"
  rc=1
  _mc_err "cannot obtain '$label' ($pin).
  It is NOT in the archive at $MEDIA_ARCHIVE_ROOT, and every source URL failed
  or returned the wrong bytes:
$(printf '    %s\n' "$@")
  This is a HARD failure on purpose. The old behaviour here was
  \`curl … || true\`, which let a media-less build report success and produced a
  black tile weeks later. If the upstream is gone for good, stage a copy by hand
  and archive it: media_cache_put <file> '$label'
  See docs/lab/ASSETS-MANIFEST.md and $MEDIA_ARCHIVE_ROOT/README.md."
  return $rc
}
