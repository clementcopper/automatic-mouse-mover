package mac

/*
#cgo darwin LDFLAGS: -framework ServiceManagement
#include <stdlib.h>
#include "system.h"
*/
import "C"

import (
	"errors"
	"unsafe"
)

// LoginItemStatus mirrors SMAppServiceStatus.
type LoginItemStatus int

const (
	LoginItemNotRegistered LoginItemStatus = iota
	LoginItemEnabled
	LoginItemRequiresApproval
	LoginItemNotFound
	LoginItemUnsupported LoginItemStatus = -1
)

// GetLoginItemStatus reports whether the app is registered to launch at login.
func (API) GetLoginItemStatus() LoginItemStatus {
	return LoginItemStatus(C.amm_login_item_status())
}

// SetLoginItem registers or unregisters the app as a login item.
//
// Note that macOS ties the registration to the executable: after the app is rebuilt or
// replaced it has to be registered again, or it will not launch.
func (API) SetLoginItem(enabled bool) error {
	buf := (*C.char)(C.calloc(512, 1))
	defer C.free(unsafe.Pointer(buf))

	var flag C.int
	if enabled {
		flag = 1
	}
	if C.amm_login_item_set(flag, buf, 512) != 0 {
		return errors.New(C.GoString(buf))
	}
	return nil
}

// PrefBool reads a stored preference, returning fallback when it was never set.
func (API) PrefBool(key string, fallback bool) bool {
	cKey := C.CString(key)
	defer C.free(unsafe.Pointer(cKey))

	var def C.int
	if fallback {
		def = 1
	}
	return C.amm_pref_bool(cKey, def) != 0
}

// SetPrefBool stores a preference.
func (API) SetPrefBool(key string, value bool) {
	cKey := C.CString(key)
	defer C.free(unsafe.Pointer(cKey))

	var v C.int
	if value {
		v = 1
	}
	C.amm_pref_set_bool(cKey, v)
}

// WatchWake calls onWake every time the machine wakes from sleep.
func WatchWake(onWake func()) {
	onWakeFunc = onWake
	C.amm_watch_wake()
}
