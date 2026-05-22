#!/usr/bin/env bash
set -euo pipefail

root="$HOME/.local/share/zinc/llama-cpp-turboquant"
repo="https://github.com/iamwavecut/llama-cpp-turboquant.git"
branch="feature/turboquant-kv-cache"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need git
need cmake
need nvcc

mkdir -p "$(dirname "$root")"
if [[ -d "$root/.git" ]]; then
  git -C "$root" fetch origin "$branch"
  git -C "$root" checkout "$branch"
  git -C "$root" reset --hard "origin/$branch"
else
  git clone --branch "$branch" "$repo" "$root"
fi

cmake -S "$root" -B "$root/build" \
  -DGGML_CUDA=ON \
  -DGGML_NATIVE=ON \
  -DGGML_CUDA_FA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build "$root/build" -j"$(nproc)" --target llama-server

cat <<MSG
installed TurboQuant llama-server: $root/build/bin/llama-server

Launch Zinc's configured model server with:
  zn up

Stop it with:
  zn down
MSG
