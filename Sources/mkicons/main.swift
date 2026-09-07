// Turns a single SVG into the app's .icns, so the only artwork to maintain is one
// vector file per icon. Nothing else on a stock Mac rasterises SVG for this purpose:
// iconutil only reads PNG, sips cannot open an SVG at all. NSImage can.
//
//   appInfo/icon.svg      -> appInfo/icon.icns   (colour, the Finder icon)
//   assets/icon/tray.*    -> checked, not built  (the menu bar icon is copied as is)
//
// Run it with `make icons`.
import AppKit

let finderSource = "appInfo/icon.svg"
let finderTarget = "appInfo/icon.icns"
let trayDir = "assets/icon"

// iconutil accepts exactly these names; anything else and it refuses the folder.
let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

/// Draws the image at pixels x pixels. Colour and alpha are kept as they are.
func rasterise(_ image: NSImage, pixels: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// A missing source is reported but left alone: overwriting a working icon.icns just
/// because no SVG has been drawn yet would be worse than doing nothing.
func buildICNS() throws {
    guard FileManager.default.fileExists(atPath: finderSource) else {
        print("skipped: no \(finderSource) yet, \(finderTarget) left untouched")
        return
    }
    guard let image = NSImage(contentsOfFile: finderSource) else {
        throw NSError(domain: "mkicons", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(finderSource) could not be read as an image"])
    }
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("amm-\(getpid()).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }

    for size in iconSizes {
        guard let rep = rasterise(image, pixels: size.pixels),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "mkicons", code: 2, userInfo: [NSLocalizedDescriptionKey: "rasterising \(size.name) failed"])
        }
        try png.write(to: iconset.appendingPathComponent("\(size.name).png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", finderTarget]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw NSError(domain: "mkicons", code: 3, userInfo: [NSLocalizedDescriptionKey: "iconutil exited with \(iconutil.terminationStatus)"])
    }
    print("wrote \(finderTarget) from \(finderSource) (\(iconSizes.count) sizes)")
}

/// Warns when the menu bar artwork carries colour. It is drawn as a template image, so
/// AppKit tints it from the alpha channel and throws the colour away: a coloured icon
/// silently collapses into a silhouette.
func checkTray() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: trayDir)
        .filter { $0.hasPrefix("tray.") }.sorted()
    guard let name = names.first else {
        print("skipped: no \(trayDir)/tray.* found")
        return
    }
    if names.count > 1 {
        print("warning: \(names.count) tray files, the app loads tray.svg before tray.png: \(names)")
    }
    let path = "\(trayDir)/\(name)"
    guard let image = NSImage(contentsOfFile: path), let rep = rasterise(image, pixels: 32) else {
        throw NSError(domain: "mkicons", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(path) could not be read as an image"])
    }
    var offenders = 0
    for y in 0..<32 {
        for x in 0..<32 {
            guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
            if c.redComponent > 0.15 || c.greenComponent > 0.15 || c.blueComponent > 0.15 {
                offenders += 1
            }
        }
    }
    if offenders > 0 {
        print("warning: \(path) has \(offenders) coloured pixels at 32px. It is drawn as a template")
        print("         image, so the colour is discarded and only the silhouette remains.")
        print("         Use pure black plus an alpha channel.")
    } else {
        print("ok: \(path) is pure black plus alpha")
    }
}

var failed = false
do { try buildICNS() } catch { fputs("\(finderTarget): \(error.localizedDescription)\n", stderr); failed = true }
do { try checkTray() } catch { fputs("\(trayDir): \(error.localizedDescription)\n", stderr); failed = true }
exit(failed ? 1 : 0)
