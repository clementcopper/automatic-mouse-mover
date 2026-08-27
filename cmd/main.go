package main

import (
	"log/slog"
	"sync/atomic"

	"github.com/clementcopper/automatic-mouse-mover/assets/icon"
	"github.com/clementcopper/automatic-mouse-mover/internal/mac"
	"github.com/clementcopper/automatic-mouse-mover/internal/mousemover"
)

// version must be kept in sync with CFBundleShortVersionString in appInfo/Info.plist
// and with the release tag.
const version = "1.5.0"

// prefResumeAfterWake stores the "Resume After Wake" tick. The login item state is not
// stored here - macOS owns that one and SMAppService reports it back.
const prefResumeAfterWake = "ResumeAfterWake"

// wantRunning remembers whether the user wants the mover running, so a wake does not
// restart something that was deliberately stopped. Written by the menu loop, read by the
// wake callback on another goroutine, hence atomic.
var wantRunning atomic.Bool

func main() {
	//Route the package-level logger into unified logging too - launched from Finder the
	//app has no stderr, so the default handler would drop everything.
	slog.SetDefault(slog.New(mac.NewLogHandler(slog.LevelInfo)))

	mac.Run(onReady, onExit)
}

// onReady already runs on its own goroutine, so it may block in the menu loop.
func onReady() {
	platform := mac.API{}
	mac.SetIcon(icon.Tray)

	about := mac.AddMenuItem("About AMM", "Information about the app")
	mac.AddSeparator()
	ammStart := mac.AddMenuItem("Start", "start moving the mouse when the machine goes idle")
	ammStop := mac.AddMenuItem("Stop", "stop moving the mouse")
	mac.AddSeparator()
	atLogin := mac.AddMenuItem("Launch at Login", "start AMM automatically when you log in")
	afterWake := mac.AddMenuItem("Resume After Wake", "keep going after the Mac wakes from sleep")
	mac.AddSeparator()
	mQuit := mac.AddMenuItem("Quit", "Quit the whole app")

	mouseMover := mousemover.GetInstance()
	mouseMover.Start()
	ammStart.Disable()
	ammStop.Enable()

	loginStatus := platform.GetLoginItemStatus()
	slog.Info("login item", "status", loginStatus)
	atLogin.SetChecked(loginStatus == mac.LoginItemEnabled)

	//on by default: resuming after sleep is what one expects, and the whole point is
	//that starting the mover cannot be forgotten
	resumeAfterWake := platform.PrefBool(prefResumeAfterWake, true)
	afterWake.SetChecked(resumeAfterWake)

	//A sleeping Mac runs no goroutines, so the loop should survive on its own. Watching
	//for the wake makes that a guarantee rather than an assumption, and checks straight
	//away instead of waiting out the next tick.
	mac.WatchWake(func() {
		if !platform.PrefBool(prefResumeAfterWake, true) {
			return
		}
		if mouseMover.IsRunning() {
			slog.Info("woke up, checking now")
			mouseMover.CheckNow()
			return
		}
		//Only resume what was running. A deliberate Stop stays stopped - a sleep cycle
		//is no reason to override it.
		if wantRunning.Load() {
			slog.Info("woke up, resuming the mover")
			mouseMover.Start()
			ammStart.Disable()
			ammStop.Enable()
		}
	})
	wantRunning.Store(true)

	for {
		select {
		case <-ammStart.ClickedCh:
			slog.Info("starting the app")
			mouseMover.Start()
			wantRunning.Store(true)
			ammStart.Disable()
			ammStop.Enable()

		case <-ammStop.ClickedCh:
			slog.Info("stopping the app")
			ammStart.Enable()
			ammStop.Disable()
			wantRunning.Store(false)
			mouseMover.Quit()

		case <-atLogin.ClickedCh:
			enable := platform.GetLoginItemStatus() != mac.LoginItemEnabled
			if err := platform.SetLoginItem(enable); err != nil {
				//Say why rather than leaving a tick that does nothing.
				slog.Error("could not change the login item", "enable", enable, "err", err)
				go platform.Alert("Launch at Login could not be changed", err.Error())
			}
			status := platform.GetLoginItemStatus()
			atLogin.SetChecked(status == mac.LoginItemEnabled)
			if status == mac.LoginItemRequiresApproval {
				go platform.Alert("Launch at Login needs approval",
					"macOS is holding the request. Open System Settings > General > Login Items and allow amm there.")
			}

		case <-afterWake.ClickedCh:
			resumeAfterWake = !resumeAfterWake
			platform.SetPrefBool(prefResumeAfterWake, resumeAfterWake)
			afterWake.SetChecked(resumeAfterWake)
			slog.Info("resume after wake", "enabled", resumeAfterWake)

		case <-mQuit.ClickedCh:
			slog.Info("requesting quit")
			mouseMover.Quit()
			mac.Quit()
			return

		case <-about.ClickedCh:
			slog.Info("requesting about")
			//Alert blocks until dismissed, so keep it off this loop - otherwise the
			//whole menu stops responding while it is open.
			go platform.Alert("Automatic Mouse Mover "+version,
				"by Daniel Martin\ngithub.com/clementcopper/automatic-mouse-mover\n\nBased on the original by Prashant Gupta, MIT licensed.")
		}
	}
}

func onExit() {
	slog.Info("finished quitting")
}
