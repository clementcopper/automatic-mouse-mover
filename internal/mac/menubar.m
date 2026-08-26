#import <Cocoa/Cocoa.h>

#include "menubar.h"
#include "_cgo_export.h"

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
		// The artwork is pure black plus an alpha ramp, so AppKit can tint it itself:
		// black on a light menu bar, white on a dark one, inverted while the menu is
		// open, and correct when the bar picks up colour from the wallpaper. A
		// coloured replacement icon would be flattened to a silhouette by this.
		[image setTemplate:YES];
		[image setSize:NSMakeSize(16, 16)];
		gStatusItem.button.image = image;
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
