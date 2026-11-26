#!/bin/zsh
# Builds "Artifact Widgets.app" (universal: Apple Silicon + Intel) into ./build.
#   ./build.sh            build only
#   ./build.sh --install  build, then copy to ~/Applications and quit any running copy
#   ./build.sh --package  build, then make dist/Artifact-Widgets-<version>.dmg to share
# Needs only Apple's Command Line Tools (xcode-select --install), not full Xcode.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0"
APP="build/Artifact Widgets.app"
BIN="ArtifactWidgets"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" \
    -framework AppKit -framework WebKit -framework ServiceManagement \
    Sources/main.swift -o "build/obj/$BIN-$arch"
done
lipo -create "build/obj/$BIN-arm64" "build/obj/$BIN-x86_64" -output "$APP/Contents/MacOS/$BIN"

[[ -f Resources/AppIcon.icns ]] || swift tools/make_icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Artifact Widgets</string>
  <key>CFBundleDisplayName</key><string>Artifact Widgets</string>
  <key>CFBundleIdentifier</key><string>local.artifactwidgets</string>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$BIN"))"

case "${1:-}" in
  --install)
    mkdir -p ~/Applications
    pkill -x "$BIN" 2>/dev/null && sleep 1 || true
    rm -rf ~/Applications/"Artifact Widgets.app"
    cp -R "$APP" ~/Applications/
    echo "Installed to ~/Applications/Artifact Widgets.app"
    ;;
  --package)
    STAGE="build/dmg"
    DMG="dist/Artifact-Widgets-$VERSION.dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE" dist
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp INSTALL.txt "$STAGE/Read Me First.txt"
    hdiutil create -volname "Artifact Widgets" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    echo "Packaged $DMG ($(du -h "$DMG" | cut -f1))"
    ;;
esac
