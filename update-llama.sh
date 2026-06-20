#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/ggml-org/llama.cpp.git"
REPO_DIR="llama.cpp"
REPO_BRANCH="master"
BUILD_DIR="build"

# Backend toggles (override from the env, e.g. ENABLE_VULKAN=1 ENABLE_CUDA=0 ./update-llama.sh).
# Supports: CUDA only (1/0), Vulkan only (0/1), and both (1/1).
ENABLE_CUDA="${ENABLE_CUDA:-1}"
ENABLE_VULKAN="${ENABLE_VULKAN:-0}"

have() { command -v "$1" >/dev/null 2>&1; }

# We only ever build the latest tip of the default branch and never contribute,
# so keep a shallow, single-branch checkout with no history.
if [[ -d "${REPO_DIR}/.git" ]]; then
  # Fetch only the newest commit and hard-reset onto it (history isn't kept).
  git -C "${REPO_DIR}" fetch --depth 1 origin "${REPO_BRANCH}"
  git -C "${REPO_DIR}" reset --hard FETCH_HEAD
  git -C "${REPO_DIR}" clean -fdx -e "${BUILD_DIR}"
else
  git clone --depth 1 --single-branch --branch "${REPO_BRANCH}" \
    "${REPO_URL}" "${REPO_DIR}"
fi

cd "${REPO_DIR}"

GEN_ARGS=()
have ninja && GEN_ARGS=(-G Ninja)

[ -n "${BUILD_DIR}" ] && rm -rf "${BUILD_DIR}"

if [[ "$ENABLE_CUDA" != "1" && "$ENABLE_VULKAN" != "1" ]]; then
  echo "ERROR: no backend enabled (set ENABLE_CUDA=1 and/or ENABLE_VULKAN=1)." >&2
  exit 1
fi

# Start with every optional backend OFF, then turn on only what is toggled.
CMAKE_BACKEND=(
  -DGGML_CUDA=OFF
  -DGGML_VULKAN=OFF
  -DGGML_METAL=OFF
  -DGGML_BLAS=OFF
  -DGGML_OPENCL=OFF
  -DGGML_SYCL=OFF
  -DGGML_HIP=OFF
  -DGGML_RPC=OFF
  -DGGML_CANN=OFF
)

ENABLED_BACKENDS=()

if [[ "$ENABLE_CUDA" == "1" ]]; then
  if ! have nvidia-smi || ! have nvcc; then
    echo "ERROR: CUDA enabled but toolchain not found (need nvidia-smi and nvcc)." >&2
    exit 1
  fi

  [[ -x /opt/cuda/bin/nvcc ]] && export PATH="/opt/cuda/bin:$PATH"

  CUDA_VERSIONS=$(
    nvidia-smi --query-gpu=index,name,compute_cap --format=csv,noheader,nounits 2>/dev/null \
      | awk -F',' '{gsub(/ /,"",$3); gsub(/\./,"",$3); if($3!="") print $3}' \
      | sort -nu \
      | paste -sd';' -
  )

  if [[ -z "$CUDA_VERSIONS" ]]; then
    echo "ERROR: could not detect CUDA compute capabilities from nvidia-smi." >&2
    exit 1
  fi

  echo "Backend: CUDA (architectures: $CUDA_VERSIONS)"
  export GGML_CUDA_FA_ALL_QUANTS=true
  export GGML_CUDA_PEER_MAX_BATCH_SIZE=1024
  export GGML_CUDA_FORCE_CUBLAS=true
  CMAKE_BACKEND+=(
    -DGGML_CUDA=ON
    -DCUDAToolkit_ROOT=/opt/cuda
    -DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_VERSIONS}"
  )
  ENABLED_BACKENDS+=("CUDA")
fi

if [[ "$ENABLE_VULKAN" == "1" ]]; then
  if ! have vulkaninfo; then
    echo "ERROR: Vulkan enabled but vulkaninfo not found." >&2
    exit 1
  fi
  echo "Backend: Vulkan"
  CMAKE_BACKEND+=(-DGGML_VULKAN=ON)
  ENABLED_BACKENDS+=("Vulkan")
fi

echo "Enabled backends: ${ENABLED_BACKENDS[*]}"

cmake -B "${BUILD_DIR}" \
  "${GEN_ARGS[@]}" \
  "${CMAKE_BACKEND[@]}" \
  -DGGML_NATIVE=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF

cmake --build "${BUILD_DIR}" -j"$(nproc)"

# If you hit missing library errors post-install:
#   echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/local.conf
#   sudo ldconfig

sudo cmake --install "${BUILD_DIR}"
