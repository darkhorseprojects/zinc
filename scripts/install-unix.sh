#!/usr/bin/env sh
set -eu

repo="darkhorseprojects/zinc"
version="latest"
prefix="${PREFIX:-$HOME/.local}"
archive=""

usage() {
  cat <<'EOF'
Usage: install-unix.sh [--version vX.Y.Z] [--prefix DIR] [--archive FILE]

Installs the Zinc binary on Linux or macOS.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --archive) archive="$2"; shift 2 ;;
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

bin_dir="$prefix/bin"

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT HUP TERM

if [ -n "$archive" ]; then
  cp "$archive" "$tmp/$asset"
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

need tar
tar -xzf "$tmp/$asset" -C "$tmp"

if [ ! -f "$tmp/zn" ]; then
  echo "release archive did not contain zn" >&2
  exit 1
fi

mkdir -p "$bin_dir"
install -m 0755 "$tmp/zn" "$bin_dir/zn"

echo "installed Zinc: $bin_dir/zn"
echo "Make sure $bin_dir is in your PATH."
