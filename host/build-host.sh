#!/bin/sh
# Builds "Glass Act Host.app" (Release, Apple silicon) from a folder made by host/prepare-host.sh.
# Usage: host/build-host.sh <host folder> "<signing identity>" <team id> <bundle prefix>
#   signing identity: the full name from `security find-identity -v -p codesigning`,
#                     for example "Apple Development: Your Name (ABCDE12345)" or "Developer ID Application: …"
#   team id:          your 10-character Apple developer team id
#   bundle prefix:    for example com.yourname.glassact (the Host's bundle id becomes <prefix>.host)
# Updates are turned off (no Sparkle key) and the Host gets no keychain entitlement, so no provisioning
# profile is needed; it keeps its own key in a file in ~/Library/Application Support/Glass Act/.
set -eu
[ $# -eq 4 ] || { sed -n '2,8p' "$0" >&2; exit 2; }
src=$(cd "$1" && pwd); identity=$2; team=$3; prefix=$4
PATH="/opt/homebrew/opt/rustup/bin:$PATH:${CARGO_HOME:-$HOME/.cargo}/bin"; export PATH
printf 'DEVELOPMENT_TEAM = %s\nGLASSACT_BUNDLE_PREFIX = %s\n' "$team" "$prefix" > "$src/Apps/Signing.local.xcconfig"
commit=$(git -C "$src" rev-parse --short=7 HEAD)
cd "$src/Apps"
xcodebuild -project GlassActApps.xcodeproj -scheme Host -configuration Release ARCHS=arm64 \
  -derivedDataPath "$src/.host-build" \
  'GLASSACT_SPARKLE_PUBLIC_KEY=' CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" \
  PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS=Shared/Host-NoTeam.entitlements \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO "GLASSACT_COMMIT=$commit" build
app="$src/.host-build/Build/Products/Release/Glass Act Host.app"
codesign --verify --deep --strict "$app"
key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist" 2>/dev/null || true)
[ -z "$key" ] || { echo "error: the built Host has an update key; it would replace itself with upstream" >&2; exit 1; }
echo "built: $app"
