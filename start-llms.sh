#!/usr/bin/env bash
set -euo pipefail

export CUDA_SCALE_LAUNCH_QUEUES=4x

LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-$HOME/Documents/local-llm/llama.cpp/build/bin/llama-server}"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-10000}"

args=(
  --host "$HOST"
  --port "$PORT"
  --models-preset ./model-config.ini
)

echo "exec: $LLAMA_SERVER_BIN ${args[*]} $*"
exec "$LLAMA_SERVER_BIN" "${args[@]}" "$@"
