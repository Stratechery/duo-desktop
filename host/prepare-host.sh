#!/bin/sh
# Gets Glass Act at the pinned commit and applies the Host patches in order (patches/HOST_PATCHES).
# Usage: host/prepare-host.sh [folder]     (default: vendor/glassact-host, next to app/)
# Stops at the first patch that does not apply. Run it on an empty or missing folder.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
dest=${1:-"$repo/vendor/glassact-host"}
want=$(tr -d '[:space:]' < "$repo/app/GLASSACT_COMMIT")
if [ -e "$dest" ]; then echo "error: $dest already exists; remove it or name another folder" >&2; exit 1; fi
git clone https://github.com/brianmario/glassact "$dest"
git -C "$dest" checkout --quiet --detach "$want"
for p in $(grep -v '^#' "$repo/patches/HOST_PATCHES"); do
    git -C "$dest" apply "$repo/patches/$p"
    echo "applied $p"
done
echo "ready: $dest (Glass Act $want + $(grep -vc '^#' "$repo/patches/HOST_PATCHES") patches)"
