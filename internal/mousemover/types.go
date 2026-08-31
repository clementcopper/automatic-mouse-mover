package mousemover

import (
	"log/slog"
	"os"
	"sync"
	"time"
)

// MouseMover is the main struct for the app
type MouseMover struct {
	//mutex serialises Start, Quit and CheckNow. The menu loop is not the only caller -
	//the wake callback runs on its own goroutine and drives the same three methods.
	mutex sync.Mutex
	quit  chan struct{}
	//done is closed by the loop goroutine when it has stopped, so Quit can wait for it
	//instead of assuming.
	done chan struct{}
	//kick asks the loop to check right now instead of waiting for the next tick
	kick    chan struct{}
	logFile *os.File
	//logger overrides the default for one instance. Tests set it to keep invented
	//failures out of the system log; nil means the unified-logging default.
	logger   *slog.Logger
	state    *state
	platform platform
}

// platform is everything the engine needs from macOS. internal/mac implements it for
// real; tests substitute a fake, which keeps them free of cgo and of the actual cursor.
type platform interface {
	AccessibilityTrusted() bool
	IdleSeconds() float64
	MousePos() (int, int)
	MoveMouse(x, y int)
	//Alert returns at once; the dialog is put up on the main thread and lives on
	//without the caller.
	Alert(title, msg string)
}

// state manages the internal working of the app
type state struct {
	mutex              sync.RWMutex
	isAppRunning       bool
	lastMouseMovedTime time.Time
	lastErrorTime      time.Time
	lastAlertTime      time.Time
	didNotMoveCount    int
}
