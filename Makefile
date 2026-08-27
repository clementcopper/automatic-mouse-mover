COVER_PROFILE=cover.out
COVER_HTML=cover.html

.PHONY: $(COVER_PROFILE) $(COVER_HTML)

all: open

# Universal binary: build each arch on its own, then lipo them together, so one
# .app runs natively on both Apple Silicon and Intel.
#
# No -mmacosx-version-min is set, so the binary targets whatever macOS the build host
# runs. That was forced by robotgo's screen capture backend switch; robotgo is gone, so
# a minimum deployment target could be set here again if older systems need supporting.
build: clean
	mkdir -p -v ./bin/amm.app/Contents/Resources
	mkdir -p -v ./bin/amm.app/Contents/MacOS
	cp ./appInfo/*.plist ./bin/amm.app/Contents/Info.plist
	cp ./appInfo/*.icns ./bin/amm.app/Contents/Resources/icon.icns
	CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
		CGO_CFLAGS="-arch arm64" CGO_LDFLAGS="-arch arm64" \
		go build -o ./bin/amm-arm64 cmd/main.go
	CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 \
		CGO_CFLAGS="-arch x86_64" CGO_LDFLAGS="-arch x86_64" \
		go build -o ./bin/amm-amd64 cmd/main.go
	lipo -create -output ./bin/amm.app/Contents/MacOS/amm ./bin/amm-arm64 ./bin/amm-amd64
	rm ./bin/amm-arm64 ./bin/amm-amd64
# Ad-hoc sign the bundle. Apple Silicon refuses to run unsigned arm64 code, and while
# the Go linker signs the arm64 slice itself, the surrounding .app stays unsigned - the
# bundle is what macOS validates at launch. This is not notarisation: a downloaded copy
# still needs its quarantine attribute cleared.
	codesign --force --sign - ./bin/amm.app
	codesign --verify ./bin/amm.app
	lipo -archs ./bin/amm.app/Contents/MacOS/amm

open: build
	open ./bin

clean:
	rm -rf ./bin

start:
	go run cmd/main.go

test:coverage

coverage: $(COVER_HTML)

$(COVER_HTML): $(COVER_PROFILE)
	go tool cover -html=$(COVER_PROFILE) -o $(COVER_HTML)

$(COVER_PROFILE):
	go test -v -failfast -race -coverprofile=$(COVER_PROFILE) ./...

vet:
	go vet ./...

# Rasterises appInfo/icon.svg into appInfo/icon.icns, and checks that the menu bar
# artwork is pure black plus alpha. Deliberately not a dependency of build: that would
# demand an SVG on every build and re-rasterise each time.
icons:
	go run ./tools/mkicons

.PHONY: all build open clean start test coverage vet icons
