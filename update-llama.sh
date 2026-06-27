#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_URL="https://github.com/ggml-org/llama.cpp.git"
REPO_REPO="ggml-org/llama.cpp"
REPO_DIR="llama.cpp"
BUILD_DIR="build"
VERSION_FILE="${SCRIPT_DIR}/.llama-version"

# Backend toggles (override from the env, e.g. ENABLE_VULKAN=1 ENABLE_CUDA=0 ./update-llama.sh).
# Supports: CUDA only (1/0), Vulkan only (0/1), and both (1/1).
ENABLE_CUDA="${ENABLE_CUDA:-1}"
ENABLE_VULKAN="${ENABLE_VULKAN:-0}"

have() { command -v "$1" >/dev/null 2>&1; }

print_changelog() {
  local base="$1" head="$2" json total shown
  if ! json="$(curl -fsSL "https://api.github.com/repos/${REPO_REPO}/compare/${base}...${head}")"; then
    printf '\033[1;33mCould not fetch changelog %s -> %s\033[0m\n' "$base" "$head" >&2
    return 0
  fi
  total="$(jq -r '.total_commits' <<<"$json")"
  shown="$(jq -r '.commits | length' <<<"$json")"
  printf '\n\033[1;36m╔══════════════════════════════════════════════════════════╗\033[0m\n'
  printf '\033[1;36m║\033[0m  \033[1mChangelog %s → %s\033[0m  (%s commits)\n' "$base" "$head" "$total"
  printf '\033[1;36m╚══════════════════════════════════════════════════════════╝\033[0m\n'
  jq -r '.commits[].commit.message | split("\n")[0]' <<<"$json" | sed 's/^/  • /'
  if [[ "$total" -gt "$shown" ]]; then
    printf '\033[2m  …and %s more (API caps at %s)\033[0m\n' "$((total - shown))" "$shown"
  fi
  printf '\n'
}

# Stream a command's output into a fixed N-line dimmed window that updates in
# place, so the build doesn't flood the terminal. Falls back to plain passthrough
# when stdout isn't a terminal.
rolling_view() {
  local n="$1" cols i
  if [[ ! -t 1 ]]; then cat; return; fi
  cols="$(tput cols 2>/dev/null || echo 100)"
  local -a buf=()
  for ((i = 0; i < n; i++)); do printf '\n'; done
  while IFS= read -r line; do
    line="${line//$'\t'/    }"
    buf+=("${line:0:cols}")
    ((${#buf[@]} > n)) && buf=("${buf[@]: -n}")
    printf '\033[%dA' "$n"
    for ((i = 0; i < n; i++)); do
      printf '\033[2K\033[2m%s\033[0m\n' "${buf[i]:-}"
    done
  done
}

have curl || { echo "ERROR: curl is required to resolve the latest release." >&2; exit 1; }
have jq   || { echo "ERROR: jq is required to render the changelog." >&2; exit 1; }

# Build the latest tagged release (not the unreviewed master tip).
REPO_TAG="$(curl -fsSL "https://api.github.com/repos/${REPO_REPO}/releases/latest" \
  | jq -r '.tag_name')"
if [[ -z "${REPO_TAG}" ]]; then
  echo "ERROR: could not determine latest ${REPO_REPO} release tag." >&2
  exit 1
fi
echo "Latest release: ${REPO_TAG}"

PREV_TAG=""
[[ -f "${VERSION_FILE}" ]] && PREV_TAG="$(cat "${VERSION_FILE}")"

if [[ -z "${PREV_TAG}" ]]; then
  echo "No previously recorded version (first tracked build)."
elif [[ "${PREV_TAG}" == "${REPO_TAG}" ]]; then
  echo "Already at ${REPO_TAG}; rebuilding."
else
  print_changelog "${PREV_TAG}" "${REPO_TAG}"
fi

# Shallow checkout of just that tag (no history kept).
if [[ -d "${REPO_DIR}/.git" ]]; then
  git -C "${REPO_DIR}" fetch --depth 1 origin tag "${REPO_TAG}"
  git -C "${REPO_DIR}" reset --hard "${REPO_TAG}"
  git -C "${REPO_DIR}" clean -fdx -e "${BUILD_DIR}"
else
  git clone --depth 1 --branch "${REPO_TAG}" "${REPO_URL}" "${REPO_DIR}"
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
  -DCMAKE_INSTALL_PREFIX="$HOME/.local" \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF

echo "Building ${REPO_TAG}..."
cmake --build "${BUILD_DIR}" -j"$(nproc)" 2>&1 | rolling_view 3

rm -f "$HOME"/.local/lib/libggml*.so* \
      "$HOME"/.local/lib/libllama*.so* \
      "$HOME"/.local/lib/libmtmd*.so*

cmake --install "${BUILD_DIR}"

printf '%s\n' "${REPO_TAG}" > "${VERSION_FILE}"
echo "Recorded ${REPO_TAG} in ${VERSION_FILE}"

SERVICE="local-llm.service"
UNIT_SRC="${SCRIPT_DIR}/${SERVICE}"

if [[ -f "${UNIT_SRC}" ]]; then
  echo "Linking ${SERVICE} from ${UNIT_SRC}..."
  systemctl --user link --force "${UNIT_SRC}"
else
  echo "WARNING: ${UNIT_SRC} not found; skipping unit link." >&2
fi

systemctl --user daemon-reload

if systemctl --user is-enabled --quiet "${SERVICE}" 2>/dev/null \
   || systemctl --user is-active --quiet "${SERVICE}" 2>/dev/null; then
  echo "Restarting ${SERVICE}..."
  systemctl --user restart "${SERVICE}"
  systemctl --user --no-pager --lines=0 status "${SERVICE}" || true
else
  echo "Note: ${SERVICE} not enabled/active; linked unit only." >&2
  echo "      Enable with: systemctl --user enable --now ${UNIT_SRC}" >&2
fi
