#!/usr/bin/env bash
# bench.sh — llama-bench harness for the retronet LLM candidates.
#
# WHY a harness and not a bare llama-bench: the numbers have to be comparable
# across candidates and reproducible months later, and they have to be taken at
# the SAME thread count the caged service actually gets. retronet-llm runs under
# CPUQuota=400% (4 cores' worth of an 8C/16T Xeon D-2146NT), so a 16-thread
# bench would publish a throughput the unit can never reach.
#
# The bot's shape decides which column matters:
#   pp (prompt processing) — the persona system prompt + a few turns of history,
#                            ~300-500 tokens, paid on EVERY reply
#   tg (token generation)  — replies are capped at ~200 characters (~60 tokens)
# so time-to-reply ~= pp_tokens/pp_rate + 60/tg_rate. Both are published.
#
# usage: bench.sh [-t THREADS] [-o OUTFILE] [model.gguf ...]
#        bench.sh                 # all GGUFs in $RN_LLM_HOME/models, -t 4 and 8
set -euo pipefail

RN_LLM_HOME="${RN_LLM_HOME:-/data/retronet/llm}"
THREADS="${RN_LLM_BENCH_THREADS:-4,8}"
PROMPT_TOKENS="${RN_LLM_BENCH_PP:-256}"
GEN_TOKENS="${RN_LLM_BENCH_TG:-64}"
REPS="${RN_LLM_BENCH_REPS:-3}"
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -t)
      THREADS="$2"
      shift 2
      ;;
    -o)
      OUT="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    *) break ;;
  esac
done

BIN="$RN_LLM_HOME/bin/llama-bench"
[ -x "$BIN" ] || {
  echo "bench.sh: $BIN missing — run install-llm.sh first" >&2
  exit 1
}

models=("$@")
if [ ${#models[@]} -eq 0 ]; then
  mapfile -t models < <(find "$RN_LLM_HOME/models" -maxdepth 1 -name '*.gguf' | sort)
fi
[ ${#models[@]} -gt 0 ] || {
  echo "bench.sh: no GGUF models found under $RN_LLM_HOME/models" >&2
  exit 1
}

emit() {
  echo "# retronet LLM bench  $(date -Is)"
  echo "# host: $(hostname)  $(nproc) threads  $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)"
  echo "# llama.cpp: $(LD_LIBRARY_PATH="$RN_LLM_HOME/bin" "$BIN" --version 2>&1 | head -1)"
  echo "# -t $THREADS -p $PROMPT_TOKENS -n $GEN_TOKENS -r $REPS"
  for m in "${models[@]}"; do
    echo
    echo "## $(basename "$m")  ($(du -h "$m" | cut -f1))"
    # nice + idle IO: the fleet owns this box, the bench is a guest in it.
    nice -n 15 ionice -c 3 env LD_LIBRARY_PATH="$RN_LLM_HOME/bin" \
      "$BIN" -m "$m" -t "$THREADS" -p "$PROMPT_TOKENS" -n "$GEN_TOKENS" -r "$REPS" -o md 2>/dev/null
  done
}

if [ -n "$OUT" ]; then emit | tee "$OUT"; else emit; fi
