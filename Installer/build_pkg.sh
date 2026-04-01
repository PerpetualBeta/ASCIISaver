#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/_BuildOutput"
PKG_DIR="$SCRIPT_DIR/_pkg_staging"

VERSION="1.0.0"
PKG_NAME="ASCIISaver-Installer"

# Check that build output exists
if [ ! -d "$BUILD_DIR/ASCIISaver.saver" ] || [ ! -d "$BUILD_DIR/ASCIISaverCameraAgent.app" ]; then
    echo "ERROR: Build output not found. Run ./build.sh first."
    exit 1
fi

echo "==> Preparing package staging..."
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

# Make postinstall executable
chmod +x "$SCRIPT_DIR/scripts/postinstall"

echo "==> Building component: ASCIISaver-saver.pkg..."
pkgbuild \
    --root "$BUILD_DIR/ASCIISaver.saver" \
    --identifier "com.jorviksoftware.ASCIISaver.saver" \
    --version "$VERSION" \
    --install-location "/Library/Screen Savers/ASCIISaver.saver" \
    --scripts "$SCRIPT_DIR/scripts" \
    "$PKG_DIR/ASCIISaver-saver.pkg"

echo "==> Building component: ASCIISaver-agent.pkg..."
pkgbuild \
    --root "$BUILD_DIR/ASCIISaverCameraAgent.app" \
    --identifier "com.jorviksoftware.ASCIISaver.agent" \
    --version "$VERSION" \
    --install-location "/Applications/ASCIISaverCameraAgent.app" \
    "$PKG_DIR/ASCIISaver-agent.pkg"

echo "==> Building distribution package..."
productbuild \
    --distribution "$SCRIPT_DIR/Distribution.xml" \
    --resources "$SCRIPT_DIR" \
    --package-path "$PKG_DIR" \
    --sign "Developer ID Installer: Jonthan Hollin (EG86BCGUE7)" \
    "$BUILD_DIR/$PKG_NAME.pkg"

echo "==> Cleaning up staging..."
rm -rf "$PKG_DIR"

echo ""
echo "==> Package built: $BUILD_DIR/$PKG_NAME.pkg"
echo ""
echo "To verify: pkgutil --check-signature '$BUILD_DIR/$PKG_NAME.pkg'"
