#!/bin/sh
# Fails unless vendor/glassact is exactly GLASSACT_COMMIT plus the patches in GLASSACT_PATCHES, with nothing else
# changed or added, in everything the app builds from. Apps/ (the Mac Host and Viewer apps) is left out: the iPhone app
# never compiles it, and Host-only patches (host-macos15-setup-window.patch) are made in this same copy. Build output
# (.build, rust/av1/target) is ignored upstream, so it doesn't count. How: build the expected tree in a throwaway git
# index (pin + patches) and the actual tree from the working copy in another; the two tree hashes must match. Neither
# touches the working copy or its real index.
set -eu
app=$(cd "$(dirname "$0")/.." && pwd)
vendor="$app/../vendor/glassact"
patches="$app/../patches"
want=$(tr -d '[:space:]' < "$app/GLASSACT_COMMIT")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git -C "$vendor" cat-file -e "$want^{commit}" 2>/dev/null || { echo "error: $vendor lacks pinned commit $want" >&2; exit 1; }
GIT_INDEX_FILE="$tmp/want" git -C "$vendor" read-tree "$want"
for p in $(grep -v '^#' "$app/GLASSACT_PATCHES"); do
  GIT_INDEX_FILE="$tmp/want" git -C "$vendor" apply --cached "$patches/$p" \
    || { echo "error: $p does not apply on the pin" >&2; exit 1; }
done
expected=$(GIT_INDEX_FILE="$tmp/want" git -C "$vendor" write-tree)
GIT_INDEX_FILE="$tmp/have" git -C "$vendor" read-tree HEAD
GIT_INDEX_FILE="$tmp/have" git -C "$vendor" add -A .
actual=$(GIT_INDEX_FILE="$tmp/have" git -C "$vendor" write-tree)
GIT_INDEX_FILE="$tmp/have" git -C "$vendor" diff --quiet "$expected" "$actual" -- . ':(exclude)Apps' || {
  echo "error: vendor/glassact is not exactly $want + GLASSACT_PATCHES:" >&2
  GIT_INDEX_FILE="$tmp/have" git -C "$vendor" diff --stat "$expected" "$actual" -- . ':(exclude)Apps' >&2; exit 1; }
echo "glassact pinned at $want + $(grep -vc '^#' "$app/GLASSACT_PATCHES") patches, exact outside Apps/"
