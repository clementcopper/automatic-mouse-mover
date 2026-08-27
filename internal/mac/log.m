#import <Foundation/Foundation.h>
#import <os/log.h>

#include "log.h"

// A menu bar app launched from Finder has no stderr, so anything written there is lost.
// Unified logging is where a user - or the developer looking at Console.app - can
// actually find it: log show --predicate 'process == "amm"'.
static os_log_t amm_logger(void) {
	static os_log_t logger;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		logger = os_log_create("com.pg.amm", "amm");
	});
	return logger;
}

void amm_log(int level, const char *msg) {
	// Info maps to DEFAULT, not INFO: macOS does not retain OS_LOG_TYPE_INFO unless
	// logging is explicitly turned up for the subsystem, so info-level records would be
	// invisible in Console.app and in `log show` - which is the whole reason for this
	// handler. DEFAULT is persisted and shown without any extra flag.
	os_log_type_t type;
	switch (level) {
		case 0:  type = OS_LOG_TYPE_DEBUG;   break;
		case 2:  type = OS_LOG_TYPE_ERROR;   break;
		default: type = OS_LOG_TYPE_DEFAULT; break;
	}
	// %{public}s: without the annotation os_log redacts the string as <private>.
	os_log_with_type(amm_logger(), type, "%{public}s", msg);
}
