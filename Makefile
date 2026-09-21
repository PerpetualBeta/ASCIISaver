# ASCII Saver — camera-to-ASCII screensaver delivered as a regular .app.
#
# A background (LSUIElement) app that polls system idle time and shows a
# fullscreen ASCII rendering of the live camera feed when the user has been
# idle past a threshold. Dismisses on any mouse/key event.
#
# Built as `ASCII Saver.app`, not as a `.saver`. The saver bundle is gone, and
# so is the separate ASCIISaverCameraAgent that used to sit beside it: a
# .saver runs inside legacyScreenSaver and cannot hold a camera TCC grant, so
# the camera had to live in its own process and ship frames across through
# shared memory, with settings round-tripped via /tmp because
# ScreenSaverDefaults was not visible to the agent. As one app it simply opens
# the camera. See kb/conventions/screensaver-as-app.md.

# ─── Project identity ────────────────────────────────────────────────────────
BUNDLE_NAME      := ASCIISaver
BUNDLE_TYPE      := app
PRODUCT_NAME     := ASCII Saver.app
# Was com.jorviksoftware.ASCIISaver. Renamed with the collapse to a single app
# to match the rest of the suite; App/Migration.swift carries user settings
# across, and macOS re-prompts for the camera because the identifier changed.
BUNDLE_ID        := cc.jorviksoftware.ASCIISaver
BUILD_SYSTEM     := swiftc

# Ship both a .zip (unzip + drag to /Applications) and a .pkg
# (signed/notarised installer that avoids App Translocation). Replaces the
# two-component Distribution.xml installer the saver+agent pair needed.
PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true

SWIFT_FRAMEWORKS := Cocoa AVFoundation CoreVideo CoreGraphics QuartzCore \
                    Accelerate Vision ServiceManagement Carbon

SWIFT_SOURCES    := App/main.swift App/AppDelegate.swift \
                    App/ScreensaverWindow.swift \
                    App/StatusItem.swift App/SettingsWindow.swift \
                    App/HotkeyManager.swift \
                    App/LockScreen.swift App/Screenshot.swift \
                    App/Migration.swift \
                    App/SparkleDelegate.swift App/Log.swift \
                    Render/ASCIIRenderView.swift \
                    Camera/FrameSource.swift \
                    Camera/CameraCaptureService.swift \
                    Camera/PersonSegmentationService.swift \
                    $(wildcard App/JorvikKit/*.swift)

EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS        := ASCIISaver.entitlements

# Stable signing identity for dev. Ad-hoc (`-`) breaks the camera TCC grant on
# every rebuild — macOS keys permissions on the signature, and this app needs
# the grant to do anything at all.
DEV_SIGN_IDENTITY := Developer ID Application: Jonthan Hollin (EG86BCGUE7)

include ../jorvik-release/release.mk

.DEFAULT_GOAL := dev-build

.PHONY: dev-build run icon

# ─── Dev iteration targets ───────────────────────────────────────────────────

dev-build:
	@echo "→ dev build (arm64, signed Developer ID, Sparkle embedded)"
	@rm -rf "$(PRODUCT_NAME)"
	@mkdir -p "$(PRODUCT_NAME)/Contents/MacOS" "$(PRODUCT_NAME)/Contents/Resources" "$(PRODUCT_NAME)/Contents/Frameworks"
	swiftc -O -target arm64-apple-macos14.0 -sdk $(SDK) \
		$(addprefix -framework ,$(SWIFT_FRAMEWORKS)) \
		-F . \
		-Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
		-module-name $(BUNDLE_NAME) \
		-o "$(PRODUCT_NAME)/Contents/MacOS/$(BUNDLE_NAME)" \
		$(SWIFT_SOURCES)
	cp Info.plist "$(PRODUCT_NAME)/Contents/Info.plist"
	# Mirror Resources/ the way release.mk does, skipping the .iconset source
	# (it is the input to AppIcon.icns, not something to ship). This used to be
	# `cp AppIcon.icns … 2>/dev/null || true`, which silently shipped an
	# icon-less app for several builds because the file did not exist — the old
	# Xcode target got its icon from an asset catalog that went with it.
	@if [[ ! -f Resources/$(ICON_FILE) ]]; then \
		echo "ERROR: Resources/$(ICON_FILE) missing — run 'gmake icon'"; exit 1; \
	fi
	find Resources -mindepth 1 -maxdepth 1 ! -name "*.iconset" -exec cp -R {} "$(PRODUCT_NAME)/Contents/Resources/" \;
	@echo "→ Embedding Sparkle.framework..."
	@cp -R Sparkle.framework "$(PRODUCT_NAME)/Contents/Frameworks/"
	@echo "→ Signing framework leaves-first..."
	@codesign --force --options runtime --timestamp --sign "$(DEV_SIGN_IDENTITY)" \
		"$(PRODUCT_NAME)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>&1 | tail -1
	@codesign --force --options runtime --timestamp --sign "$(DEV_SIGN_IDENTITY)" \
		"$(PRODUCT_NAME)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>&1 | tail -1
	@codesign --force --options runtime --timestamp --sign "$(DEV_SIGN_IDENTITY)" \
		"$(PRODUCT_NAME)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>&1 | tail -1
	@codesign --force --options runtime --timestamp --sign "$(DEV_SIGN_IDENTITY)" \
		"$(PRODUCT_NAME)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>&1 | tail -1
	@codesign --force --options runtime --timestamp --sign "$(DEV_SIGN_IDENTITY)" \
		"$(PRODUCT_NAME)/Contents/Frameworks/Sparkle.framework" 2>&1 | tail -1
	@echo "→ Signing app bundle (entitlements + hardened runtime)..."
	codesign --force --options runtime --timestamp \
		--entitlements "$(ENTITLEMENTS)" \
		--sign "$(DEV_SIGN_IDENTITY)" \
		"$(PRODUCT_NAME)"
	@echo "→ Done: $(PRODUCT_NAME) (signed: $(DEV_SIGN_IDENTITY))"

run: dev-build
	pkill -f "/$(PRODUCT_NAME)/" 2>/dev/null || true
	open "$(PRODUCT_NAME)"

# Rebuild AppIcon.icns from Resources/AppIcon.iconset. Unlike most Jorvik apps
# this icon is existing artwork rather than something drawn procedurally by a
# generate_icon.swift, so the iconset is the source and lives in the repo. It
# is excluded from the bundle copy above and by release.mk.
icon:
	@echo "→ Building $(ICON_FILE) from Resources/AppIcon.iconset"
	iconutil -c icns Resources/AppIcon.iconset -o Resources/$(ICON_FILE)
