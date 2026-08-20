#!/usr/bin/env bash
# install-llm.sh — put llama.cpp + the retronet GGUF on labhost and install the
# caged `retronet-llm` systemd unit. Idempotent; run as root on labhost.
#
#   ssh lab '/data/kernel-hive/scripts/retronet/llm/install-llm.sh --apply'
#
# Steps (each skipped when already satisfied):
#   1. fetch the PINNED llama.cpp release tarball, verify sha256, unpack
#   2. fetch the model GGUFs from the archival mirror (--models to force)
#   3. write /etc/retronet/llm.env  (the knobs; the unit reads only this)
#   4. install + enable + start retronet-llm.service
#
# The llama.cpp build is a pinned upstream release, not a local compile: the
# ubuntu-x64 tarball ships per-microarch ggml CPU backends and picks
# libggml-cpu-skylakex.so at runtime, which is exactly the AVX-512 path this
# Xeon D-2146NT wants — and it means no cmake/toolchain on the Proxmox host.
set -euo pipefail

LLAMA_TAG="${LLAMA_TAG:-b10516}"
LLAMA_SHA256="f263a91280471b4c33c4999d7c76259c0f3a0a53a0b3e692b2c0b84380137a35"
RN_LLM_HOME="${RN_LLM_HOME:-/data/retronet/llm}"
# The pick: see the bench table in docs/lab/retronet/BOT.md.
DEFAULT_MODEL="Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
MODELS=(
  "unsloth/Qwen3-4B-Instruct-2507-GGUF|Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
  "bartowski/Llama-3.2-3B-Instruct-GGUF|Llama-3.2-3B-Instruct-Q4_K_M.gguf"
  "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF|Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"
)

APPLY=0
WANT_MODELS=0
UNIT_SRC="$(cd "$(dirname "$0")" && pwd)/retronet-llm.service"

for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --models) WANT_MODELS=1 ;;
    -h | --help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "install-llm.sh: unknown arg $a" >&2
      exit 2
      ;;
  esac
done

say() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
do_or_plan() {
  if [ "$APPLY" = 1 ]; then "$@"; else say "PLAN: $*"; fi
}

[ "$(id -u)" = 0 ] || {
  echo "install-llm.sh: must run as root on labhost" >&2
  exit 1
}

step "llama.cpp $LLAMA_TAG"
TARBALL="$RN_LLM_HOME/dist/llama-$LLAMA_TAG-bin-ubuntu-x64.tar.gz"
if [ -x "$RN_LLM_HOME/dist/llama-$LLAMA_TAG/llama-server" ]; then
  say "already unpacked: $RN_LLM_HOME/dist/llama-$LLAMA_TAG"
else
  do_or_plan mkdir -p "$RN_LLM_HOME/dist" "$RN_LLM_HOME/models"
  if [ "$APPLY" = 1 ]; then
    [ -f "$TARBALL" ] || curl -fsSL -o "$TARBALL" \
      "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-bin-ubuntu-x64.tar.gz"
    echo "$LLAMA_SHA256  $TARBALL" | sha256sum -c - || {
      echo "install-llm.sh: sha256 MISMATCH on $TARBALL — refusing" >&2
      exit 1
    }
    tar xzf "$TARBALL" -C "$RN_LLM_HOME/dist"
  else
    say "PLAN: download + sha256 + unpack $TARBALL"
  fi
fi
do_or_plan ln -sfn "$RN_LLM_HOME/dist/llama-$LLAMA_TAG" "$RN_LLM_HOME/bin"

step "models"
for spec in "${MODELS[@]}"; do
  repo="${spec%%|*}"
  file="${spec##*|}"
  dest="$RN_LLM_HOME/models/$file"
  if [ -s "$dest" ]; then
    say "have $file ($(du -h "$dest" | cut -f1))"
  elif [ "$WANT_MODELS" = 1 ] || [ "$file" = "$DEFAULT_MODEL" ]; then
    do_or_plan curl -fsSL -C - -o "$dest" "https://huggingface.co/$repo/resolve/main/$file"
  else
    say "skip $file (bench candidate; --models to fetch)"
  fi
done
# DynamicUser= runs as a transient uid, so everything it reads must be
# world-readable. curl under root's umask leaves 0600 GGUFs behind.
do_or_plan chmod a+rX /data/retronet
do_or_plan chmod -R a+rX "$RN_LLM_HOME"

step "/etc/retronet/llm.env"
if [ "$APPLY" = 1 ]; then
  mkdir -p /etc/retronet
  if [ -f /etc/retronet/llm.env ]; then
    say "kept existing /etc/retronet/llm.env (edit by hand to change the model)"
  else
    cat >/etc/retronet/llm.env <<EOF
# retronet-llm knobs. THE model choice lives here; the unit file has no defaults.
RN_LLM_HOST=127.0.0.1
RN_LLM_PORT=8091
RN_LLM_MODEL=$RN_LLM_HOME/models/$DEFAULT_MODEL
RN_LLM_ALIAS=retronet
# Keep in step with CPUQuota= in the unit: 400% == 4 threads.
RN_LLM_THREADS=4
RN_LLM_CTX=8192
RN_LLM_SLOTS=2
EOF
    say "wrote /etc/retronet/llm.env"
  fi
else
  say "PLAN: write /etc/retronet/llm.env (model=$DEFAULT_MODEL, port 8091, -t 4)"
fi

step "unit"
do_or_plan install -m 0644 "$UNIT_SRC" /etc/systemd/system/retronet-llm.service
do_or_plan systemctl daemon-reload
do_or_plan systemctl enable --now retronet-llm.service
if [ "$APPLY" = 1 ]; then
  for _ in $(seq 1 60); do
    curl -fsS -m 2 http://127.0.0.1:8091/health >/dev/null 2>&1 && break
    sleep 2
  done
  printf '\n'
  systemctl --no-pager --lines=3 status retronet-llm.service || true
  curl -fsS -m 5 http://127.0.0.1:8091/v1/models || say "NOT READY — journalctl -u retronet-llm"
  printf '\n'
fi
