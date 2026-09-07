MIN_MACOS=13.0
BUILD=.build
APP=./bin/amm.app

all: open

# Universal binary: build each arch on its own and lipo them together, so one .app
# runs natively on both Apple Silicon and Intel. `swift build --arch a --arch b` would
# do it in one go, but that path needs xcbuild from a full Xcode; --triple works with
# the Command Line Tools alone.
#
# The triple carries the deployment target, so a bundle built on a newer Mac still
# runs on Ventura. Check with `otool -l bin/amm.app/Contents/MacOS/amm | grep -A3 LC_BUILD_VERSION`.
build: clean
	mkdir -p -v $(APP)/Contents/Resources
	mkdir -p -v $(APP)/Contents/MacOS
	cp ./appInfo/Info.plist $(APP)/Contents/Info.plist
	cp ./appInfo/icon.icns $(APP)/Contents/Resources/icon.icns
	cp ./assets/icon/tray.* $(APP)/Contents/Resources/
	swift build -c release --product amm --triple arm64-apple-macosx$(MIN_MACOS)
	swift build -c release --product amm --triple x86_64-apple-macosx$(MIN_MACOS)
	lipo -create -output $(APP)/Contents/MacOS/amm \
		$(BUILD)/arm64-apple-macosx/release/amm \
		$(BUILD)/x86_64-apple-macosx/release/amm
# Ad-hoc sign the bundle. Apple Silicon refuses to run unsigned arm64 code, and the
# bundle is what macOS validates at launch. This is not notarisation: a downloaded
# copy still needs its quarantine attribute cleared.
	codesign --force --sign - $(APP)
	codesign --verify $(APP)
	lipo -archs $(APP)/Contents/MacOS/amm

open: build
	open ./bin

clean:
	rm -rf ./bin

# Runs the app straight from the build tree. No bundle, so there is no tray icon
# (the button says AMM) and the login item cannot be registered.
start:
	swift run amm

# The engine's tests, a plain executable that exits non-zero on failure. Debug build,
# which is what lets the tests reach the engine's internals.
test:
	swift run amm-tests

# Rasterises appInfo/icon.svg into appInfo/icon.icns and checks that the menu bar
# artwork is pure black plus alpha. Deliberately not a dependency of build: that would
# demand an SVG on every build and re-rasterise each time.
icons:
	swift run mkicons

.PHONY: all build open clean start test icons
