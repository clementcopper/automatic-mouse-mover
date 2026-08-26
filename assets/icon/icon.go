// Package icon holds the menu bar artwork.
//
// To change the icon, drop a replacement in as assets/icon/tray.png or tray.svg and
// rebuild - there is no generator step. Keep exactly one tray.* file.
//
// Two requirements, both enforced by how macOS draws it:
//
//   - It must be pure black plus an alpha channel. The icon is drawn as a template
//     image, so AppKit tints it from the alpha and discards colour - black on a light
//     menu bar, white on a dark one. Anything coloured collapses into a silhouette.
//   - PNG or SVG. SVG is vector and stays sharp at any scale; for PNG, 32x32 matches
//     the 16pt icon on a Retina display exactly.
package icon

import (
	"embed"
	"io/fs"
	"log/slog"
)

//go:embed tray.*
var files embed.FS

// Tray is the menu bar artwork, ready to hand to NSImage.
var Tray = loadTray()

func loadTray() []byte {
	names, err := fs.Glob(files, "tray.*")
	if err != nil || len(names) == 0 {
		//unreachable in a successful build: //go:embed fails to compile without a match
		slog.Error("no tray icon embedded", "err", err)
		return nil
	}
	if len(names) > 1 {
		slog.Warn("several tray icons embedded, using the first", "found", names)
	}

	data, err := files.ReadFile(names[0])
	if err != nil {
		slog.Error("could not read the embedded tray icon", "name", names[0], "err", err)
		return nil
	}
	return data
}
