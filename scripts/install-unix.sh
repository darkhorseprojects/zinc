#!/usr/bin/env sh
set -eu

repo="darkhorseprojects/zinc"
version="latest"
prefix="${PREFIX:-$HOME/.local}"
binary=""

usage() {
  cat <<'EOF'
Usage: install-unix.sh [--version vX.Y.Z] [--prefix DIR] [--binary FILE]

Installs zn on Linux or macOS.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --binary) binary="$2"; shift 2 ;;
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
  Linux:x86_64|Linux:amd64) asset="zn-x86_64-linux" ;;
  Darwin:x86_64|Darwin:amd64) asset="zn-x86_64-macos" ;;
  Darwin:arm64|Darwin:aarch64) asset="zn-aarch64-macos" ;;
  *) echo "unsupported platform: $os_name $machine" >&2; exit 1 ;;
esac

bin_dir="$prefix/bin"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT HUP TERM

if [ -n "$binary" ]; then
  cp "$binary" "$tmp/$asset"
else
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo "Downloading release using GitHub CLI..."
    if [ "$version" = "latest" ]; then
      gh release download -R "$repo" -p "$asset" -O "$tmp/$asset"
    else
      gh release download "$version" -R "$repo" -p "$asset" -O "$tmp/$asset"
    fi
  else
    need curl
    if [ "$version" = "latest" ]; then
      url="https://github.com/$repo/releases/latest/download/$asset"
    else
      url="https://github.com/$repo/releases/download/$version/$asset"
    fi
    curl -fL "$url" -o "$tmp/$asset"
  fi
fi

mkdir -p "$bin_dir"
install -m 0755 "$tmp/$asset" "$bin_dir/zn"

echo "installed zn: $bin_dir/zn"
echo "Make sure $bin_dir is in your PATH."
