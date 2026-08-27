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

// Blocks until the user dismisses the dialog, so callers keep it off any loop they
// still need to service.
void amm_alert(const char *title, const char *msg) {
	CFStringRef cfTitle = CFStringCreateWithCString(NULL, title, kCFStringEncodingUTF8);
	CFStringRef cfMsg = CFStringCreateWithCString(NULL, msg, kCFStringEncodingUTF8);
	CFOptionFlags response;

	CFUserNotificationDisplayAlert(0.0, kCFUserNotificationNoteAlertLevel,
	                               NULL, NULL, NULL, cfTitle, cfMsg,
	                               CFSTR("OK"), NULL, NULL, &response);

	if (cfTitle != NULL) CFRelease(cfTitle);
	if (cfMsg != NULL) CFRelease(cfMsg);
}
