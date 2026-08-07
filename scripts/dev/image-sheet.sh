#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: image-sheet.sh <out.png> <img...> [--labels]

Build a deterministic contact sheet from two or more images. --labels adds each
input basename below its tile. IMAGE_SHEET_GEOMETRY may override 480x360+16+28.
Requires ImageMagick's montage and identify commands.
EOF
}

die() {
  echo "image-sheet: $*" >&2
  exit 1
}

[[ ${1:-} != --help && ${1:-} != -h ]] || {
  usage
  exit 0
}
[[ $# -ge 3 ]] || {
  usage >&2
  exit 2
}

out=$1
shift
labels=0
images=()
for arg in "$@"; do
  if [[ $arg == --labels ]]; then
    labels=1
  elif [[ $arg == -* ]]; then
    die "unknown option: $arg"
  else
    [[ -f $arg ]] || die "image not found: $arg"
    identify "$arg" >/dev/null 2>&1 || die "unreadable image: $arg"
    images+=("$arg")
  fi
done
((${#images[@]} >= 2)) || die "provide at least two images"

count=${#images[@]}
cols=1
while ((cols * cols < count)); do
  ((cols += 1))
done
mkdir -p -- "$(dirname "$out")"
geometry=${IMAGE_SHEET_GEOMETRY:-480x360+16+28}
args=(-background '#202124' -fill white -geometry "$geometry" -tile "${cols}x")
if ((labels)); then
  args+=(-set label '%t')
else
  args+=(-set label '')
fi
montage "${images[@]}" "${args[@]}" "$out"
identify "$out" >/dev/null 2>&1 || die "ImageMagick did not create $out"
echo "image-sheet: wrote $out (${count} images, ${cols} columns, labels=$labels)"
