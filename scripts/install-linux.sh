#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="$HOME/.local"
bin_dir="$prefix/bin"
share_dir="$prefix/share/zinc"
scripts_dir="$share_dir/scripts"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need zig

if [[ "$(zig version)" != 0.16.* ]]; then
  echo "warning: Zinc was designed against Zig 0.16.x; found $(zig version)" >&2
fi

cd "$root"
zig build -Doptimize=ReleaseFast

mkdir -p "$bin_dir" "$scripts_dir" "$share_dir/graphs" "$share_dir/compiled" "$share_dir/prompts"
install -m 0755 "$root/zig-out/bin/zn" "$bin_dir/zn"
install -m 0755 "$root/scripts/setup-turboquant-linux.sh" "$scripts_dir/setup-turboquant-linux.sh"
install -m 0755 "$root/scripts/serve-model.sh" "$scripts_dir/serve-model.sh"
install -m 0644 "$root/graphs/zinc-loop.circuitry.yaml" "$share_dir/graphs/zinc-loop.circuitry.yaml"
install -m 0644 "$root/graphs/zinc-context-recovery.circuitry.yaml" "$share_dir/graphs/zinc-context-recovery.circuitry.yaml"
install -m 0644 "$root/graphs/zinc-compaction.circuitry.yaml" "$share_dir/graphs/zinc-compaction.circuitry.yaml"
install -m 0644 "$root/prompts/circuitry-author.md" "$share_dir/prompts/circuitry-author.md"
install -m 0644 "$root/prompts/bash-guide.md" "$share_dir/prompts/bash-guide.md"

mkdir -p "$HOME/.config/zinc"
vram_allocation_percent="87.5"
if [[ -f "$HOME/.config/zinc/config.toml" ]]; then
  existing_vram="$(awk -F= '$1 ~ /^[[:space:]]*vram_allocation_percent[[:space:]]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' "$HOME/.config/zinc/config.toml")"
  [[ -z "$existing_vram" ]] || vram_allocation_percent="$existing_vram"
fi
cat > "$HOME/.config/zinc/config.toml" <<EOF_CONFIG
# Zinc global config. Project config at .zinc/config.toml can override these.
graph = "$share_dir/graphs/zinc-loop.circuitry.yaml"
compiled_plan = "$share_dir/compiled/plan.json"
provider_base_url = "http://127.0.0.1:30000/v1"
max_retries = 5
compaction_threshold_percent = 70
compaction_graph = "$share_dir/graphs/zinc-compaction.circuitry.yaml"
default_model = "gemma-heretic"

[models.gemma-heretic]
engine = "llama-cpp-turboquant"
alias = "gemma-4-96e-a4b-heretic-tq"
hf_repo = "WaveCut/Gemma-4-96E-A4B-Heretic-TQ"
hf_file = "Gemma-4-96E-A4B-Heretic-TQ3_1S.gguf"
cache_type_k = "q8_0"
cache_type_v = "turbo3"
fit_ctx = 8192
vram_allocation_percent = $vram_allocation_percent
[models.gemma-heretic.runtime]
tool_format = "gemma-native"
reasoning_effort = "low"
reasoning_format = "auto"
temperature = 0.5
max_tokens = 1024
tool_reasoning = false

[models.gemma-heretic.runtime.budgets]
off = 0
low = 256
medium = 1024
high = 4096
extra-high = -1
EOF_CONFIG

cat > "$bin_dir/zn-setup-turboquant" <<EOF
#!/usr/bin/env bash
exec "$scripts_dir/setup-turboquant-linux.sh" "\$@"
EOF
chmod 0755 "$bin_dir/zn-setup-turboquant"
rm -f "$bin_dir/zn-setup-beellama" "$scripts_dir/setup-beellama-linux.sh" "$bin_dir/zn-serve-qwen36-27b-bee" "$scripts_dir/serve-qwen36-27b-bee.sh" "$bin_dir/zn-serve-gemma-heretic-bee" "$scripts_dir/serve-gemma-heretic-bee.sh" "$bin_dir/zn-serve-gemma-heretic" "$scripts_dir/serve-gemma-heretic-turboquant.sh" "$bin_dir/zn-serve"
"$bin_dir/zn" compile "$share_dir/graphs/zinc-loop.circuitry.yaml" "$share_dir/compiled/plan.json" >/dev/null


echo "installed Zinc: $bin_dir/zn"
echo "installed TurboQuant setup helper: $bin_dir/zn-setup-turboquant"
echo "model server lifecycle: zn up / zn down"
