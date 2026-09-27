#!/bin/sh
set -eu

source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -f "$source/data/cygnet.db" ] || ! find "$source/package/native" -type f -name 'lsqlite3complete.*' | grep -q .; then
    printf 'Zinc release payload is incomplete\n' >&2
    exit 1
fi
if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION]\n' "$0" >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then
    destination=$1
elif [ "$(uname -s)" = Darwin ]; then
    destination=${HOME:?}/Library/Application Support/Zinc
else
    destination=${XDG_DATA_HOME:-${HOME:?}/.local/share}/zinc
fi
mkdir -p "$destination/state"
destination=$(CDPATH= cd -- "$destination" && pwd)
if [ "$source" != "$destination" ]; then
    for path in package data; do
        rm -rf "$destination/$path"
        cp -R "$source/$path" "$destination/$path"
    done
    for path in install.sh install.ps1 lux.toml lux.lock models.lock README.md RELEASE_NOTES.md LICENSE NOTICE; do
        cp "$source/$path" "$destination/$path"
    done
    for path in ac.yaml models.ini; do
        if [ ! -e "$destination/$path" ]; then
            cp "$source/$path" "$destination/$path"
        fi
    done
fi
printf '%s\n' "$destination"
