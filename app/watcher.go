package main

import (
	"context"
	"log/slog"
	"os"
	"time"
)

type loader interface {
	reload(ctx context.Context, data []byte) error
}

// Polled, not watched with inotify: a stat a second is all a rendered file
// needs, and the binary stays free of a watcher dependency.
type fileWatcher struct {
	path   string
	target loader
	mtime  time.Time
	loaded bool
}

func (w *fileWatcher) poll(ctx context.Context) {
	info, err := os.Stat(w.path)
	if err != nil {
		return
	}
	if w.loaded && info.ModTime().Equal(w.mtime) {
		return
	}
	data, err := os.ReadFile(w.path)
	if err != nil {
		slog.Warn("watcher: read failed", "path", w.path, "err", err)
		return
	}
	if err := w.target.reload(ctx, data); err != nil {
		slog.Warn("watcher: load failed", "path", w.path, "err", err)
		return
	}
	w.mtime = info.ModTime()
	w.loaded = true
}
