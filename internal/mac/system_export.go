package mac

import "C"

var onWakeFunc func()

//export ammDidWake
func ammDidWake() {
	if onWakeFunc != nil {
		//runs on the main thread, so hand off rather than doing work here
		go onWakeFunc()
	}
}
