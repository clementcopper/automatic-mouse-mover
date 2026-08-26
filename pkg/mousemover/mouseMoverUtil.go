package mousemover

import (
	"log/slog"
	"os"
	"time"
)

// getLogger returns the logger for one run. Writing to a file is off by default and
// only meant for debugging; a file that cannot be opened downgrades to stderr rather
// than killing the app.
func getLogger(m *MouseMover, doWriteToFile bool, filename string) *slog.Logger {
	out := os.Stderr

	if doWriteToFile {
		if err := os.MkdirAll(logDir, os.ModePerm); err != nil {
			slog.Error("could not create log dir, logging to stderr", "dir", logDir, "err", err)
			return slog.New(slog.NewTextHandler(out, nil))
		}

		logFile, err := os.OpenFile(logDir+"/"+filename, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0666)
		if err != nil {
			slog.Error("could not open log file, logging to stderr", "file", filename, "err", err)
			return slog.New(slog.NewTextHandler(out, nil))
		}
		m.logFile = logFile
		out = logFile
	}

	return slog.New(slog.NewTextHandler(out, nil))
}

// moveAndCheck nudges the cursor and reports whether it actually moved. An unchanged
// position means macOS swallowed the event, which is what happens when AMM has not been
// granted Accessibility permission.
func moveAndCheck(p platform, movePixel int) bool {
	currentX, currentY := p.MousePos()
	p.MoveMouse(currentX+movePixel, currentY+movePixel)

	movedX, movedY := p.MousePos()
	return movedX != currentX || movedY != currentY
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
