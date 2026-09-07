// swift-tools-version:5.9
// 5.9 is what the Command Line Tools on Ventura ship; the M2 builds it with 6.x in
// language mode 5. Nothing here needs a newer toolchain.
import PackageDescription

let package = Package(
    name: "amm",
    platforms: [.macOS(.v13)],
    targets: [
        // The engine: no AppKit, everything native behind the Platform protocol.
        .target(name: "AMMCore", path: "Sources/AMMCore"),
        // The menu bar app.
        .executableTarget(name: "amm", dependencies: ["AMMCore"], path: "Sources/amm"),
        // Tests as a plain executable: the Command Line Tools carry no XCTest, and the
        // engine is synchronous, so `check` plus an exit code is all a test needs.
        .executableTarget(name: "amm-tests", dependencies: ["AMMCore"], path: "Sources/amm-tests"),
        // appInfo/icon.svg -> icon.icns, plus the tray artwork check. `make icons`.
        .executableTarget(name: "mkicons", path: "Sources/mkicons"),
    ]
)
