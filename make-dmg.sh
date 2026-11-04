#!/bin/bash
# Builds the app, then packs it with the BlackHole installers and instructions into
# dist/MicFlow <version>.dmg for sharing. Needs the BlackHole installers that
# `brew install blackhole-2ch blackhole-16ch` left in Homebrew's Caskroom.
set -euo pipefail
cd "$(dirname "$0")"

# The public download is always the visitor edition: no Admin/ code in it.
MICFLOW_EDITION=visitor ./build.sh
if strings build/MicFlow.app/Contents/MacOS/MicFlow | grep -q "ContentAdminView\|ContentPublisher\|ADMIN BUILD"; then
    echo "Stopped: admin code found in the build." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
CASKROOM="$(brew --prefix)/Caskroom"
PKG_2CH=$(ls "$CASKROOM"/blackhole-2ch/*/BlackHole2ch-*.pkg | tail -1)
PKG_16CH=$(ls "$CASKROOM"/blackhole-16ch/*/BlackHole16ch-*.pkg | tail -1)

STAGE=build/dmg
rm -rf "$STAGE"
mkdir -p "$STAGE" dist
ditto "build/MicFlow.app" "$STAGE/MicFlow.app"
ln -s /Applications "$STAGE/Applications"
cp "$PKG_2CH" "$STAGE/1 Install BlackHole 2ch.pkg"
cp "$PKG_16CH" "$STAGE/2 Install BlackHole 16ch.pkg"
cp "Packaging/Read Me First.txt" "$STAGE/"
# The license text ships inside each BlackHole installer.
pkgutil --expand "$PKG_2CH" build/obj/pkg-2ch
cp build/obj/pkg-2ch/Resources/LICENSE "$STAGE/BlackHole License.txt"
rm -rf build/obj/pkg-2ch

DMG="dist/MicFlow $VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "MicFlow" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Created $DMG"
