#!/bin/bash
set -euo pipefail


rolling_view() {
  local n="$1" cols i line

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


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_URL="https://github.com/ggml-org/llama.cpp.git"
REPO_REPO="https://api.github.com/repos/ggml-org/llama.cpp"
REPO_TAG="$(curl -fsSL "${REPO_REPO}/releases/latest" | jq -r '.tag_name')"
REPO_DIR="${SCRIPT_DIR}/llama.cpp"
BUILD_DIR="build"
VERSION_FILE="${SCRIPT_DIR}/.llama-version"

PREV_TAG=""
[[ -f "${VERSION_FILE}" ]] && PREV_TAG="$(cat "${VERSION_FILE}")"

BLAS_SRC="${SCRIPT_DIR}/blas-src"
AOCL_PREFIX="$HOME/.local/aocl"
BLIS_PREFIX="$HOME/.local/blis"

SVC_GOMP_CPU_AFFINITY="${SVC_GOMP_CPU_AFFINITY:-}"
SVC_BLIS_NUM_THREADS="${SVC_BLIS_NUM_THREADS:-}"

SERVICE="local-llm.service"
UNIT_SRC="${SCRIPT_DIR}/${SERVICE}"
DROPIN="$HOME/.config/systemd/user/${SERVICE}.d/blis.conf"
CPU_VENDOR="$(grep -m1 -oE 'GenuineIntel|AuthenticAMD' /proc/cpuinfo || true)"



CMAKE_BACKEND=(
  -DGGML_CUDA=OFF
  -DGGML_VULKAN=OFF
  -DGGML_METAL=OFF
  -DGGML_OPENCL=OFF
  -DGGML_SYCL=OFF
  -DGGML_HIP=OFF
  -DGGML_RPC=OFF
  -DGGML_CANN=OFF
  -DGGML_BLAS=ON
  -DGGML_BLAS_VENDOR=OpenBLAS
)

ENABLE_CUDA="${ENABLE_CUDA:-1}"
ENABLE_VULKAN="${ENABLE_VULKAN:-0}"

if [[ "$ENABLE_CUDA" == "1" ]]; then
  CUDA_VERSIONS=$(
    nvidia-smi --query-gpu=index,name,compute_cap --format=csv,noheader,nounits 2>/dev/null \
      | awk -F',' '{gsub(/ /,"",$3); gsub(/\./,"",$3); if($3!="") print $3}' \
      | sort -nu \
      | paste -sd';' -
  )

  CMAKE_BACKEND+=(
    -DGGML_CUDA=ON
    -DGGML_CUDA_FA_QUANTS=all
    -DCUDAToolkit_ROOT=/opt/cuda
    -DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_VERSIONS}"
  )
fi

if [[ "$ENABLE_VULKAN" == "1" ]]; then
  CMAKE_BACKEND+=(-DGGML_VULKAN=ON)
fi

build_blis() {
  local repo="$1" prefix="$2" lib="$3" url head built
  shift 3
  url="https://github.com/${repo}.git"
  head="$(git ls-remote "$url" HEAD | cut -f1)"
  built="$(cat "${prefix}/.version" 2>/dev/null || true)"

  if [[ -f "${prefix}/lib/${lib}" && "$built" == "$head" ]]; then
    return 0
  fi
  rm -rf "${BLAS_SRC}"

  git clone --depth 1 "$url" "${BLAS_SRC}"
  head="$(git -C "${BLAS_SRC}" rev-parse HEAD)"
  (
    cd "${BLAS_SRC}"

    CC=gcc CXX=g++ ./configure --prefix="${prefix}" --enable-cblas "$@"
    make -j"$(nproc)"
    make install
  ) 2>&1 | rolling_view 3

  printf '%s\n' "$head" > "${prefix}/.version"
  rm -rf "${BLAS_SRC}"
}

case "$CPU_VENDOR" in
  AuthenticAMD)
    build_blis amd/blis "${AOCL_PREFIX}" libblis-mt.so --enable-threading=openmp auto
    BLAS_VENDOR="AOCL_mt" BLAS_PREFIX="${AOCL_PREFIX}"
    ;;
  GenuineIntel)
    build_blis flame/blis "${BLIS_PREFIX}" libblis.so -t openmp,pthreads auto
    BLAS_VENDOR="FLAME" BLAS_PREFIX="${BLIS_PREFIX}"
    ;;
  *)
    BLAS_VENDOR="OpenBLAS" BLAS_PREFIX=""
    ;;
esac

if [[ -n "$BLAS_PREFIX" ]]; then
  CMAKE_BACKEND+=(
    -DGGML_BLAS_VENDOR="${BLAS_VENDOR}"
    -DBLAS_INCLUDE_DIRS="${BLAS_PREFIX}/include/blis"
    -DCMAKE_PREFIX_PATH="${BLAS_PREFIX}"
  )
fi

if command -v sccache >/dev/null 2>&1; then
  CMAKE_BACKEND+=(
      -DCMAKE_C_COMPILER_LAUNCHER=sccache
      -DCMAKE_CXX_COMPILER_LAUNCHER=sccache
      -DCMAKE_CUDA_COMPILER_LAUNCHER=sccache
  )
fi

detect_cpu_tuning() {
  local cpus
  [[ -n "$SVC_GOMP_CPU_AFFINITY" && -n "$SVC_BLIS_NUM_THREADS" ]] && return 0

  if command -v lscpu >/dev/null 2>&1; then
    cpus="$(lscpu -p=CPU,SOCKET,CORE,MAXMHZ 2>/dev/null | awk -F, '
      BEGIN { n = 0 }
      /^#/ { next }
      { k =$2 "," $3
        if (!(k in seen)) { seen[k] = 1; cpu[n] = $1; mhz[n] = $4 + 0; if ($4 + 0 > max) max = $4 + 0; n++ } }
      END { for (i = 0; i < n; i++) if (mhz[i] >= max * 0.9) printf "%s%s", (c++ ? "," : ""), cpu[i] }')"
  fi

  if [[ -z "${cpus:-}" ]]; then
    cpus="$(seq -s, 0 $(($(nproc --all) - 1)))"
  fi
  : "${SVC_GOMP_CPU_AFFINITY:=$cpus}"
  : "${SVC_BLIS_NUM_THREADS:=$(tr ',' '\n' <<<"$cpus" | wc -l)}"
}

print_changelog() {
  local base="$1" head="$2" json total r c
  json="$(curl -fsSL "${REPO_REPO}/compare/${base}...${head}")";
  total="$(jq -r '.total_commits' <<<"$json")"
  c=$'\033[1;36m' r=$'\033[0m'

  cat <<EOF
  ${c}╔══════════════════════════════════════════════════════════╗${r}
  ${c}║ Changelog $base → $head  ($total commits)${r}
  ${c}╚══════════════════════════════════════════════════════════╝${r}
EOF

  jq -r '.commits[].commit.message | split("\n")[0]' <<<"$json" | sed 's/^/  • /'
  printf '\n'
}


[[ -n "$PREV_TAG" ]] && print_changelog "${PREV_TAG}" "${REPO_TAG}"

if [[ -d "${REPO_DIR}/.git" ]]; then
  git -C "${REPO_DIR}" fetch --depth 1 origin tag "${REPO_TAG}"
  git -C "${REPO_DIR}" reset --hard "${REPO_TAG}"
  git -C "${REPO_DIR}" clean -fdx -e "${BUILD_DIR}"
else
  git clone --depth 1 --branch "${REPO_TAG}" "${REPO_URL}" "${REPO_DIR}"
fi

cd "${REPO_DIR}"

CC=gcc CXX=g++ cmake -B "${BUILD_DIR}" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DGGML_NATIVE=ON \
  -DCMAKE_BUILD_TYPE=Release \
  "-G Ninja" \
  "${CMAKE_BACKEND[@]}" \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local"

cmake --build "${BUILD_DIR}" -j"$(nproc)" 2>&1 | rolling_view 3

if [[ -d "$HOME"/.local/lib/ ]]; then
    rm -f "$HOME"/.local/lib/{libggml,libmtmd,libllama}*.so*
fi

cmake --install "${BUILD_DIR}"

printf '%s\n' "${REPO_TAG}" > "${VERSION_FILE}"



if [[ "$BLAS_VENDOR" == "FLAME" ]]; then
  detect_cpu_tuning
  mkdir -p "$(dirname "${DROPIN}")"
  cat > "${DROPIN}" <<EOF
[Service]
Environment=GOMP_CPU_AFFINITY=${SVC_GOMP_CPU_AFFINITY}
Environment=BLIS_NUM_THREADS=${SVC_BLIS_NUM_THREADS}
EOF
elif [[ -f "${DROPIN}" ]]; then
  rm -f "${DROPIN}"
fi

if [[ -f "${UNIT_SRC}" ]]; then
  systemctl --user link --force "${UNIT_SRC}"
  systemctl --user daemon-reload
  systemctl --user restart "${SERVICE}"
fi
