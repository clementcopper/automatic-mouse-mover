package mousemover

import (
	"fmt"
	"log/slog"
	"time"

	"github.com/prashantgupta24/automatic-mouse-mover/internal/mac"
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

//how long to wait for a posted mouse event to take effect before calling it a failure.
//A var, not a const, so tests do not have to sit out the real budget.
var moveSettleTimeout = 200 * time.Millisecond

// Start the main app
func (m *MouseMover) Start() {
	if m.state.isRunning() {
		return
	}
	m.state = &state{}
	m.quit = make(chan struct{})

	ticker := time.NewTicker(checkInterval)
	m.run(ticker.C, ticker.Stop)
}

//run drives the loop. The tick channel and stop function are parameters so tests can
//drive it themselves instead of waiting on a real ticker.
func (m *MouseMover) run(tick <-chan time.Time, stop func()) {
	go func() {
		state := m.state
		state.updateRunningStatus(true)

		logger := getLogger(m, false, logFileName) //set writeToFile=true only for debugging
		movePixel := 10

		for {
			select {
			case <-tick:
				idle := m.platform.IdleSeconds()
				if idle < idleThreshold.Seconds() {
					logger.Debug("activity detected, leaving the cursor alone", "idleSeconds", idle)
					continue
				}

				if !moveAndCheck(m.platform, movePixel) {
					m.reportFailedMove(logger, state)
					continue
				}

				state.updateLastMouseMovedTime(time.Now())
				state.updateDidNotMoveCount(0)
				//flip the direction so the cursor oscillates instead of drifting off screen
				movePixel *= -1
				logger.Info("moved mouse", "at", state.getLastMouseMovedTime())

			case <-m.quit:
				logger.Info("stopping mouse mover")
				state.updateRunningStatus(false)
				stop()
				return
			}
		}
	}()
}

//reportFailedMove counts a failed move and, at most once every 24 hours, tells the user
//that AMM is most likely missing Accessibility permission.
func (m *MouseMover) reportFailedMove(logger *slog.Logger, state *state) {
	state.updateDidNotMoveCount(state.getDidNotMoveCount() + 1)
	state.updateLastErrorTime(time.Now())

	msg := fmt.Sprintf("Mouse pointer cannot be moved at %v. Last moved at %v. Happened %v times. (Only notifies once every 24 hours.) See README for details.",
		time.Now(), state.getLastMouseMovedTime(), state.getDidNotMoveCount())
	logger.Error(msg)

	//lastAlertTime is tracked separately from lastErrorTime, which was just set to now -
	//comparing against that one made this condition permanently false.
	lastAlertTime := state.getLastAlertTime()
	if state.getDidNotMoveCount() >= failuresBeforeAlert &&
		(lastAlertTime.IsZero() || time.Since(lastAlertTime).Hours() > 24) {
		state.updateLastAlertTime(time.Now())
		go m.platform.Alert("Error with Automatic Mouse Mover", msg)
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
