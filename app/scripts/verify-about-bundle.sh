#!/bin/sh
# Checks a BUILT Duo Desktop .app for every notice About shows (plan §9, M4 acceptance; the reviewer: "Verify the
# actual built About bundle"). Usage: scripts/verify-about-bundle.sh path/to/DuoDesktop.app
set -u
APP="${1:?usage: verify-about-bundle.sh DuoDesktop.app}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GA="$HERE/../vendor/glassact"
fail=0
check() { # file, text that must be in it
  if [ ! -f "$APP/$1" ]; then echo "MISSING  $1"; fail=1; return; fi
  if grep -qF -- "$2" "$APP/$1"; then echo "ok       $1: $2"; else echo "ABSENT   $1: $2"; fail=1; fi
}
same() { # bundled file, source file
  if cmp -s "$APP/$1" "$2"; then echo "ok       $1 = $(basename "$2") at the pin"; else echo "DIFFERS  $1"; fail=1; fi
}
check Acknowledgements.txt "# Glass Act"
check Acknowledgements.txt "Copyright (c) 2026 Brian Lopez"
check Acknowledgements.txt "# libwebp 1.5.0"
check Acknowledgements.txt "Additional IP Rights Grant (Patents)"
check Acknowledgements.txt "# libaom"
check Acknowledgements.txt "Alliance for Open Media Patent License 1.0"
check Acknowledgements.txt "# av1gpu"
check GlassActLICENSE.txt "MIT License"
check RustAV1ThirdPartyNotices.md "# Third-party notices"
check RustAV1ThirdPartyNotices.md "## libaom (Alliance for Open Media)"
check RustAV1ThirdPartyNotices.md "## AV1 patents"
check DuoDesktopNotice.txt "Apps/iPad/SessionModel.swift and Apps/iPad/CanvasView.swift"
check DuoDesktopNotice.txt "Permission is hereby granted"
check GLASSACT_COMMIT "$(cat "$HERE/GLASSACT_COMMIT")"
same Acknowledgements.txt "$GA/Apps/Shared/Acknowledgements.txt"
same GlassActLICENSE.txt "$GA/LICENSE"
same RustAV1ThirdPartyNotices.md "$GA/rust/av1/THIRD_PARTY_NOTICES.md"
# The copied source files still carry their MIT header.
for f in SessionModel.swift CanvasView.swift; do
  if head -2 "$HERE/DuoDesktop/$f" | grep -q "MIT licensed"; then echo "ok       source header: $f"
  else echo "ABSENT   source header: $f"; fail=1; fi
done
[ $fail -eq 0 ] && echo "PASS: every notice is in the built app" || echo "FAIL"
exit $fail
