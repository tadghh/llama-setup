#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/ggml-org/llama.cpp"
REPO_DIR="llama.cpp"
BUILD_DIR="build"

have() { command -v "$1" >/dev/null 2>&1; }

declare -A gpu_cuda_versions

if have nvidia-smi; then
  # Query: index,name,compute_cap (e.g., "0, NVIDIA ..., 7.5")

  while IFS=',' read -r gpu_id gpu_name compute_cap; do
    gpu_id="$(echo "$gpu_id" | xargs)"
    compute_cap="$(echo "$compute_cap" | xargs)"   # "7.5"
    sm="${compute_cap//./}"                        # "75"
    [[ -n "$gpu_id" && -n "$sm" ]] && gpu_cuda_versions["$gpu_id"]="$sm"
  done < <(nvidia-smi --query-gpu=index,name,compute_cap --format=csv,noheader,nounits 2>/dev/null || true)
fi

VERSIONS=$(
  printf "%s\n" "${gpu_cuda_versions[@]:-}" \
    | awk 'NF{a[$0]=1} END{for(k in a) print k}' \
    | sort -n \
    | paste -sd';' - 2>/dev/null || true
)

if [[ -z "${VERSIONS}" ]]; then
  echo "ERROR: failed to detect CUDA architectures via nvidia-smi." >&2
  exit 1
fi

echo "CUDA architectures: $VERSIONS"

if [[ -x /opt/cuda/bin/nvcc ]]; then
  export PATH="/opt/cuda/bin:$PATH"
fi

if ! have nvcc; then
  echo "ERROR: nvcc missing. Install CUDA toolkit (Arch: pacman -S cuda) and ensure /opt/cuda/bin is in PATH." >&2
  exit 1
fi

if ! have mold; then
  echo "ERROR: mold not found in PATH. Install it first (e.g., pacman -S mold)." >&2
  exit 1
fi

if [[ -d "${REPO_DIR}/.git" ]]; then
  git -C "${REPO_DIR}" pull --rebase
else
  git clone "${REPO_URL}" "${REPO_DIR}"
fi

cd "${REPO_DIR}"

GEN_ARGS=()
if have ninja; then
  GEN_ARGS=(-G Ninja)
fi

# it will be okay
[ -n "${BUILD_DIR}" ] && rm -rf "${BUILD_DIR}"

cmake -B "${BUILD_DIR}" \
  "${GEN_ARGS[@]}" \
  -DGGML_CUDA=ON \
  -DGGML_NATIVE=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_LINKER=mold \
  -DCUDAToolkit_ROOT=/opt/cuda \
  -DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc \
  -DCMAKE_CUDA_ARCHITECTURES="${VERSIONS}"

cmake --build "${BUILD_DIR}" -j"$(nproc)"
