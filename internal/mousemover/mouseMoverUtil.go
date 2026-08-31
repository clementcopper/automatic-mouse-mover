package mousemover

import (
	"log/slog"
	"os"
	"time"

	"github.com/clementcopper/automatic-mouse-mover/internal/mac"
)

// getLogger returns the logger for one run. By default it writes into unified logging,
// which is the only place a Finder-launched app's output can be read. Writing to a file
// is a debugging switch; a file that cannot be opened falls back rather than killing the
// app.
func getLogger(m *MouseMover, doWriteToFile bool, filename string) *slog.Logger {
	//Default goes to unified logging: a Finder-launched app has no stderr, so a plain
	//text handler would write into nothing.
	if !doWriteToFile {
		return slog.New(mac.NewLogHandler(slog.LevelInfo))
	}

	if err := os.MkdirAll(logDir, os.ModePerm); err != nil {
		slog.Error("could not create log dir, logging to the system log", "dir", logDir, "err", err)
		return slog.New(mac.NewLogHandler(slog.LevelInfo))
	}

	logFile, err := os.OpenFile(logDir+"/"+filename, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0666)
	if err != nil {
		slog.Error("could not open log file, logging to the system log", "file", filename, "err", err)
		return slog.New(mac.NewLogHandler(slog.LevelInfo))
	}
	m.logFile = logFile

	return slog.New(slog.NewTextHandler(logFile, nil))
}

// moveAndCheck nudges the cursor and reports whether it actually moved. Failing both
// directions means macOS swallowed the event, which is what happens when AMM has not
// been granted Accessibility permission.
func moveAndCheck(p platform, movePixel int) bool {
	if tryMove(p, movePixel) {
		return true
	}
	//A cursor parked in a screen corner cannot go any further that way: macOS clamps
	//the event to the edge and the position never changes, which looks exactly like a
	//dropped event. The sign only flips after a success, so without this the mover
	//stayed stuck in the corner for ever and eventually claimed the Accessibility
	//permission was missing. Try the other way before believing that.
	return tryMove(p, -movePixel)
}

// tryMove posts one move and waits to see whether it landed.
//
// CGEventPost is asynchronous: the cursor position does not update until the event has
// been delivered, so reading it straight back reports every single move as failed. Poll
// instead, which returns as soon as the move lands and only spends the full budget when
// the move really was swallowed.
func tryMove(p platform, movePixel int) bool {
	currentX, currentY := p.MousePos()
	p.MoveMouse(currentX+movePixel, currentY+movePixel)

	deadline := time.Now().Add(moveSettleTimeout)
	for {
		movedX, movedY := p.MousePos()
		if movedX != currentX || movedY != currentY {
			return true
		}
		if !time.Now().Before(deadline) {
			return false
		}
		time.Sleep(moveSettleInterval)
	}
}

// getters and setters for state variable
func (s *state) isRunning() bool {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return s.isAppRunning
}

func (s *state) updateRunningStatus(isRunning bool) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	s.isAppRunning = isRunning
}

func (s *state) getLastMouseMovedTime() time.Time {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return s.lastMouseMovedTime
}

func (s *state) updateLastMouseMovedTime(time time.Time) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	s.lastMouseMovedTime = time
}

func (s *state) getLastErrorTime() time.Time {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return s.lastErrorTime
}

func (s *state) updateLastErrorTime(time time.Time) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	s.lastErrorTime = time
}

func (s *state) getLastAlertTime() time.Time {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return s.lastAlertTime
}

func (s *state) updateLastAlertTime(time time.Time) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	s.lastAlertTime = time
}

func (s *state) getDidNotMoveCount() int {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return s.didNotMoveCount
}

func (s *state) updateDidNotMoveCount(count int) {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	s.didNotMoveCount = count
}
