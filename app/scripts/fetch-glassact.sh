#!/bin/sh
# Makes vendor/glassact if missing: Glass Act at GLASSACT_COMMIT plus the patches in GLASSACT_PATCHES
# (in order), then checks it. Upstream updates are by hand only: read the diff, change GLASSACT_COMMIT, redo the
# patches on the new commit, rebuild, rerun the tests.
set -eu
app=$(cd "$(dirname "$0")/.." && pwd)
vendor="$app/../vendor/glassact"
want=$(tr -d '[:space:]' < "$app/GLASSACT_COMMIT")
if [ ! -d "$vendor/.git" ]; then
    git clone https://github.com/brianmario/glassact "$vendor"
    git -C "$vendor" checkout --detach "$want"
    for p in $(grep -v '^#' "$app/GLASSACT_PATCHES"); do git -C "$vendor" apply "$app/../patches/$p"; done
fi
exec "$app/scripts/check-glassact.sh"
