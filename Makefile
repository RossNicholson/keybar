.PHONY: generate build run test clean release dmg screenshots icon

generate:
	@xcodegen generate >/dev/null

# Build and open a development copy. It's signed with the Developer ID (like
# releases) so the app accepts its helper's signature and the Keychain doesn't
# ask again after every build.
run: generate
	@xcodebuild -project KeyBar.xcodeproj -scheme KeyBar -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath build/dd \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
		DEVELOPMENT_TEAM=5HQ5V9NP82 OTHER_CODE_SIGN_FLAGS="--timestamp=none" -quiet build
	@pkill -x KeyBar || true
	@sleep 1
	@open build/dd/Build/Products/Debug/KeyBar.app

build: generate
	@xcodebuild -project KeyBar.xcodeproj -scheme KeyBar -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -quiet build

# Run the unit tests. They use keys in memory, never the Keychain.
test: generate
	@xcodebuild test -project KeyBar.xcodeproj -scheme KeyBar -destination 'platform=macOS' \
		-derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -quiet

clean:
	rm -rf build KeyBar.xcodeproj

# Ship a release: bump version, commit, tag, push -> CI builds/notarizes/publishes.
#   make release VERSION=1.2.3
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z"; exit 1; }
	@scripts/cut-release.sh $(VERSION)

# Build a local notarized test DMG (does not publish).
dmg:
	@scripts/release.sh

# Renders the panel and the window's screens with demo keys into
# build/screenshots, for the README and website and for checking the design.
screenshots: generate
	@SCREENSHOTS="$(CURDIR)/build/screenshots" TEST_RUNNER_SCREENSHOTS="$(CURDIR)/build/screenshots" \
		xcodebuild test -project KeyBar.xcodeproj -scheme KeyBar -destination 'platform=macOS' \
		-derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:KeyBarTests/ScreenshotTests -quiet
	@echo "Screenshots in build/screenshots"

# Redraws the app icon from the mascot into the asset catalog.
icon: generate
	@TEST_RUNNER_ICON_DIR="$(CURDIR)/KeyBar/Assets.xcassets/AppIcon.appiconset" \
		xcodebuild test -project KeyBar.xcodeproj -scheme KeyBar -destination 'platform=macOS' \
		-derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO -only-testing:KeyBarTests/ScreenshotTests/testAppIcon -quiet
	@echo "Icon written to KeyBar/Assets.xcassets/AppIcon.appiconset"
