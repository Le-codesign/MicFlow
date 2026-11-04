#!/bin/bash
# Builds build/MicFlow.app with the Swift command-line tools (no Xcode needed).
# The app runs on both Apple Silicon and Intel Macs with macOS 13 or later.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MicFlow.app"
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
cp Info.plist "$APP/Contents/Info.plist"

# Two editions from one codebase. The admin edition adds Admin/ (editing the About page and posts);
# it exists only in the private repository. MICFLOW_EDITION=visitor builds the public edition even
# where Admin/ exists; make-dmg.sh always does.
EDITION="${MICFLOW_EDITION:-}"
if [ -z "$EDITION" ]; then
    if [ -d Admin ]; then EDITION=admin; else EDITION=visitor; fi
fi
EXTRA_SOURCES=()
EXTRA_FLAGS=()
if [ "$EDITION" = admin ]; then
    EXTRA_SOURCES=(Admin/*.swift)
    EXTRA_FLAGS=(-D ADMIN)
fi
echo "Building the $EDITION edition"

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -parse-as-library \
        -target "$arch-apple-macos13.0" \
        ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        Sources/*.swift ${EXTRA_SOURCES[@]+"${EXTRA_SOURCES[@]}"} \
        -o "build/obj/MicFlow-$arch"
done
lipo -create build/obj/MicFlow-arm64 build/obj/MicFlow-x86_64 -output "$APP/Contents/MacOS/MicFlow"
cp Resources/* "$APP/Contents/Resources/"

# App icon, from Design/AppIcon.svg.
ICONSET=build/obj/AppIcon.iconset
mkdir -p "$ICONSET"
swift Tools/make-icon.swift Design/AppIcon.svg build/obj/icon-1024.png
for px in 16 32 128 256 512; do
    sips -z $px $px build/obj/icon-1024.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) build/obj/icon-1024.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Sign with the local "Mic Boost Local Signing" certificate (named before the app became MicFlow)
# when this Mac has one: the signature
# then stays the same from build to build, so macOS keeps Accessibility and Keychain permissions.
# Without it, fall back to an ad-hoc signature (permissions must be granted again after each build).
IDENTITY="Mic Boost Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
