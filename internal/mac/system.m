#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>

#include "system.h"
#include "_cgo_export.h"

// SMAppService registers the app itself as a login item, so nothing about the state
// needs storing on our side - the system owns it. Requires a code signature; ad-hoc is
// enough, only LaunchDaemons need notarisation.
int amm_login_item_status(void) {
	if (@available(macOS 13.0, *)) {
		return (int)[SMAppService mainAppService].status;
	}
	return -1;
}

int amm_login_item_set(int enabled, char *errBuf, int errBufLen) {
	if (@available(macOS 13.0, *)) {
		NSError *error = nil;
		BOOL ok = enabled
			? [[SMAppService mainAppService] registerAndReturnError:&error]
			: [[SMAppService mainAppService] unregisterAndReturnError:&error];

		if (ok) {
			return 0;
		}
		// Say why. Silently swallowing this is how a dead toggle looks like a bug in
		// the app rather than a refusal by the system.
		const char *reason = error ? [[error localizedDescription] UTF8String] : "unknown error";
		strncpy(errBuf, reason, errBufLen - 1);
		errBuf[errBufLen - 1] = '\0';
		return -1;
	}
	strncpy(errBuf, "requires macOS 13 or newer", errBufLen - 1);
	errBuf[errBufLen - 1] = '\0';
	return -1;
}

int amm_pref_bool(const char *key, int fallback) {
	NSString *k = [NSString stringWithUTF8String:key];
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	if ([defaults objectForKey:k] == nil) {
		return fallback;
	}
	return [defaults boolForKey:k] ? 1 : 0;
}

void amm_pref_set_bool(const char *key, int value) {
	[[NSUserDefaults standardUserDefaults] setBool:(value != 0)
	                                        forKey:[NSString stringWithUTF8String:key]];
}

// The callback lands on the main thread, so it must not block - ammDidWake only drops a
// value into a buffered channel.
void amm_watch_wake(void) {
	[[[NSWorkspace sharedWorkspace] notificationCenter]
		addObserverForName:NSWorkspaceDidWakeNotification
		            object:nil
		             queue:nil
		        usingBlock:^(NSNotification *note) { ammDidWake(); }];
}
