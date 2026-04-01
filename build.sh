#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="$SCRIPT_DIR/_BuildOutput"
INTERMEDIATE="$SCRIPT_DIR/build"
SIGN_IDENTITY="2130627FC82A7E78F4069F3CC3ABE5BDA1B3D836"
TEAM_ID="EG86BCGUE7"

echo "==> Cleaning..."
rm -rf "$BUILD_DIR" "$INTERMEDIATE"
mkdir -p "$BUILD_DIR"

# Strip xattrs from source tree
xattr -cr "$SCRIPT_DIR" 2>/dev/null || true

echo "==> Building ASCIISaver.saver..."
xcodebuild -project ASCIISaver.xcodeproj \
    -target ASCIISaver \
    -configuration Release \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tail -3

# Strip xattrs from built .saver before signing
xattr -cr "$BUILD_DIR/ASCIISaver.saver"
codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "ScreenSaver/ASCIISaver.entitlements" \
    "$BUILD_DIR/ASCIISaver.saver"

echo "==> Building ASCIISaverCameraAgent.app..."
xcodebuild -project ASCIISaver.xcodeproj \
    -target ASCIISaverCameraAgent \
    -configuration Release \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    build 2>&1 | tail -3

# Strip xattrs and sign
xattr -cr "$BUILD_DIR/ASCIISaverCameraAgent.app"
codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "CameraAgent/ASCIISaverCameraAgent.entitlements" \
    "$BUILD_DIR/ASCIISaverCameraAgent.app"

# Clean up intermediate build artifacts
rm -rf "$BUILD_DIR"/*.swiftmodule "$BUILD_DIR"/*.dSYM "$INTERMEDIATE"

echo ""
echo "==> Verifying code signatures..."
codesign -dv "$BUILD_DIR/ASCIISaver.saver" 2>&1 | grep -E "Identifier|Team"
codesign -dv "$BUILD_DIR/ASCIISaverCameraAgent.app" 2>&1 | grep -E "Identifier|Team"

echo ""
echo "==> Build complete!"
echo "    Screensaver: $BUILD_DIR/ASCIISaver.saver"
echo "    Camera Agent: $BUILD_DIR/ASCIISaverCameraAgent.app"
echo ""
echo "To install manually:"
echo "    cp -R \"$BUILD_DIR/ASCIISaver.saver\" ~/Library/Screen\\ Savers/"
echo "    cp -R \"$BUILD_DIR/ASCIISaverCameraAgent.app\" /Applications/"
echo ""
echo "To build the installer package:"
echo "    ./Installer/build_pkg.sh"
