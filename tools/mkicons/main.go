// Command mkicons turns a single SVG into the app's .icns, so the only artwork that has
// to be maintained is one vector file per icon.
//
// It exists because nothing on a stock Mac rasterises SVG for this purpose: iconutil
// only reads PNG, sips cannot open an SVG at all, and rsvg-convert and friends are not
// installed. NSImage does read SVG, so AppKit does the rasterising here.
//
//	appInfo/icon.svg      -> appInfo/icon.icns   (colour, the Finder icon)
//	assets/icon/tray.*    -> checked, not built  (the menu bar icon is embedded as is)
//
// Run it with `make icons`.
package main

/*
#cgo darwin CFLAGS: -x objective-c
#cgo darwin LDFLAGS: -framework Cocoa
#import <Cocoa/Cocoa.h>
#include <stdlib.h>

// Draws image data at pixels x pixels and writes a PNG. Colour and alpha are kept as
// they are - no template tinting here, the Finder icon may be in colour.
static int amm_rasterize(const void *data, int len, int pixels, const char *outPath) {
	@autoreleasepool {
		NSImage *image = [[NSImage alloc] initWithData:[NSData dataWithBytes:data length:len]];
		if (image == nil) { return 1; }

		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
			initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels
			bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
			colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
		if (rep == nil) { return 2; }

		[NSGraphicsContext saveGraphicsState];
		[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
		[image drawInRect:NSMakeRect(0, 0, pixels, pixels) fromRect:NSZeroRect
		        operation:NSCompositingOperationSourceOver fraction:1.0];
		[NSGraphicsContext restoreGraphicsState];

		NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
		if (png == nil) { return 3; }
		return [png writeToFile:[NSString stringWithUTF8String:outPath] atomically:YES] ? 0 : 4;
	}
}

// Counts opaque pixels that are not black. A template image is tinted from its alpha
// channel alone, so any colour in there is silently discarded at draw time.
static int amm_count_non_black(const void *data, int len, int pixels) {
	@autoreleasepool {
		NSImage *image = [[NSImage alloc] initWithData:[NSData dataWithBytes:data length:len]];
		if (image == nil) { return -1; }

		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
			initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels
			bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
			colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
		if (rep == nil) { return -1; }

		[NSGraphicsContext saveGraphicsState];
		[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
		[image drawInRect:NSMakeRect(0, 0, pixels, pixels) fromRect:NSZeroRect
		        operation:NSCompositingOperationSourceOver fraction:1.0];
		[NSGraphicsContext restoreGraphicsState];

		int offenders = 0;
		for (int y = 0; y < pixels; y++) {
			for (int x = 0; x < pixels; x++) {
				NSColor *c = [rep colorAtX:x y:y];
				if ([c alphaComponent] <= 0.5) { continue; }
				if ([c redComponent] > 0.15 || [c greenComponent] > 0.15 || [c blueComponent] > 0.15) {
					offenders++;
				}
			}
		}
		return offenders;
	}
}
*/
import "C"

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"unsafe"
)

const (
	finderSource = "appInfo/icon.svg"
	finderTarget = "appInfo/icon.icns"
	trayGlob     = "assets/icon/tray.*"
)

// iconutil accepts exactly these names; anything else and it refuses the folder.
var iconSizes = []struct {
	name   string
	pixels int
}{
	{"icon_16x16", 16}, {"icon_16x16@2x", 32},
	{"icon_32x32", 32}, {"icon_32x32@2x", 64},
	{"icon_128x128", 128}, {"icon_128x128@2x", 256},
	{"icon_256x256", 256}, {"icon_256x256@2x", 512},
	{"icon_512x512", 512}, {"icon_512x512@2x", 1024},
}

func main() {
	failed := false

	if err := buildICNS(); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", finderTarget, err)
		failed = true
	}
	if err := checkTray(); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", trayGlob, err)
		failed = true
	}

	if failed {
		os.Exit(1)
	}
}

// buildICNS rasterises the source SVG into every size iconutil wants and packs them.
// A missing source is reported but left alone: overwriting a working icon.icns just
// because no SVG has been drawn yet would be worse than doing nothing.
func buildICNS() error {
	data, err := os.ReadFile(finderSource)
	if os.IsNotExist(err) {
		fmt.Printf("skipped: no %s yet, %s left untouched\n", finderSource, finderTarget)
		return nil
	}
	if err != nil {
		return err
	}

	iconset, err := os.MkdirTemp("", "amm-*.iconset")
	if err != nil {
		return err
	}
	defer os.RemoveAll(iconset)

	for _, size := range iconSizes {
		out := filepath.Join(iconset, size.name+".png")
		if rc := rasterize(data, size.pixels, out); rc != 0 {
			return fmt.Errorf("rasterising %s at %dpx failed (code %d)", size.name, size.pixels, rc)
		}
	}

	cmd := exec.Command("iconutil", "-c", "icns", iconset, "-o", finderTarget)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("iconutil: %v: %s", err, out)
	}

	fmt.Printf("wrote %s from %s (%d sizes)\n", finderTarget, finderSource, len(iconSizes))
	return nil
}

// checkTray warns when the menu bar artwork carries colour. It is drawn as a template
// image, so AppKit tints it from the alpha channel and throws the colour away - a
// coloured icon silently collapses into a silhouette.
func checkTray() error {
	names, err := filepath.Glob(trayGlob)
	if err != nil {
		return err
	}
	if len(names) == 0 {
		fmt.Printf("skipped: no %s found\n", trayGlob)
		return nil
	}
	if len(names) > 1 {
		fmt.Printf("warning: %d tray files, only the first is embedded: %v\n", len(names), names)
	}

	data, err := os.ReadFile(names[0])
	if err != nil {
		return err
	}

	offenders := int(C.amm_count_non_black(unsafe.Pointer(&data[0]), C.int(len(data)), 32))
	switch {
	case offenders < 0:
		return fmt.Errorf("%s could not be read as an image", names[0])
	case offenders > 0:
		fmt.Printf("warning: %s has %d coloured pixels at 32px. It is drawn as a template\n"+
			"         image, so the colour is discarded and only the silhouette remains.\n"+
			"         Use pure black plus an alpha channel.\n", names[0], offenders)
	default:
		fmt.Printf("ok: %s is pure black plus alpha\n", names[0])
	}
	return nil
}

func rasterize(data []byte, pixels int, outPath string) int {
	cPath := C.CString(outPath)
	defer C.free(unsafe.Pointer(cPath))

	return int(C.amm_rasterize(unsafe.Pointer(&data[0]), C.int(len(data)), C.int(pixels), cPath))
}
