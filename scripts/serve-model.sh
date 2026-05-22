#!/usr/bin/env bash
set -euo pipefail

root="$HOME/.local/share/zinc"
global_config="$HOME/.config/zinc/config.toml"
manifest_config="zinc.toml"
project_config=".zinc/config.toml"
model_name="${1:-}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need nvidia-smi
need python3

config_value() {
  local key="$1"
  local path
  for path in "$global_config" "$manifest_config" "$project_config"; do
    [[ -f "$path" ]] || continue
    awk -F= -v key="$key" '
      $0 !~ /^[[:space:]]*(#|$)/ {
        lhs=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        if (lhs == key) {
          rhs=substr($0, index($0, "=") + 1)
          sub(/[[:space:]]+#.*$/, "", rhs)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
          gsub(/^"|"$/, "", rhs)
          print rhs
          exit
        }
      }
    ' "$path"
  done | tail -n 1
}

model_value() {
  local model="$1"
  local key="$2"
  local path
  for path in "$global_config" "$manifest_config" "$project_config"; do
    [[ -f "$path" ]] || continue
    awk -F= -v section="models.$model" -v key="$key" '
      /^[[:space:]]*\[/ {
        current=$0
        gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", current)
        next
      }
      current == section && $0 !~ /^[[:space:]]*(#|$)/ {
        lhs=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        if (lhs == key) {
          rhs=substr($0, index($0, "=") + 1)
          sub(/[[:space:]]+#.*$/, "", rhs)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
          gsub(/^"|"$/, "", rhs)
          print rhs
          exit
        }
      }
    ' "$path"
  done | tail -n 1
}

if [[ -z "$model_name" ]]; then
  model_name="$(config_value default_model)"
fi
if [[ -z "$model_name" ]]; then
  echo "missing default_model in Zinc config" >&2
  exit 1
fi

engine="$(model_value "$model_name" engine)"
alias="$(model_value "$model_name" alias)"
hf_repo="$(model_value "$model_name" hf_repo)"
hf_file="$(model_value "$model_name" hf_file)"
cache_type_k="$(model_value "$model_name" cache_type_k)"
cache_type_v="$(model_value "$model_name" cache_type_v)"
fit_ctx="$(model_value "$model_name" fit_ctx)"
vram_allocation_percent="$(model_value "$model_name" vram_allocation_percent)"
reasoning="$(model_value "$model_name" reasoning)"
reasoning_format="$(model_value "$model_name" reasoning_format)"
reasoning_budget="$(model_value "$model_name" reasoning_budget)"

: "${engine:=llama-cpp-turboquant}"
: "${cache_type_k:=q8_0}"
: "${cache_type_v:=q8_0}"
: "${fit_ctx:=8192}"
: "${vram_allocation_percent:=87.5}"
: "${reasoning:=auto}"
: "${reasoning_format:=deepseek}"
: "${reasoning_budget:=-1}"

if [[ -z "$alias" || -z "$hf_repo" || -z "$hf_file" ]]; then
  echo "model '$model_name' is missing alias, hf_repo, or hf_file in Zinc config" >&2
  exit 1
fi

case "$engine" in
  llama-cpp-turboquant)
    server="$root/llama-cpp-turboquant/build/bin/llama-server"
    ;;
  *)
    echo "unsupported Zinc model engine for serving: $engine" >&2
    exit 1
    ;;
esac

if [[ ! -x "$server" ]]; then
  echo "llama-server not found at $server" >&2
  echo "Run: zn-setup-turboquant" >&2
  exit 1
fi

total_vram_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1 | tr -d '[:space:]')"
fit_values="$(python3 - "$vram_allocation_percent" "$total_vram_mib" <<'PY'
import math
import sys

percent = float(sys.argv[1])
total = int(sys.argv[2])
if not 0 < percent <= 100:
    raise SystemExit("vram_allocation_percent must be > 0 and <= 100")
max_mib = math.floor(total * percent / 100.0)
print(max_mib, max(total - max_mib, 0))
PY
)"
read -r max_vram_mib fit_margin_mib <<<"$fit_values"
echo "Zinc serving '$model_name' as '$alias': ${max_vram_mib}MiB cap (${vram_allocation_percent}%); fit margin ${fit_margin_mib}MiB" >&2

exec "$server" \
  -hf "$hf_repo" \
  -hff "$hf_file" \
  --alias "$alias" \
  --host 127.0.0.1 \
  --port 30000 \
  -np 1 \
  -fit on \
  -fitc "$fit_ctx" \
  -fitt "$fit_margin_mib" \
  -fa on \
  -ctk "$cache_type_k" \
  -ctv "$cache_type_v" \
  --jinja \
  --cache-ram 0 \
  --log-colors off \
  --reasoning "$reasoning" \
  --reasoning-format "$reasoning_format" \
  --reasoning-budget "$reasoning_budget"
