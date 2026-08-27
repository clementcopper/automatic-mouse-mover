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
	if m.state.isRunning() {
		return
	}
	m.state = &state{}
	m.quit = make(chan struct{})
	m.kick = make(chan struct{}, 1)

	ticker := time.NewTicker(checkInterval)
	m.run(ticker.C, ticker.Stop)
}

// run drives the loop. The tick channel and stop function are parameters so tests can
// drive it themselves instead of waiting on a real ticker.
func (m *MouseMover) run(tick <-chan time.Time, stop func()) {
	go func() {
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

			case <-m.kick:
				m.checkAndMove(logger, state, &movePixel)

			case <-m.quit:
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
		go m.platform.Alert(title, msg)
	}
}

// IsRunning reports whether the mover loop is active.
func (m *MouseMover) IsRunning() bool {
	return m != nil && m.state.isRunning()
}

// CheckNow asks the loop to look at the idle time immediately instead of waiting for the
// next tick. Non-blocking: a pending kick is enough, a second one adds nothing.
func (m *MouseMover) CheckNow() {
	if m == nil || m.kick == nil || !m.state.isRunning() {
		return
	}
	select {
	case m.kick <- struct{}{}:
	default:
	}
}

// Quit the app
func (m *MouseMover) Quit() {
	//making it idempotent
	if m != nil && m.state.isRunning() {
		m.quit <- struct{}{}
	}
	if m.logFile != nil {
		m.logFile.Close()
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
