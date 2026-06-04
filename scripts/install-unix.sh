#!/usr/bin/env sh
set -eu

repo="darkhorseprojects/zinc"
version="latest"
prefix="${PREFIX:-$HOME/.local}"
archive=""
run_doctor=1

usage() {
  cat <<'EOF'
Usage: install-unix.sh [--version vX.Y.Z] [--prefix DIR] [--archive FILE] [--no-doctor]

Installs Zinc release assets on Linux or macOS, including stock graphs, prompts,
and the default config when one does not already exist.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --archive) archive="$2"; shift 2 ;;
    --no-doctor) run_doctor=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

os_name="$(uname -s)"
machine="$(uname -m)"
case "$os_name:$machine" in
  Linux:x86_64|Linux:amd64) asset="zinc-linux-x86_64.tar.gz" ;;
  Darwin:x86_64|Darwin:amd64) asset="zinc-macos-x86_64.tar.gz" ;;
  Darwin:arm64|Darwin:aarch64) asset="zinc-macos-aarch64.tar.gz" ;;
  *) echo "unsupported platform: $os_name $machine" >&2; exit 1 ;;
esac

case "$os_name" in
  Linux)
    config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/zinc"
    data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/zinc"
    ;;
  Darwin)
    config_dir="$HOME/Library/Application Support/zinc"
    data_dir="$HOME/Library/Application Support/zinc"
    ;;
esac

bin_dir="$prefix/bin"
config_file="$config_dir/config.yaml"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT HUP TERM

if [ -n "$archive" ]; then
  cp "$archive" "$tmp/$asset"
else
  need curl
  if [ "$version" = "latest" ]; then
    url="https://github.com/$repo/releases/latest/download/$asset"
  else
    url="https://github.com/$repo/releases/download/$version/$asset"
  fi
  curl -fL "$url" -o "$tmp/$asset"
fi

need tar
tar -xzf "$tmp/$asset" -C "$tmp"

if [ ! -f "$tmp/zn" ]; then
  echo "release archive did not contain zn" >&2
  exit 1
fi
if [ ! -d "$tmp/stock" ]; then
  echo "release archive did not contain stock assets" >&2
  exit 1
fi

mkdir -p "$bin_dir" "$data_dir" "$config_dir"
install -m 0755 "$tmp/zn" "$bin_dir/zn"
rm -rf "$data_dir/graphs" "$data_dir/prompts"
cp -R "$tmp/stock/graphs" "$data_dir/graphs"
cp -R "$tmp/stock/prompts" "$data_dir/prompts"
chmod -R u+rwX,go+rX "$data_dir/graphs" "$data_dir/prompts"

if [ ! -f "$config_file" ]; then
  cp "$tmp/stock/config.yaml" "$config_file"
  chmod 600 "$config_file"
fi

echo "installed Zinc: $bin_dir/zn"
echo "installed stock assets: $data_dir"
echo "config: $config_file"

if [ "$run_doctor" -eq 1 ]; then
  "$bin_dir/zn" doctor
else
  echo "run doctor: $bin_dir/zn doctor"
fi
