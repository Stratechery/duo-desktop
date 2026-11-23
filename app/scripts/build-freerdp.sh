#!/bin/sh
# Builds the Remote Desktop engine for the DUO_RDP switch (project notes, Remote Desktop milestone 0;
# the owner 2026-11-22: "Yes on library."): FreeRDP 3 and OpenSSL 3, static, for iPhone and the iPhone simulator (arm64),
# into one xcframework:
#   ../vendor/freerdp-build/FreeRDP.xcframework   (libfreerdp-all.a + headers per platform)
#
# Third-party source is fetched here at pinned tags (and checked against the pinned commit), never copied into
# this repository, as the Glass Act fetch does. FFmpeg and OpenH264 are OFF (LGPL / patents); H.264 uses Apple's
# own decoder (WITH_APPLE_VIDEOTOOLBOX). No other outside library is linked (no JPEG, PNG, WebP, Opus, cJSON,
# Kerberos, PC/SC); Notices/RemoteDesktopNotice.txt lists the two that are.
#
# Usage: scripts/build-freerdp.sh          builds if the xcframework is missing or the pins changed
#        scripts/build-freerdp.sh --force  rebuilds
set -eu
FREERDP_TAG=3.33.1
FREERDP_COMMIT=65bcca1913a28cbdd7eb913599f692bd2b707991
OPENSSL_TAG=openssl-3.6.5
OPENSSL_COMMIT=c8bd5a57108599ac650bbae77fcabe3109dab2e8
IOS_MIN=27.0

app=$(cd "$(dirname "$0")/.." && pwd)
root="$app/../vendor/freerdp-build"
mkdir -p "$root/src"
root=$(cd "$root" && pwd)
src="$root/src"
out="$root/FreeRDP.xcframework"
stamp="$root/built-pins"
pins="$FREERDP_COMMIT $OPENSSL_COMMIT $IOS_MIN"
if [ "${1:-}" != --force ] && [ -d "$out" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$pins" ]; then
    echo "FreeRDP.xcframework is current ($FREERDP_TAG, $OPENSSL_TAG)"; exit 0
fi
jobs=$(sysctl -n hw.ncpu)

fetch() { # dir url tag commit
    if [ ! -d "$src/$1/.git" ]; then
        git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" "$2" "$src/$1"
    fi
    have=$(git -C "$src/$1" rev-parse HEAD)
    [ "$have" = "$4" ] || { echo "PIN MISMATCH: $1 is $have, want $4 ($3)"; exit 1; }
}
fetch openssl https://github.com/openssl/openssl "$OPENSSL_TAG" "$OPENSSL_COMMIT"
fetch freerdp https://github.com/FreeRDP/FreeRDP "$FREERDP_TAG" "$FREERDP_COMMIT"

build_openssl() { # sdk openssl-target min-version-flag
    pre="$root/$1/openssl"
    [ -f "$pre/lib/libssl.a" ] && return 0
    b="$root/$1/openssl-build"; rm -rf "$b"; mkdir -p "$b"
    ( cd "$b" && "$src/openssl/Configure" "$2" no-shared no-tests no-apps no-docs no-dso no-engine \
        no-async no-module "$3=$IOS_MIN" --prefix="$pre" --libdir=lib > configure.log \
      && make -j"$jobs" > make.log 2>&1 && make install_sw > install.log 2>&1 )
}

build_freerdp() { # sdk
    sdk=$1; pre="$root/$sdk/freerdp"; b="$root/$sdk/freerdp-build"
    rm -rf "$b" "$pre"; mkdir -p "$b"
    cmake -S "$src/freerdp" -B "$b" -G "Unix Makefiles" \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN -DIOS_TARGET_SDK=$IOS_MIN \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -DCMAKE_INSTALL_PREFIX="$pre" -DCMAKE_PREFIX_PATH="$root/$sdk/openssl" \
        -DCMAKE_FIND_ROOT_PATH="$root/$sdk/openssl" \
        -DOPENSSL_ROOT_DIR="$root/$sdk/openssl" -DOPENSSL_USE_STATIC_LIBS=ON \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DWITH_MANPAGES=OFF \
        -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF \
        -DWITH_SHADOW=OFF -DWITH_PROXY=OFF -DWITH_PLATFORM_SERVER=OFF -DWITH_CHANNELS=ON \
        -DWITH_CLIENT_CHANNELS=ON -DWITH_SERVER_CHANNELS=OFF -DCHANNEL_URBDRC=OFF -DWITH_X11=OFF \
        -DWITH_WAYLAND=OFF -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_FUSE=OFF \
        -DWITH_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF -DWITH_SWSCALE=OFF \
        -DWITH_OPENH264=OFF -DWITH_APPLE_VIDEOTOOLBOX=ON \
        -DWITH_JPEG=OFF -DWITH_OPUS=OFF -DWITH_FAAD2=OFF -DWITH_FAAC=OFF -DWITH_LAME=OFF -DWITH_SOXR=OFF \
        -DWITH_GSM=OFF -DWITH_KRB5=OFF -DWITH_AAD=OFF -DWITH_WINPR_JSON=OFF -DWITH_CJSON_REQUIRED=OFF \
        -DWITH_JSONC_REQUIRED=OFF -DWITH_URIPARSER=OFF -DWITH_WEBVIEW=OFF -DWITH_LIBSYSTEMD=OFF \
        -DWITH_PKCS11=OFF -DWITH_SIMD=ON -DWITH_UNICODE_BUILTIN=ON -DWITH_TIMEZONE_ICU=OFF \
        -DWITH_INTERNAL_RC4=ON -DWITH_INTERNAL_MD4=ON \
        -DWITH_MBEDTLS=OFF -DWITH_OPENSSL=ON -DWITH_ALSA=OFF -DWITH_PULSE=OFF -DWITH_OSS=OFF \
        > "$root/$sdk/freerdp-configure.log" 2>&1 \
        || { tail -30 "$root/$sdk/freerdp-configure.log"; echo "FreeRDP configure failed ($sdk)"; exit 1; }
    cmake --build "$b" -j"$jobs" > "$root/$sdk/freerdp-make.log" 2>&1 \
        || { grep -E 'error' "$root/$sdk/freerdp-make.log" | head -20; echo "FreeRDP build failed ($sdk)"; exit 1; }
    cmake --install "$b" > /dev/null
    # One static library per platform: FreeRDP, its client library, WinPR, the static channels, and OpenSSL.
    libs=$(find "$pre/lib" -name '*.a'; echo "$root/$sdk/openssl/lib/libssl.a"; echo "$root/$sdk/openssl/lib/libcrypto.a")
    mkdir -p "$root/$sdk/all/include"
    # shellcheck disable=SC2086
    libtool -static -no_warning_for_no_symbols -o "$root/$sdk/all/libfreerdp-all.a" $libs
    # Flat headers (freerdp/, winpr/, openssl/) and a module the app imports as `import FreeRDP` (DUO_RDP only).
    rm -rf "$root/$sdk/all/include"; mkdir -p "$root/$sdk/all/include"
    cp -R "$pre/include/freerdp3/." "$pre/include/winpr3/." "$root/$sdk/openssl/include/." "$root/$sdk/all/include/"
    printf '#include <freerdp/freerdp.h>\n#include <freerdp/client.h>\n' > "$root/$sdk/all/include/duo_freerdp.h"
    printf 'module FreeRDP [system] {\n  header "duo_freerdp.h"\n  export *\n}\n' \
        > "$root/$sdk/all/include/module.modulemap"
}

build_openssl iphoneos ios64-xcrun -mios-version-min
build_openssl iphonesimulator iossimulator-arm64-xcrun -mios-simulator-version-min
build_freerdp iphoneos
build_freerdp iphonesimulator

rm -rf "$out"
xcodebuild -create-xcframework \
    -library "$root/iphoneos/all/libfreerdp-all.a" -headers "$root/iphoneos/all/include" \
    -library "$root/iphonesimulator/all/libfreerdp-all.a" -headers "$root/iphonesimulator/all/include" \
    -output "$out" > /dev/null
# Licence texts for the notice check (scripts/verify-about-bundle.sh compares them with the bundled notice).
cp "$src/freerdp/LICENSE" "$root/FreeRDP-LICENSE.txt"
cp "$src/openssl/LICENSE.txt" "$root/OpenSSL-LICENSE.txt"
echo "$pins" > "$stamp"
echo "built $out ($FREERDP_TAG, $OPENSSL_TAG)"
du -sh "$root/iphoneos/all/libfreerdp-all.a"
