/*
Package mousemover keeps a Mac awake by nudging the cursor whenever the machine has been
idle for a while, so messaging apps do not flip the user's status to away.

The engine holds no macOS code of its own. Everything native sits behind the platform
interface, which internal/mac implements and tests replace with a fake, so the package
builds and tests without cgo, a real cursor or a real dialog.

GetInstance returns the singleton. Start begins the loop, Quit ends it, CheckNow asks for
an immediate check instead of waiting out the next tick.
*/
package mousemover
