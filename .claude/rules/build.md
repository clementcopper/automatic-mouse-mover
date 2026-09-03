---
paths:
  - "Makefile"
  - "go.mod"
  - "go.sum"
  - "tools/**"
  - "appInfo/**"
  - "assets/**"
  - ".github/**"
---

# Build, dependencies, icons, release

Distilled from `LEARNINGS.md` § Why there are no dependencies any more and § Build. `-s -w`, `-mmacosx-version-min` and the `NSImage` SVG path are already in `CLAUDE.md`.

- **Before adding a library, check whether the platform already exposes the thing.** One `CGEventSourceSecondsSinceLastEventType` call replaced four polling handlers; `systray` cost 4.2 MB for one logging line.
- **Measure dependency weight with an A/B build, not `go tool nm`** (symbol sizes summed to 38 MB for a 7.7 MB binary), and count with `go list -deps ./cmd/...`, not go.mod lines.
- **Ad-hoc sign the bundle, not just the binary** (`codesign --force --sign - ./bin/amm.app` in the Makefile); Apple Silicon refuses unsigned arm64 and macOS validates the `.app`. Still not notarisation: downloads need `xattr -cr` **before** the first launch; macOS 15 dropped right-click → Open, the GUI route is Privacy & Security → Open Anyway. Write install instructions for Finder users, not only the terminal.
- **Without a deployment target, `minos` is the build host's macOS.** Check with `otool -l <binary> | grep -A3 LC_BUILD_VERSION`.
- **Cross-compiling cgo works both ways with plain Command Line Tools** (`CGO_ENABLED=1 GOARCH=arm64 CGO_CFLAGS="-arch arm64 $(MIN_MACOS)" CGO_LDFLAGS="-arch arm64 $(MIN_MACOS)"` — never without the deployment target, see the rule above); `make build` does both plus `lipo` and prints `lipo -archs`.
- **`iconutil` wants exactly ten files named `icon_16x16.png` … `icon_512x512@2x.png`,** anything else fails with "Failed to generate ICNS".
