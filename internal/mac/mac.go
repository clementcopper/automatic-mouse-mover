// Package mac wraps the handful of macOS calls AMM needs, so the app carries no runtime
// dependencies. It replaces robotgo, activity-tracker and mac-sleep-notifier.
package mac

/*
#cgo darwin CFLAGS: -x objective-c
#cgo darwin LDFLAGS: -framework ApplicationServices -framework CoreFoundation -framework CoreGraphics -framework Cocoa
#include <stdlib.h>
#include "mac.h"
*/
import "C"

import "unsafe"

// API is the real macOS implementation. The engine takes it as an interface so tests
// can substitute a fake and run without cgo or a real mouse.
type API struct{}

// AccessibilityTrusted reports whether macOS lets this process post input events.
func (API) AccessibilityTrusted() bool {
	return C.amm_accessibility_trusted() != 0
}

// IdleSeconds reports how long it has been since the last user input event.
func (API) IdleSeconds() float64 {
	return float64(C.amm_idle_seconds())
}

// MousePos returns the current cursor position.
func (API) MousePos() (int, int) {
	var x, y C.int
	C.amm_mouse_pos(&x, &y)
	return int(x), int(y)
}

// MoveMouse posts a mouse-moved event at the given position.
func (API) MoveMouse(x, y int) {
	C.amm_move_mouse(C.int(x), C.int(y))
}

// Alert puts up a dialog and returns at once. The dialog is shown on the main thread and
// outlives the call, so nothing has to be parked while it is open.
func (API) Alert(title, msg string) {
	cTitle := C.CString(title)
	defer C.free(unsafe.Pointer(cTitle))
	cMsg := C.CString(msg)
	defer C.free(unsafe.Pointer(cMsg))

	C.amm_alert(cTitle, cMsg)
}
