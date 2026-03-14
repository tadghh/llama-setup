#!/usr/bin/env bash
set -euo pipefail

export CUDA_SCALE_LAUNCH_QUEUES=4x

LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-$HOME/Documents/local-llm/llama.cpp/build/bin/llama-server}"
HF_REPO="${HF_REPO:-PeterAM4/Qwen3-Embedding-0.6B-GGUF:Q5_K_M}"

CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"

KV_OFFLOAD="${KV_OFFLOAD:-1}"

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-10001}"

GPU_LAYERS="${GPU_LAYERS:-999}"

have() { command -v "$1" >/dev/null 2>&1; }

if [[ ! -x "$LLAMA_SERVER_BIN" ]]; then
  echo "ERROR: llama-server not executable: $LLAMA_SERVER_BIN" >&2
  exit 1
fi

if [[ -z "$HF_REPO" ]]; then
  echo "ERROR: HF_REPO not set" >&2
  exit 1
fi

detect_devices() {
  local out devs
  out="$("$LLAMA_SERVER_BIN" --list-devices 2>/dev/null || true)"

  devs="$(echo "$out" | grep -Eo '\bcuda[0-9]+\b' | sort -Vu | paste -sd',' -)"
  if [[ -n "$devs" ]]; then
    echo "$devs"
    return 0
  fi

  # Fallback: if we can count GPUs, assume cuda0..cudaN-1
  if have nvidia-smi; then
    local n i
    n="$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
      devs=""
      for ((i=0; i<n; i++)); do
        devs+="${devs:+,}cuda${i}"
      done
      echo "$devs"
      return 0
    fi
  fi

  return 1
}

DEVICES="${DEVICES:-}"
if [[ -z "$DEVICES" ]]; then
  if ! DEVICES="$(detect_devices)"; then
    echo "ERROR: failed to auto-detect devices. Run: $LLAMA_SERVER_BIN --list-devices" >&2
    exit 1
  fi
fi

DEVICE_COUNT="$(awk -F',' '{print NF}' <<<"$DEVICES")"

SPLIT_MODE="${SPLIT_MODE:-layer}"
TENSOR_SPLIT="${TENSOR_SPLIT:-10,11}"  # only applied when exactly 2 GPUs

args=(
  --host "$HOST"
  --port "$PORT"
  --hf-repo "$HF_REPO"
  --mlock
  --ubatch-size 4096
  --batch-size 4096
  --numa numactl
  --direct-io
  --no-host
  --cache-type-k "$CACHE_TYPE_K"
  --cache-type-v "$CACHE_TYPE_V"
  --gpu-layers 1
  --embedding
  --pooling mean
  --parallel 1
  --cache-ram -1
  --api-key none # for vibe coded non optional, docs mcp
)

if (( DEVICE_COUNT > 1 )); then
  args+=(--split-mode "$SPLIT_MODE")
  if (( DEVICE_COUNT == 2 )); then
    args+=(--tensor-split "$TENSOR_SPLIT")
  fi
fi

if [[ "$KV_OFFLOAD" == "0" ]]; then
  args+=(--no-kv-offload)
else
  args+=(--kv-offload)
fi

echo "exec: $LLAMA_SERVER_BIN ${args[*]} $*"
exec "$LLAMA_SERVER_BIN" "${args[@]}" "$@"
