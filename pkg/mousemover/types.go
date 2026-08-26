package mousemover

import (
	"os"
	"sync"
	"time"
)

//MouseMover is the main struct for the app
type MouseMover struct {
	quit     chan struct{}
	logFile  *os.File
	state    *state
	platform platform
}

//platform is everything the engine needs from macOS. internal/mac implements it for
//real; tests substitute a fake, which keeps them free of cgo and of the actual cursor.
type platform interface {
	AccessibilityTrusted() bool
	IdleSeconds() float64
	MousePos() (int, int)
	MoveMouse(x, y int)
	Alert(title, msg string)
}

//state manages the internal working of the app
type state struct {
	mutex              sync.RWMutex
	isAppRunning       bool
	lastMouseMovedTime time.Time
	lastErrorTime      time.Time
	lastAlertTime      time.Time
	didNotMoveCount    int
}
