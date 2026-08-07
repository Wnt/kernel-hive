#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: blender-review.sh <generator> <variant> [--textured] [--h H] [--port P]

Run a scene-v2 Blender generator, verify/copy its GLB into the dev lineup,
start a task-owned Vite server if needed, capture the lineup with
scene-v2-shot.mjs, and make a centered crop. Artifacts are preserved below
/tmp/scene-v2-blender-review (override with BLENDER_REVIEW_ROOT).

generator may be blender/gen_mouse.py, gen_mouse.py, or mouse.
Defaults: --h 0.4 --port 5230. Ports 5197/5199 remain forbidden.
EOF
}

die() {
  echo "blender-review: $*" >&2
  exit 1
}

[[ ${1:-} != --help && ${1:-} != -h ]] || {
  usage
  exit 0
}
[[ $# -ge 2 ]] || {
  usage >&2
  exit 2
}
generator_arg=$1
variant=$2
shift 2
textured=0
height=0.4
port=5230
while (($#)); do
  case $1 in
    --textured)
      textured=1
      shift
      ;;
    --h | --port)
      (($# >= 2)) || die "missing value for $1"
      if [[ $1 == --h ]]; then
        height=$2
      else
        port=$2
      fi
      shift 2
      ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ $variant =~ ^[A-Za-z0-9_-]+$ ]] || die "unsafe variant: $variant"
[[ $height =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--h must be a positive number"
[[ $port =~ ^[0-9]+$ ]] || die "--port must be numeric"
[[ $port != 5197 && $port != 5199 ]] || die "port $port is reserved"

root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
if [[ -f $generator_arg ]]; then
  generator=$(realpath "$generator_arg")
elif [[ -f $root/blender/$generator_arg ]]; then
  generator=$root/blender/$generator_arg
elif [[ -f $root/blender/gen_"$generator_arg".py ]]; then
  generator=$root/blender/gen_"$generator_arg".py
else
  die "generator not found: $generator_arg"
fi
[[ $generator == "$root/blender/"*.py ]] ||
  die "generator must be a Python file under $root/blender"

base=$(basename "$generator" .py)
base=${base#gen_}
variant_lower=${variant,,}
slug=$base-$variant_lower
stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
artifact_root=${BLENDER_REVIEW_ROOT:-/tmp/scene-v2-blender-review}
artifacts=$artifact_root/$slug/$stamp
mkdir -p -- "$artifacts"
glb=$artifacts/$slug.glb
blender_log=$artifacts/blender.log
full=$artifacts/lineup-full.png
crop=$artifacts/lineup-crop.png

command=(blender -b --python "$generator" -- --variant "$variant" --out "$glb")
((textured == 0)) || command+=(--textured)
echo "blender-review: exporting $slug"
if ! timeout "${BLENDER_REVIEW_TIMEOUT:-600}" "${command[@]}" >"$blender_log" 2>&1; then
  tail -n 40 "$blender_log" >&2 || true
  die "Blender export failed; see $blender_log"
fi
[[ -s $glb ]] || die "Blender produced an empty GLB: $glb"
magic=$(head -c 4 "$glb")
[[ $magic == glTF ]] || die "output is not a binary glTF: $glb"
dev_glb=$root/spa/public/assets/models/v2/dev/$slug.glb
cp -- "$glb" "$dev_glb"

server=$root/scripts/dev/scene-v2-server.sh
started=0
cleanup() {
  if ((started)); then
    "$server" stop "$port" >/dev/null || true
  fi
}
trap cleanup EXIT
if ! "$server" status "$port" >/dev/null 2>&1; then
  "$server" start "$port"
  started=1
fi

url="http://127.0.0.1:$port/museum?lineup=dev:$slug:$height&shot=lineupOne"
"$root/scripts/dev/scene-v2-shot.mjs" "$url" "$full" --w 1920 --h 900 --patient
convert "$full" -gravity center -crop '70%x90%+0+0' +repage "$crop"
identify "$crop" >/dev/null 2>&1 || die "center crop failed: $crop"

echo "blender-review: GLB       $glb"
echo "blender-review: full PNG  $full"
echo "blender-review: crop PNG  $crop"
echo "blender-review: log       $blender_log"
