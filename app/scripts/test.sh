#!/bin/sh
# The test run for every build of Duo Desktop.
#   scripts/test.sh                  the switch check below, then the whole unit suite (both switches, iPhone Duo)
#   scripts/test.sh --switches-only  the switch check only
#
# Switch check: the app must compile in every version, not only the full one TestFlight ships. It builds the app
# (compile only, simulator, unsigned) with NO switches, with only DUO_TERMINAL and with only DUO_JETKVM, and stops
# with a failure if any of them does not compile. (Build 53 to 57: the plain version did not compile because
# Screens.swift used a Terminal-only type outside `#if DUO_TERMINAL`; nothing caught it, because every build had
# both switches on.)
#
# Generates the Xcode project in place for each version and puts the one that was there back at the end.
set -eu
app=$(cd "$(dirname "$0")/.." && pwd)
cd "$app"
out="$app/build/test-run"
mkdir -p "$out"

"$app/scripts/fetch-glassact.sh" >/dev/null

saved="$out/project.pbxproj.saved"
had_project=no
if [ -f DuoDesktop.xcodeproj/project.pbxproj ]; then
    cp DuoDesktop.xcodeproj/project.pbxproj "$saved"
    had_project=yes
fi
# Resolving the packages in the app's project also rewrites DuoTerminalKit's own Package.resolved; keep it as it was.
cp DuoTerminalKit/Package.resolved "$out/Package.resolved.saved"
restore() {
    cp "$out/Package.resolved.saved" DuoTerminalKit/Package.resolved
    [ "$had_project" = yes ] && cp "$saved" DuoDesktop.xcodeproj/project.pbxproj || true
}
trap restore EXIT

failed=""
compile() { # name, then the environment for xcodegen
    name=$1; shift
    env "$@" xcodegen generate --quiet
    if xcodebuild build -project DuoDesktop.xcodeproj -scheme DuoDesktop \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$out/dd-$name" \
        -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO > "$out/compile-$name.log" 2>&1; then
        echo "compiles: $name"
    else
        echo "DOES NOT COMPILE: $name (log: $out/compile-$name.log)"
        grep -E ': error: ' "$out/compile-$name.log" | sort -u | head -10
        failed="$failed $name"
    fi
}
compile plain DUO_TERMINAL= DUO_JETKVM=
compile terminal-only DUO_TERMINAL=YES DUO_JETKVM=
compile jetkvm-only DUO_TERMINAL= DUO_JETKVM=YES
if [ -n "$failed" ]; then
    echo "FAILED: not every version compiles:$failed"
    exit 1
fi
echo "switch check passed: plain, Terminal only and JetKVM only all compile"
[ "${1:-}" = --switches-only ] && exit 0

# The whole unit suite on the full version (both switches), as TestFlight ships it.
DUO_TERMINAL=YES DUO_JETKVM=YES xcodegen generate --quiet
sim=$(xcrun simctl list devices available | sed -n 's/^ *iPhone Duo (\([0-9A-F-]*\)).*/\1/p' | head -1)
[ -n "$sim" ] || { echo "no iPhone Duo simulator"; exit 1; }
if xcodebuild test -project DuoDesktop.xcodeproj -scheme DuoDesktop -destination "id=$sim" \
    -derivedDataPath "$out/dd-both" -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
    > "$out/test-both.log" 2>&1; then
    grep -E 'Executed [0-9]+ tests' "$out/test-both.log" | tail -1
    echo "test run passed"
else
    grep -E 'error:|failed|Executed [0-9]+ tests' "$out/test-both.log" | tail -15
    echo "FAILED: unit tests (log: $out/test-both.log)"
    exit 1
fi
