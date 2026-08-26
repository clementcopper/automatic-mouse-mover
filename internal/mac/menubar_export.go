package mac

//Callbacks from AppKit into Go. They run on the main thread, so none of them may block.

import "C"

//export ammMenubarReady
func ammMenubarReady() {
	if onReadyFunc != nil {
		go onReadyFunc()
	}
}

//export ammMenubarExit
func ammMenubarExit() {
	if onExitFunc != nil {
		onExitFunc()
	}
}

//export ammMenubarClicked
func ammMenubarClicked(itemID C.int) {
	menuMutex.Lock()
	item := menuItems[int(itemID)]
	menuMutex.Unlock()

	if item == nil {
		return
	}

	//non-blocking: the channel is buffered, and stalling here would freeze the menu
	select {
	case item.ClickedCh <- struct{}{}:
	default:
	}
}
