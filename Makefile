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

.PHONY: all build open clean start test coverage vet