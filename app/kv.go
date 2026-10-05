package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"maps"
	"slices"
	"sync"
)

type kvState struct {
	cfg  KVConfig
	mu   sync.RWMutex
	data map[string]any
}

func (s *kvState) reload(_ context.Context, data []byte) error {
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}
	s.mu.Lock()
	s.data = m
	s.mu.Unlock()
	slog.Info("kv reloaded", "kv", s.cfg.Name, "keys", slices.Sorted(maps.Keys(m)))
	return nil
}

func (s *kvState) report(_ context.Context) {
	s.mu.RLock()
	snap := maps.Clone(s.data)
	s.mu.RUnlock()
	if len(snap) == 0 {
		slog.Warn("kv empty", "kv", s.cfg.Name)
		return
	}
	slog.Info("kv state", "kv", s.cfg.Name, "values", snap)
}
