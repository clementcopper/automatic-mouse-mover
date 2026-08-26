package main

import (
	"log/slog"

	"github.com/prashantgupta24/automatic-mouse-mover/assets/icon"
	"github.com/prashantgupta24/automatic-mouse-mover/internal/mac"
	"github.com/prashantgupta24/automatic-mouse-mover/pkg/mousemover"
)

//version must be kept in sync with CFBundleShortVersionString in appInfo/Info.plist
//and with the release tag.
const version = "1.4.0"

func main() {
	mac.Run(onReady, onExit)
}

//onReady already runs on its own goroutine, so it may block in the menu loop.
func onReady() {
	mac.SetIcon(icon.CloudIcon)

	about := mac.AddMenuItem("About AMM", "Information about the app")
	mac.AddSeparator()
	ammStart := mac.AddMenuItem("Start", "start the app")
	ammStop := mac.AddMenuItem("Stop", "stop the app")
	mac.AddSeparator()
	mQuit := mac.AddMenuItem("Quit", "Quit the whole app")

	mouseMover := mousemover.GetInstance()
	mouseMover.Start()
	ammStart.Disable()
	ammStop.Enable()

	for {
		select {
		case <-ammStart.ClickedCh:
			slog.Info("starting the app")
			mouseMover.Start()
			ammStart.Disable()
			ammStop.Enable()

		case <-ammStop.ClickedCh:
			slog.Info("stopping the app")
			ammStart.Enable()
			ammStop.Disable()
			mouseMover.Quit()

		case <-mQuit.ClickedCh:
			slog.Info("requesting quit")
			mouseMover.Quit()
			mac.Quit()
			return

		case <-about.ClickedCh:
			slog.Info("requesting about")
			//Alert blocks until dismissed, so keep it off this loop - otherwise the
			//whole menu stops responding while it is open.
			go mac.API{}.Alert("Automatic-mouse-mover app v"+version,
				"Developed by Prashant Gupta. \n\nMore info at: https://github.com/prashantgupta24/automatic-mouse-mover")
		}
	}
}

func onExit() {
	slog.Info("finished quitting")
}
