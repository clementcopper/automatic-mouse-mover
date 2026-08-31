#import <Cocoa/Cocoa.h>

#include "menubar.h"
#include "_cgo_export.h"

// Motif height in points. The menu bar is 22pt, so this leaves a little air.
#define AMM_ICON_HEIGHT 16.0

static NSStatusItem *gStatusItem = nil;
static NSMenu *gMenu = nil;
static int gNextItemID = 1;

// Every AppKit call has to happen on the main thread. Menu items are built from a Go
// goroutine, so everything below funnels through here. dispatch_sync would deadlock if
// we were already on the main thread, hence the check.
static void runOnMain(dispatch_block_t block) {
	if ([NSThread isMainThread]) {
		block();
	} else {
		dispatch_sync(dispatch_get_main_queue(), block);
	}
}

// Rasterise once, at the sizes the menu bar actually draws. The artwork may be an SVG,
// and a vector NSImage handed straight to the status button leaves AppKit re-rendering
// 2400 path segments every single time the menu bar redraws - which it does whenever
// what sits behind it changes. Bitmaps are drawn from a cache.
//
// Returns nil if the bitmaps cannot be built, so the caller can fall back to the image
// it already has.
static NSImage *rasterise(NSImage *image, NSSize size) {
	NSImage *flat = [[NSImage alloc] initWithSize:size];

	// 1x and 2x. Every Mac that can run this is Retina or drives one, but a 1x rep
	// keeps a non-Retina external display sharp too.
	for (int scale = 1; scale <= 2; scale++) {
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
			initWithBitmapDataPlanes:NULL
			              pixelsWide:(NSInteger)(size.width * scale)
			              pixelsHigh:(NSInteger)(size.height * scale)
			           bitsPerSample:8
			         samplesPerPixel:4
			                hasAlpha:YES
			                isPlanar:NO
			          colorSpaceName:NSCalibratedRGBColorSpace
			             bytesPerRow:0
			            bitsPerPixel:0];
		if (rep == nil) {
			continue;
		}
		// The rep's size is in points, its pixel count is not: that is what makes this
		// the 2x representation rather than a bigger picture.
		[rep setSize:size];

		[NSGraphicsContext saveGraphicsState];
		[NSGraphicsContext setCurrentContext:
			[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
		[image drawInRect:NSMakeRect(0, 0, size.width, size.height)
		         fromRect:NSZeroRect
		        operation:NSCompositingOperationSourceOver
		         fraction:1.0];
		[NSGraphicsContext restoreGraphicsState];

		[flat addRepresentation:rep];
	}

	if ([[flat representations] count] == 0) {
		return nil;
	}
	return flat;
}

@interface AMMDelegate : NSObject <NSApplicationDelegate>
- (void)onClick:(id)sender;
@end

@implementation AMMDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
	ammMenubarReady();
}

- (void)onClick:(id)sender {
	ammMenubarClicked((int)[sender tag]);
}

@end

static AMMDelegate *gDelegate = nil;

void amm_menubar_run(void) {
	@autoreleasepool {
		[NSApplication sharedApplication];
		// menu bar only, no dock icon - matches LSUIElement in Info.plist
		[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

		gDelegate = [[AMMDelegate alloc] init];
		[NSApp setDelegate:gDelegate];

		gStatusItem = [[NSStatusBar systemStatusBar]
			statusItemWithLength:NSVariableStatusItemLength];

		gMenu = [[NSMenu alloc] initWithTitle:@""];
		// Without this AppKit decides on its own whether an item is enabled, by asking
		// the target, and silently overrides every setEnabled: we make.
		[gMenu setAutoenablesItems:NO];
		[gStatusItem setMenu:gMenu];

		[NSApp run];
	}

	ammMenubarExit();
}

void amm_menubar_set_icon(const void *data, int len) {
	NSData *buffer = [NSData dataWithBytes:data length:len];

	runOnMain(^{
		NSImage *image = [[NSImage alloc] initWithData:buffer];
		if (image == nil) {
			return;
		}

		// Scale to a fixed height and let the width follow, so a wide mark is not
		// squashed into a square. The status item was created with
		// NSVariableStatusItemLength, so it widens to match; only the height is fixed,
		// by the menu bar itself.
		NSSize native = [image size];
		CGFloat height = AMM_ICON_HEIGHT;
		CGFloat width = (native.height > 0) ? native.width * height / native.height : height;
		NSSize size = NSMakeSize(width, height);
		[image setSize:size];

		// Flatten before handing it over, and set the template flag on the result: the
		// flag governs how a control tints the image, drawInRect: copies the artwork as
		// it is either way.
		NSImage *icon = rasterise(image, size);
		if (icon == nil) {
			icon = image;
		}
		// The artwork is pure black plus an alpha ramp, so AppKit can tint it itself:
		// black on a light menu bar, white on a dark one, inverted while the menu is
		// open, and correct when the bar picks up colour from the wallpaper. A
		// coloured replacement icon would be flattened to a silhouette by this.
		[icon setTemplate:YES];

		gStatusItem.button.image = icon;
		gStatusItem.button.imagePosition = NSImageOnly;
	});
}

int amm_menubar_add_item(const char *title, const char *tooltip) {
	NSString *itemTitle = [NSString stringWithUTF8String:title];
	NSString *itemTooltip = [NSString stringWithUTF8String:tooltip];
	int itemID = gNextItemID++;

	runOnMain(^{
		NSMenuItem *item = [gMenu addItemWithTitle:itemTitle
		                                    action:@selector(onClick:)
		                             keyEquivalent:@""];
		[item setTarget:gDelegate];
		[item setToolTip:itemTooltip];
		[item setTag:itemID];
		[item setEnabled:YES];
	});

	return itemID;
}

void amm_menubar_add_separator(void) {
	runOnMain(^{
		[gMenu addItem:[NSMenuItem separatorItem]];
	});
}

void amm_menubar_set_enabled(int itemID, int enabled) {
	runOnMain(^{
		NSMenuItem *item = [gMenu itemWithTag:itemID];
		if (item != nil) {
			[item setEnabled:(enabled != 0)];
		}
	});
}

void amm_menubar_set_checked(int itemID, int checked) {
	runOnMain(^{
		NSMenuItem *item = [gMenu itemWithTag:itemID];
		if (item != nil) {
			[item setState:(checked != 0) ? NSControlStateValueOn : NSControlStateValueOff];
		}
	});
}

void amm_menubar_quit(void) {
	runOnMain(^{
		[NSApp stop:nil];
		// stop: only takes effect after the next event is handled, so hand it one.
		NSEvent *wakeUp = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
		                                     location:NSMakePoint(0, 0)
		                                modifierFlags:0
		                                    timestamp:0
		                                 windowNumber:0
		                                      context:nil
		                                      subtype:0
		                                        data1:0
		                                        data2:0];
		[NSApp postEvent:wakeUp atStart:YES];
	});
}
