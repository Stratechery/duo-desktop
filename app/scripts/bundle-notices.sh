#!/bin/sh
# Xcode build phase: copy the notices the app must carry into the app bundle (plan §9, M4), from the pinned
# Glass Act checkout (the pre-build pin check has already run) and this app's own notice.
set -eu
GA="$SRCROOT/../vendor/glassact"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST"
cp "$GA/Apps/Shared/Acknowledgements.txt"   "$DEST/Acknowledgements.txt"
cp "$GA/LICENSE"                            "$DEST/GlassActLICENSE.txt"
cp "$GA/rust/av1/THIRD_PARTY_NOTICES.md"    "$DEST/RustAV1ThirdPartyNotices.md"
cp "$SRCROOT/Notices/DuoDesktopNotice.txt"  "$DEST/DuoDesktopNotice.txt"
cp "$SRCROOT/GLASSACT_COMMIT"               "$DEST/GLASSACT_COMMIT"
# The Terminal build only: SwiftTerm's licence and the SSH engine's (SwiftNIO) notices.
if [ -n "${DUO_TERMINAL_FLAG:-}" ]; then
  cp "$SRCROOT/Notices/TerminalNotice.txt"  "$DEST/TerminalNotice.txt"
else
  rm -f "$DEST/TerminalNotice.txt"
fi
# The JetKVM build only: WebRTC's licence (and its packaging's).
if [ -n "${DUO_JETKVM_FLAG:-}" ]; then
  cp "$SRCROOT/Notices/JetKVMNotice.txt"    "$DEST/JetKVMNotice.txt"
else
  rm -f "$DEST/JetKVMNotice.txt"
fi
