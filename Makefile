# ASCII Saver — multi-target screensaver + camera-agent helper.
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release. Two Xcode targets:
#   ASCIISaver               (.saver, ships to /Library/Screen Savers)
#   ASCIISaverCameraAgent    (.app helper, ships to /Applications)
# Combined into a single signed installer via productbuild +
# Installer/Distribution.xml.

BUNDLE_NAME      := ASCIISaver
BUNDLE_TYPE      := saver
PRODUCT_NAME     := ASCIISaver.saver
BUNDLE_ID        := com.jorviksoftware.ASCIISaver
BUILD_SYSTEM     := xcode

XCODE_PROJECT    := ASCIISaver.xcodeproj
XCODE_SCHEME     := ASCIISaver
ENTITLEMENTS     := ScreenSaver/ASCIISaver.entitlements

PACKAGE_TYPE     := pkg
ALSO_SHIP_PKG    := false

# ── Multi-component installer ────────────────────────────────────────────────
DISTRIBUTION_XML    := Installer/Distribution.xml
PKG_RESOURCES       := Installer
PKG_MAIN_IDENTIFIER := com.jorviksoftware.ASCIISaver.saver
PKG_MAIN_FILENAME   := ASCIISaver-saver.pkg
PKG_MAIN_SCRIPTS    := Installer/scripts

# Helper records (one per line continuation):
#   <xcodeTarget>:<productName>:<entitlements>:<pkgIdentifier>:<pkgFilename>
HELPER_TARGETS := ASCIISaverCameraAgent:ASCIISaverCameraAgent.app:CameraAgent/ASCIISaverCameraAgent.entitlements:com.jorviksoftware.ASCIISaver.agent:ASCIISaver-agent.pkg

include ../jorvik-release/release.mk
