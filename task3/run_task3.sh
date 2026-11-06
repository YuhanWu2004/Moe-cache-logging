#!/bin/bash
# Task 3 — run everything, end to end.
#
# What it does: start the SSE server, wait until it's ready, then run the client
# for prompt A (cold cache) and prompt B (warm -- sees what A left resident),
# analyzing each. Override PROMPT_A / PROMPT_B / MAX_NEW to use your own pair.
#
# Where to run it: inside your salloc session, from the moe-setup checkout:
#   bash moe-cache-logging/task3/run_task3.sh
set -eo pipefail

# ---- locate the checkout and load its environment (same as run_logged.sh) ----
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HERE/../.." && pwd)"
export MOE_WORK_ROOT="$(cat "$REPO_DIR/.work-root")"
source "$MOE_WORK_ROOT/miniforge/etc/profile.d/conda.sh"
conda activate "$MOE_WORK_ROOT/env"
export PYTHONNOUSERSITE=1 HF_HOME="$MOE_WORK_ROOT/hf" XDG_CACHE_HOME="$MOE_WORK_ROOT/cache"
export TMPDIR="$MOE_WORK_ROOT/tmp" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 TOKENIZERS_PARALLELISM=false
export TORCH_EXTENSIONS_DIR="$MOE_WORK_ROOT/state/torch_extensions"
export TRITON_CACHE_DIR="$MOE_WORK_ROOT/state/triton"

# ---- knobs ----
export RUN_TAG="${RUN_TAG:-$(date +%Y%m%d-%H%M%S)}"
export LOG_DIR="${LOG_DIR:-$HERE/../logs}"
export PORT="${PORT:-8077}"
mkdir -p "$LOG_DIR"
MAX_NEW="${MAX_NEW:-96}"
PROMPT_A="${PROMPT_A:-Explain how a nuclear reactor produces electricity, step by step.}"
PROMPT_B="${PROMPT_B:-Write a short Python function that reverses a linked list.}"

# ---- start the server in the background; model load takes a few minutes ----
echo "[task3] starting server (tag $RUN_TAG) ..."
stdbuf -oL -eL python -u "$HERE/sse_server.py" > "$LOG_DIR/${RUN_TAG}_server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT          # always stop the server on exit

# ---- wait (up to ~6 min) for the server to answer /health ----
for i in $(seq 1 180); do
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
    sleep 2
    if ! kill -0 $SRV 2>/dev/null; then echo "server died:"; cat "$LOG_DIR/${RUN_TAG}_server.log"; exit 1; fi
done
echo "[task3] server up."

# ---- one request: client fetches + streams, then analyze ----
run_one () {  # args: tag  prompt  cache
    echo "[task3] client $1 (cache=$3)"
    python "$HERE/sse_client.py" --host 127.0.0.1 --port "$PORT" \
        --tag "$1" --prompt "$2" --max-new-tokens "$MAX_NEW" --cache "$3" --logdir "$LOG_DIR"
    python "$HERE/analyze.py" --tag "$1" --layers-tag "$RUN_TAG" --logdir "$LOG_DIR"
}

run_one "A" "$PROMPT_A" "cold"
run_one "B" "$PROMPT_B" "warm"   # B sees whatever experts A left on the GPU
echo "[task3] done. logs in $LOG_DIR (tag $RUN_TAG; per-request A_*, B_*)"
