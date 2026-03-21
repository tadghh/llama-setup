#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/ggml-org/llama.cpp"
REPO_DIR="llama.cpp"
BUILD_DIR="build"

have() { command -v "$1" >/dev/null 2>&1; }

if [[ -d "${REPO_DIR}/.git" ]]; then
  git -C "${REPO_DIR}" pull --rebase
else
  git clone "${REPO_URL}" "${REPO_DIR}"
fi

cd "${REPO_DIR}"

GEN_ARGS=()
have ninja && GEN_ARGS=(-G Ninja)

[ -n "${BUILD_DIR}" ] && rm -rf "${BUILD_DIR}"

CMAKE_BACKEND=()

if have nvidia-smi && have nvcc; then
  [[ -x /opt/cuda/bin/nvcc ]] && export PATH="/opt/cuda/bin:$PATH"

  CUDA_VERSIONS=$(
    nvidia-smi --query-gpu=index,name,compute_cap --format=csv,noheader,nounits 2>/dev/null \
      | awk -F',' '{gsub(/ /,"",$3); gsub(/\./,"",$3); if($3!="") print $3}' \
      | sort -nu \
      | paste -sd';' -
  )

  if [[ -n "$CUDA_VERSIONS" ]]; then
    echo "Backend: CUDA (architectures: $CUDA_VERSIONS)"
    export GGML_CUDA_FA_ALL_QUANTS=true
    export GGML_CUDA_PEER_MAX_BATCH_SIZE=1024
    export GGML_CUDA_FORCE_CUBLAS=true
    CMAKE_BACKEND=(
      -DGGML_CUDA=ON
      -DCUDAToolkit_ROOT=/opt/cuda
      -DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc
      -DCMAKE_CUDA_ARCHITECTURES="${CUDA_VERSIONS}"
    )
  fi
elif have vulkaninfo; then
  echo "Backend: Vulkan"
  CMAKE_BACKEND=(-DGGML_VULKAN=ON)
else
  echo "Backend: CPU only"
fi

if ! have mold; then
  echo "ERROR: mold not found. Install it first (e.g., pacman -S mold)." >&2
  exit 1
fi

cmake -B "${BUILD_DIR}" \
  "${GEN_ARGS[@]}" \
  "${CMAKE_BACKEND[@]}" \
  -DGGML_NATIVE=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_LINKER=mold

cmake --build "${BUILD_DIR}" -j"$(nproc)"

# If you hit missing library errors post-install:
#   echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/local.conf
#   sudo ldconfig

sudo cmake --install "${BUILD_DIR}"
