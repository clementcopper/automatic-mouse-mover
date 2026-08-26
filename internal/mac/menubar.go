package mac

/*
#cgo darwin LDFLAGS: -framework Cocoa
#include <stdlib.h>
#include "menubar.h"
*/
import "C"

import (
	"runtime"
	"sync"
	"unsafe"
)

func init() {
	//AppKit insists on running its event loop on the process' first thread. init runs
	//on the main goroutine while it is still there, so this pins it before anything
	//else can migrate it.
	runtime.LockOSThread()
}

var (
	menuMutex sync.Mutex
	menuItems = map[int]*MenuItem{}

	onReadyFunc func()
	onExitFunc  func()
)

// MenuItem is one entry in the status bar menu.
type MenuItem struct {
	id int
	//ClickedCh receives a value every time the item is clicked. It is buffered so a
	//click is not lost while the reader is busy, and never blocks the AppKit thread.
	ClickedCh chan struct{}
}

// Run sets up the status item and runs the AppKit event loop. It blocks until Quit is
// called, then invokes onExit. onReady runs once the app has finished launching.
func Run(onReady, onExit func()) {
	onReadyFunc = onReady
	onExitFunc = onExit

	C.amm_menubar_run()
}

// SetIcon sets the status bar icon from PNG bytes.
func SetIcon(data []byte) {
	if len(data) == 0 {
		return
	}
	C.amm_menubar_set_icon(unsafe.Pointer(&data[0]), C.int(len(data)))
}

// AddMenuItem appends an entry to the menu.
func AddMenuItem(title, tooltip string) *MenuItem {
	cTitle := C.CString(title)
	defer C.free(unsafe.Pointer(cTitle))
	cTooltip := C.CString(tooltip)
	defer C.free(unsafe.Pointer(cTooltip))

	item := &MenuItem{
		id:        int(C.amm_menubar_add_item(cTitle, cTooltip)),
		ClickedCh: make(chan struct{}, 1),
	}

	menuMutex.Lock()
	menuItems[item.id] = item
	menuMutex.Unlock()

	return item
}

// AddSeparator appends a divider to the menu.
func AddSeparator() {
	C.amm_menubar_add_separator()
}

// Quit stops the event loop.
func Quit() {
	C.amm_menubar_quit()
}

// Enable makes the item clickable again.
func (i *MenuItem) Enable() {
	C.amm_menubar_set_enabled(C.int(i.id), 1)
}

// SetChecked shows or hides the tick mark next to the item.
func (i *MenuItem) SetChecked(checked bool) {
	var flag C.int
	if checked {
		flag = 1
	}
	C.amm_menubar_set_checked(C.int(i.id), flag)
}

// Disable greys the item out.
func (i *MenuItem) Disable() {
	C.amm_menubar_set_enabled(C.int(i.id), 0)
}
