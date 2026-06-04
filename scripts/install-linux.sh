#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="$HOME/.local"
bin_dir="$prefix/bin"
share_dir="$prefix/share/zinc"
config_dir="$HOME/.config/zinc"
config_file="$config_dir/config.yaml"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need zig
need git
need node
need circuitry
if [[ "$(zig version)" != 0.16.* ]]; then
  echo "warning: Zinc was designed against Zig 0.16.x; found $(zig version)" >&2
fi
circuitry_bin="$(command -v circuitry)"
circuitry_version="$(node -e 'const fs=require("fs"),path=require("path"); const bin=fs.realpathSync(process.argv[1]); console.log(require(path.join(path.dirname(bin), "..", "package.json")).version)' "$circuitry_bin" 2>/dev/null || true)"
case "$circuitry_version" in
  0.5.*|[1-9].*) ;;
  *) echo "Zinc requires circuitry >= 0.5.0; found ${circuitry_version:-unknown}" >&2; exit 1 ;;
esac

cd "$root"
zig build -Doptimize=ReleaseFast

mkdir -p "$bin_dir" "$share_dir/graphs" "$share_dir/prompts" "$config_dir"
install -m 0755 "$root/zig-out/bin/zn" "$bin_dir/zn"
install -m 0644 "$root/stock/graphs/zinc-loop.circuitry.yaml" "$share_dir/graphs/zinc-loop.circuitry.yaml"
install -m 0644 "$root/stock/graphs/zinc-agent.circuitry.yaml" "$share_dir/graphs/zinc-agent.circuitry.yaml"
install -m 0644 "$root/stock/graphs/zinc-context-recovery.circuitry.yaml" "$share_dir/graphs/zinc-context-recovery.circuitry.yaml"
install -m 0644 "$root/stock/graphs/zinc-compaction.circuitry.yaml" "$share_dir/graphs/zinc-compaction.circuitry.yaml"
install -m 0644 "$root/stock/prompts/circuitry-author.md" "$share_dir/prompts/circuitry-author.md"
install -m 0644 "$root/stock/prompts/bash-guide.md" "$share_dir/prompts/bash-guide.md"

if [[ ! -f "$config_file" ]]; then
cat > "$config_file" <<EOF_CONFIG
default_model: qwen-heretic-mtp
scope: project

tools:
  bash: build
  graph_runs: ask

confirm_commands:
  - rm
  - rmdir
  - sudo
  - su
  - chmod
  - chown
  - dd
  - mkfs
  - mount
  - umount
  - kill
  - pkill
  - shutdown
  - reboot

paths:
  graph: $share_dir/graphs/zinc-loop.circuitry.yaml
  context_graph: $share_dir/graphs/zinc-context-recovery.circuitry.yaml
  compaction_graph: $share_dir/graphs/zinc-compaction.circuitry.yaml

runtime:
  provider_max_retries: 5
  tool_max_turns: 12
  compaction_threshold_percent: 70
  compaction_max_tokens: 4096
  session_head_messages: 6
  session_tail_messages: 12
  replay_truncate_chars: 2048
  bash_output_max_bytes: 51200
  bash_output_max_lines: 2000
  bash_capture_max_bytes: 67108864
  file_read_max_bytes: 1048576
  file_range_read_max_bytes: 8388608
  file_edit_max_bytes: 8388608
  resource_read_max_bytes: 33554432
  input_text_file_max_bytes: 8388608
  input_file_max_bytes: 33554432


models:
  qwen-heretic-mtp:
    kind: local
    model: qwen3.6-27b-heretic-mtp-q3_k_s
    base_url: http://127.0.0.1:30000/v1
    llama_cpp:
      engine: llama.cpp
      repo: https://github.com/ggml-org/llama.cpp.git
      ref: master
      cache_type_k: q4_0
      cache_type_v: q4_0
      fit_ctx: 16384
      gpu_layers: fit
      draft_tokens: 2
      reasoning_format: deepseek
      mtp: true
    hf:
      repo: mradermacher/Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved-GGUF
      file: Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved.Q3_K_S.gguf
      mmproj: Qwen3.6-27B-uncensored-heretic-v2-Native-MTP-Preserved.mmproj-Q8_0.gguf
    generation:
      temperature: 0.6
      max_tokens: 128
    reasoning:
      enabled: true
      max: low
      max_tokens:
        off: 0
        low: 32
        medium: 512
        high: 1024
        unlimited: -1
    protocol:
      reasoning:
EOF_CONFIG
fi
chmod 600 "$config_file"

rm -f "$bin_dir/zn-setup-turboquant" "$bin_dir/zn-setup-beellama" "$bin_dir/zn-serve" "$share_dir/scripts/serve-model.sh" "$share_dir/scripts/setup-beellama-linux.sh" "$share_dir/scripts/setup-turboquant-linux.sh"

echo "installed Zinc: $bin_dir/zn"
echo "model server lifecycle: zn serve / zn stop / zn doctor"
