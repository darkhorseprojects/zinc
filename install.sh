#!/bin/sh
set -eu

source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ -z "$1" ]; }; then
    printf 'usage: %s [DESTINATION]\n' "$0" >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then
    destination=$1
elif [ "$(uname -s)" = Darwin ]; then
    destination="${HOME:?}/Library/Application Support/Zinc"
else
    destination=${XDG_DATA_HOME:-${HOME:?}/.local/share}/zinc
fi
for path in package/zinc.md package/native/lsqlite3complete.so data/cygnet.db ac.yaml models.ini \
    install.sh install.ps1 lux.toml lux.lock models.lock README.md RELEASE_NOTES.md LICENSE NOTICE; do
    if [ ! -s "$source/$path" ]; then
        printf 'Zinc release payload is incomplete: %s\n' "$path" >&2
        exit 1
    fi
done
mkdir -p "$destination"
destination=$(CDPATH= cd -- "$destination" && pwd)
if [ "$destination" = / ]; then
    printf 'Refusing to install Zinc at the filesystem root\n' >&2
    exit 2
fi
mkdir -p "$destination/state"
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
    if ! cmp -s "$source/ac.yaml" "$destination/ac.yaml"; then
        printf 'Preserved ac.yaml; verify Connector YAML 2 and Zinc 0.2 settings before running. Older config is not migrated.\n' >&2
    fi
fi
printf '%s\n' "$destination"
