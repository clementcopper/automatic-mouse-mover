package mousemover

import (
	"os"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/suite"
)

//fakePlatform stands in for internal/mac so the tests never touch cgo, the real cursor
//or a real dialog.
type fakePlatform struct {
	mutex sync.Mutex

	idleSeconds float64
	//canMove false simulates a missing Accessibility permission: the position never
	//changes, which is exactly how macOS behaves when it drops the event.
	canMove bool

	x, y       int
	moveCount  int
	alertCount int
}

func (f *fakePlatform) IdleSeconds() float64 {
	f.mutex.Lock()
	defer f.mutex.Unlock()
	return f.idleSeconds
}

func (f *fakePlatform) MousePos() (int, int) {
	f.mutex.Lock()
	defer f.mutex.Unlock()
	return f.x, f.y
}

func (f *fakePlatform) MoveMouse(x, y int) {
	f.mutex.Lock()
	defer f.mutex.Unlock()
	f.moveCount++
	if f.canMove {
		f.x, f.y = x, y
	}
}

func (f *fakePlatform) Alert(title, msg string) {
	f.mutex.Lock()
	defer f.mutex.Unlock()
	f.alertCount++
}

func (f *fakePlatform) counts() (moves, alerts int) {
	f.mutex.Lock()
	defer f.mutex.Unlock()
	return f.moveCount, f.alertCount
}

type TestMover struct {
	suite.Suite
	tickCh chan time.Time
	fake   *fakePlatform
}

func TestSuite(t *testing.T) {
	suite.Run(t, new(TestMover))
}

// Run once before each test
func (suite *TestMover) SetupTest() {
	instance = nil
	suite.tickCh = make(chan time.Time)
	suite.fake = &fakePlatform{canMove: true}
}

//newMover returns a started mover wired to the fake platform.
func (suite *TestMover) newMover(idleSeconds float64, canMove bool) *MouseMover {
	suite.fake.idleSeconds = idleSeconds
	suite.fake.canMove = canMove

	mouseMover := GetInstance()
	mouseMover.platform = suite.fake
	mouseMover.state = &state{}
	mouseMover.quit = make(chan struct{})
	mouseMover.run(suite.tickCh, func() {})
	time.Sleep(time.Millisecond * 100) //wait for the loop to start

	return mouseMover
}

//tick drives n iterations of the loop and waits for them to be processed.
func (suite *TestMover) tick(n int) {
	for i := 0; i < n; i++ {
		suite.tickCh <- time.Now()
	}
	time.Sleep(time.Millisecond * 100)
}

func (suite *TestMover) TestAppStart() {
	t := suite.T()
	mouseMover := suite.newMover(idleThreshold.Seconds()+1, true)
	assert.True(t, mouseMover.state.isRunning(), "app should have started")
}

func (suite *TestMover) TestSingleton() {
	t := suite.T()
	mouseMover1 := suite.newMover(idleThreshold.Seconds()+1, true)
	mouseMover2 := GetInstance()
	assert.Same(t, mouseMover1, mouseMover2, "should be the same instance")
	assert.True(t, mouseMover2.state.isRunning(), "instance should have started")
}

func (suite *TestMover) TestLogFile() {
	t := suite.T()
	mouseMover := GetInstance()
	logFileName := "test1"

	getLogger(mouseMover, true, logFileName)

	filePath := logDir + "/" + logFileName
	assert.FileExists(t, filePath, "log file should exist")
	os.RemoveAll(logDir)
}

//TestActivityLeavesCursorAlone is the core promise of the app: while the user is at the
//machine, AMM must not touch the cursor.
func (suite *TestMover) TestActivityLeavesCursorAlone() {
	t := suite.T()
	mouseMover := suite.newMover(idleThreshold.Seconds()-1, true)

	suite.tick(3)

	moves, _ := suite.fake.counts()
	assert.Equal(t, 0, moves, "should not move while the user is active")
	assert.True(t, mouseMover.state.getLastMouseMovedTime().IsZero(), "should be default")
}

func (suite *TestMover) TestMouseMoveSuccess() {
	t := suite.T()
	mouseMover := suite.newMover(idleThreshold.Seconds()+1, true)

	suite.tick(1)

	moves, _ := suite.fake.counts()
	assert.Equal(t, 1, moves, "should have moved once")
	assert.False(t, mouseMover.state.getLastMouseMovedTime().IsZero(), "move time should be set")
	assert.Equal(t, 0, mouseMover.state.getDidNotMoveCount(), "should be 0")
}

//TestMoveDirectionAlternates guards the sign flip that keeps the cursor oscillating
//instead of drifting off screen.
func (suite *TestMover) TestMoveDirectionAlternates() {
	t := suite.T()
	suite.newMover(idleThreshold.Seconds()+1, true)

	suite.tick(1)
	x1, y1 := suite.fake.MousePos()
	suite.tick(1)
	x2, y2 := suite.fake.MousePos()

	assert.NotEqual(t, 0, x1, "first move should go somewhere")
	assert.Equal(t, 0, x2, "second move should come back to the start")
	assert.Equal(t, 0, y2, "second move should come back to the start")
	assert.NotEqual(t, x1, x2, "direction should have flipped")
	assert.NotEqual(t, y1, y2, "direction should have flipped")
}

func (suite *TestMover) TestMouseMoveFailure() {
	t := suite.T()
	mouseMover := suite.newMover(idleThreshold.Seconds()+1, false)

	suite.tick(1)

	assert.True(t, mouseMover.state.getLastMouseMovedTime().IsZero(), "should stay default")
	assert.Equal(t, 1, mouseMover.state.getDidNotMoveCount(), "should have counted a failure")
	assert.False(t, mouseMover.state.getLastErrorTime().IsZero(), "error time should be set")
}

//TestAlertThrottle guards the 24-hour alert window. It used to compare against
//lastErrorTime, which was set to time.Now() a few lines above the check, so the
//condition was never true and the accessibility alert never showed.
func (suite *TestMover) TestAlertThrottle() {
	t := suite.T()
	mouseMover := suite.newMover(idleThreshold.Seconds()+1, false)
	assert.True(t, mouseMover.state.getLastAlertTime().IsZero(), "should be default")

	suite.tick(failuresBeforeAlert)

	_, alerts := suite.fake.counts()
	assert.Equal(t, failuresBeforeAlert, mouseMover.state.getDidNotMoveCount(), "all moves should have failed")
	assert.Equal(t, 1, alerts, "alert should have fired at the threshold")
	assert.False(t, mouseMover.state.getLastAlertTime().IsZero(), "alert time should be set")

	//a second batch within the 24 hour window must not re-arm the alert
	firstAlertTime := mouseMover.state.getLastAlertTime()
	suite.tick(failuresBeforeAlert)

	_, alerts = suite.fake.counts()
	assert.Equal(t, 1, alerts, "alert should only fire once per 24 hours")
	assert.Equal(t, firstAlertTime, mouseMover.state.getLastAlertTime(), "alert time should not move")
}
