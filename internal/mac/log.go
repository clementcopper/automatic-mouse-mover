package mac

/*
#include <stdlib.h>
#include "log.h"
*/
import "C"

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"unsafe"
)

// LogHandler writes slog records into Apple's unified logging.
//
// The app is a menu bar app: launched from Finder it has no stderr, so the default slog
// handler writes into nothing. Through os_log the records show up in Console.app and in
// `log show --predicate 'process == "amm"'`, which is the only way to diagnose the app
// as it actually runs.
type LogHandler struct {
	level slog.Level
	attrs []slog.Attr
}

// NewLogHandler returns a handler that logs at the given level and above.
func NewLogHandler(level slog.Level) *LogHandler {
	return &LogHandler{level: level}
}

func (h *LogHandler) Enabled(_ context.Context, level slog.Level) bool {
	return level >= h.level
}

func (h *LogHandler) Handle(_ context.Context, record slog.Record) error {
	var b strings.Builder
	b.WriteString(record.Message)

	write := func(a slog.Attr) bool {
		fmt.Fprintf(&b, " %s=%v", a.Key, a.Value.Any())
		return true
	}
	for _, a := range h.attrs {
		write(a)
	}
	record.Attrs(write)

	msg := C.CString(b.String())
	defer C.free(unsafe.Pointer(msg))

	C.amm_log(C.int(osLogLevel(record.Level)), msg)
	return nil
}

func (h *LogHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	merged := make([]slog.Attr, 0, len(h.attrs)+len(attrs))
	merged = append(merged, h.attrs...)
	merged = append(merged, attrs...)
	return &LogHandler{level: h.level, attrs: merged}
}

// WithGroup is required by the interface. The app does not group attributes, so the
// handler is returned unchanged rather than pretending to support it.
func (h *LogHandler) WithGroup(string) slog.Handler { return h }

func osLogLevel(level slog.Level) int {
	switch {
	case level <= slog.LevelDebug:
		return 0
	case level >= slog.LevelError:
		return 2
	default:
		return 1
	}
}
