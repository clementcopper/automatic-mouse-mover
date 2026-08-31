package mousemover

import (
	"fmt"
	"log/slog"
	"time"

	"github.com/clementcopper/automatic-mouse-mover/internal/mac"
)

var instance *MouseMover

const (
	//how often the idle time is looked at
	checkInterval = 30 * time.Second
	//how long the machine has to be idle before the cursor is nudged
	idleThreshold = 60 * time.Second
	//how many failed moves before the accessibility alert is shown
	failuresBeforeAlert = 10
	//how often the cursor position is re-read while waiting for a move to land
	moveSettleInterval = 10 * time.Millisecond

	logDir      = "log"
	logFileName = "logFile-amm-5"
)

// how long to wait for a posted mouse event to take effect before calling it a failure.
// A var, not a const, so tests do not have to sit out the real budget.
var moveSettleTimeout = 200 * time.Millisecond

// Start the main app
func (m *MouseMover) Start() {
	m.mutex.Lock()
	defer m.mutex.Unlock()

	if m.state.isRunning() {
		return
	}
	m.state = &state{}
	m.quit = make(chan struct{})
	m.kick = make(chan struct{}, 1)
	//Mark it running here, not inside the goroutine. The goroutine may not be scheduled
	//before the next caller asks - and the wake callback is exactly such a caller - so
	//flagging it late let two loops start, each with its own ticker.
	m.state.updateRunningStatus(true)

	ticker := time.NewTicker(checkInterval)
	m.run(ticker.C, ticker.Stop)
}

// run drives the loop. The tick channel and stop function are parameters so tests can
// drive it themselves instead of waiting on a real ticker.
func (m *MouseMover) run(tick <-chan time.Time, stop func()) {
	//A fresh one per run: the previous one is closed, and closing it twice panics.
	m.done = make(chan struct{})
	//Read the channels once. The loop must not keep reading the struct fields: Start
	//replaces them, and a select re-evaluating them would race with that.
	done, quit, kick := m.done, m.quit, m.kick

	go func() {
		defer close(done)

		state := m.state
		state.updateRunningStatus(true)

		//Set by tests before run() starts, so the goroutine never races the assignment.
		logger := m.logger
		if logger == nil {
			logger = getLogger(m, false, logFileName) //set writeToFile=true only for debugging
		}
		movePixel := 10

		for {
			select {
			case <-tick:
				m.checkAndMove(logger, state, &movePixel)

			case <-kick:
				m.checkAndMove(logger, state, &movePixel)

			case <-quit:
				logger.Info("stopping mouse mover")
				state.updateRunningStatus(false)
				stop()
				return
			}
		}
	}()
}

// checkAndMove is one iteration: nudge the cursor unless the user is active.
func (m *MouseMover) checkAndMove(logger *slog.Logger, state *state, movePixel *int) {
	idle := m.platform.IdleSeconds()
	if idle < idleThreshold.Seconds() {
		logger.Debug("activity detected, leaving the cursor alone", "idleSeconds", idle)
		return
	}

	if !moveAndCheck(m.platform, *movePixel) {
		m.reportFailedMove(logger, state)
		return
	}

	state.updateLastMouseMovedTime(time.Now())
	state.updateDidNotMoveCount(0)
	//flip the direction so the cursor oscillates instead of drifting off screen
	*movePixel *= -1
	logger.Info("moved mouse", "at", state.getLastMouseMovedTime())
}

// reportFailedMove counts a failed move and, at most once every 24 hours, tells the user
// that AMM is most likely missing Accessibility permission.
func (m *MouseMover) reportFailedMove(logger *slog.Logger, state *state) {
	state.updateDidNotMoveCount(state.getDidNotMoveCount() + 1)
	state.updateLastErrorTime(time.Now())

	//Ask macOS outright rather than inferring it. A grant that has gone stale - which is
	//what happens to an ad-hoc signed app after any rebuild, since the permission is
	//pinned to the binary's cdhash - still shows a ticked box in System Settings, so
	//guessing from failed moves points the user at the wrong thing.
	trusted := m.platform.AccessibilityTrusted()

	var msg string
	if trusted {
		msg = fmt.Sprintf("Mouse pointer cannot be moved at %v. Last moved at %v. Happened %v times. (Only notifies once every 24 hours.) See README for details.",
			time.Now(), state.getLastMouseMovedTime(), state.getDidNotMoveCount())
	} else {
		msg = "AMM is not allowed to control the mouse.\n\nOpen System Settings > Privacy & Security > Accessibility. If amm is already listed, remove it with the minus button and add it again - a ticked box can still be stale after the app was rebuilt or replaced, because the permission is tied to the exact binary."
	}
	logger.Error(msg, "accessibilityTrusted", trusted)

	//Without permission the diagnosis is certain, so say so at once instead of making
	//the user wait out ten failures. lastAlertTime is tracked separately from
	//lastErrorTime, which was just set to now - comparing against that one made this
	//condition permanently false.
	threshold := failuresBeforeAlert
	if !trusted {
		threshold = 1
	}

	lastAlertTime := state.getLastAlertTime()
	if state.getDidNotMoveCount() >= threshold &&
		(lastAlertTime.IsZero() || time.Since(lastAlertTime).Hours() > 24) {
		state.updateLastAlertTime(time.Now())
		title := "Error with Automatic Mouse Mover"
		if !trusted {
			title = "Automatic Mouse Mover needs permission"
		}
		m.platform.Alert(title, msg)
	}
}

// IsRunning reports whether the mover loop is active.
func (m *MouseMover) IsRunning() bool {
	return m != nil && m.state.isRunning()
}

// CheckNow asks the loop to look at the idle time immediately instead of waiting for the
// next tick. Non-blocking: a pending kick is enough, a second one adds nothing.
func (m *MouseMover) CheckNow() {
	if m == nil {
		return
	}
	m.mutex.Lock()
	kick := m.kick
	running := m.state.isRunning()
	m.mutex.Unlock()

	if kick == nil || !running {
		return
	}
	select {
	case kick <- struct{}{}:
	default:
	}
}

// Quit stops the loop and waits for it to be gone. Safe to call twice.
func (m *MouseMover) Quit() {
	if m == nil {
		return
	}

	m.mutex.Lock()
	quit, done := m.quit, m.done
	stopping := m.state.isRunning() && quit != nil
	if stopping {
		//Close rather than send. A send needs a receiver, so once the loop had gone
		//away - which a double Start used to arrange - Quit blocked for ever, and with
		//it the menu loop that called it: the app kept running with a dead menu.
		select {
		case <-quit:
		default:
			close(quit)
		}
	}
	if m.logFile != nil {
		m.logFile.Close()
		m.logFile = nil
	}
	m.mutex.Unlock()

	//Wait outside the lock, so the loop can still take it on its way out. done is only
	//nil when the loop never ran.
	if stopping && done != nil {
		<-done
	}
}

// GetInstance gets the singleton instance for mouse mover app
func GetInstance() *MouseMover {
	if instance == nil {
		instance = &MouseMover{
			state:    &state{},
			platform: mac.API{},
		}
	}
	return instance
}
