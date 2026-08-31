#import <Cocoa/Cocoa.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>

#include "mac.h"

// Whether this process may post input events. Asking outright beats inferring it from
// failed moves: a stale Accessibility grant looks exactly like a broken mouse otherwise.
int amm_accessibility_trusted(void) {
	return AXIsProcessTrusted() ? 1 : 0;
}

// Seconds since the last keyboard, mouse or tablet input event.
//
// This one call is the entire activity detection. It replaces four polling handlers
// (cursor position, a gohook event tap, a window-title read through the accessibility
// API, and an IOKit sleep notifier) and needs no permission of its own.
double amm_idle_seconds(void) {
	return CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState,
	                                             kCGAnyInputEventType);
}

void amm_mouse_pos(int *x, int *y) {
	CGEventRef event = CGEventCreate(NULL);
	if (event == NULL) {
		*x = 0;
		*y = 0;
		return;
	}

	CGPoint p = CGEventGetLocation(event);
	CFRelease(event);

	*x = (int)p.x;
	*y = (int)p.y;
}

// Posts a real HID event instead of warping the cursor. Warping would move the pointer
// without resetting the system idle timer - and resetting that timer is the whole point
// of the app. Without Accessibility permission macOS silently drops the event, which is
// how the caller detects a failed move.
void amm_move_mouse(int x, int y) {
	CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
	                                          CGPointMake(x, y), kCGMouseButtonLeft);
	if (move == NULL) {
		return;
	}

	CGEventPost(kCGHIDEventTap, move);
	CFRelease(move);
}

// Only one dialog at a time. Ten failed moves in a row must not stack ten alerts.
static BOOL gAlertOnScreen = NO;

// Returns immediately. The dialog is put up on the main thread and lives on without the
// caller, so no goroutine is parked for as long as it stays open.
//
// This replaced CFUserNotificationDisplayAlert, which was called from a goroutine with a
// timeout of 0.0 - never expires. It blocked that thread until someone clicked OK, and
// since AMM is an accessory app that never comes forward on its own, the dialog could
// sit behind everything and never be seen.
void amm_alert(const char *title, const char *msg) {
	NSString *alertTitle = [NSString stringWithUTF8String:title];
	NSString *alertMsg = [NSString stringWithUTF8String:msg];

	// dispatch_async, not dispatch_sync: a synchronous hop onto the main thread from a
	// goroutine is the deadlock that freezes the menu bar.
	dispatch_async(dispatch_get_main_queue(), ^{
		if (gAlertOnScreen) {
			return;
		}
		gAlertOnScreen = YES;

		NSAlert *alert = [[NSAlert alloc] init];
		[alert setMessageText:alertTitle];
		[alert setInformativeText:alertMsg];
		[alert addButtonWithTitle:@"OK"];

		// No dock icon means no automatic activation - without this the window opens
		// behind whatever the user is looking at.
		[NSApp activateIgnoringOtherApps:YES];
		[alert runModal];

		gAlertOnScreen = NO;
	});
}
