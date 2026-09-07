---
paths:
  - "Makefile"
  - "Package.swift"
  - "Sources/mkicons/**"
  - "appInfo/**"
  - "assets/**"
  - ".github/**"
---

# Build, dependencies, icons, release

Distilled from `LEARNINGS.md` § Build and § Swift port. The `--triple` build and the ad-hoc signature are described in `CLAUDE.md`.

- **Before adding a library, check whether the platform already exposes the thing.** One `secondsSinceLastEventType` call replaced four polling handlers; `systray` cost 4.2 MB for one logging line. The Swift binary is 197 KB per architecture with nothing added.
- **Measure dependency weight with an A/B build, not a symbol dump** (symbol sizes summed to 38 MB for a 7.7 MB binary).
- **`swift build --arch a --arch b` needs xcbuild, which only Xcode has.** With the Command Line Tools build once per `--triple` and `lipo` the results; the products land in `.build/<triple-without-version>/release/`.
- **The Command Line Tools ship no XCTest and no swift-testing** (`xcrun --find xctest` fails on CLT 15.2). The tests are a plain executable; `swift build` prints an XCTest warning every time, ignore it.
- **The triple carries the deployment target.** Without `-apple-macosx13.0` `minos` is the build host's macOS. Check with `otool -l <binary> | grep -A3 LC_BUILD_VERSION`.
- **Ad-hoc sign the bundle, not just the binary** (`codesign --force --sign - ./bin/amm.app`); Apple Silicon refuses unsigned arm64 and macOS validates the `.app`. Still not notarisation: downloads need `xattr -cr` **before** the first launch; macOS 15 dropped right-click → Open, the GUI route is Privacy & Security → Open Anyway. Write install instructions for Finder users, not only the terminal.
- **`iconutil` wants exactly ten files named `icon_16x16.png` … `icon_512x512@2x.png`,** anything else fails with "Failed to generate ICNS".
- **The version lives in `Info.plist` only;** the app reads it from the bundle and `release.yml` checks it against the tag.
