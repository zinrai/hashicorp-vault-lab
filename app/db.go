package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type dbCreds struct {
	Username      string `json:"username"`
	Password      string `json:"password"`
	LeaseID       string `json:"lease_id"`
	LeaseDuration int    `json:"lease_duration"`
}

// Closed later, not at once: queries already running on the old pool, with
// the old credentials, finish first.
const oldPoolGrace = 30 * time.Second

type dbState struct {
	cfg   DBConfig
	mu    sync.RWMutex
	pool  *pgxpool.Pool
	creds dbCreds
}

// Port and database fixed, not configurable: every lab database is the
// postgres image's default.
func (s *dbState) reload(ctx context.Context, data []byte) error {
	var c dbCreds
	if err := json.Unmarshal(data, &c); err != nil {
		return fmt.Errorf("parse db creds: %w", err)
	}
	pool, err := pgxpool.New(ctx, fmt.Sprintf(
		"host=%s port=5432 dbname=postgres user=%s password=%s sslmode=disable pool_max_conns=4",
		s.cfg.Host, c.Username, c.Password))
	if err != nil {
		return fmt.Errorf("new pool: %w", err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return fmt.Errorf("ping new pool: %w", err)
	}

	s.mu.Lock()
	old := s.pool
	s.pool, s.creds = pool, c
	s.mu.Unlock()
	if old != nil {
		time.AfterFunc(oldPoolGrace, old.Close)
	}
	slog.Info("db pool rotated", "db", s.cfg.Name, "username", c.Username,
		"lease_id", c.LeaseID, "lease_duration_s", c.LeaseDuration)
	return nil
}

func (s *dbState) report(ctx context.Context) {
	s.mu.RLock()
	pool, c := s.pool, s.creds
	s.mu.RUnlock()
	if err := ping(ctx, pool); err != nil {
		slog.Warn("db check failed", "db", s.cfg.Name, "username", c.Username, "lease_id", c.LeaseID, "err", err.Error())
		return
	}
	slog.Info("db check ok", "db", s.cfg.Name, "username", c.Username,
		"lease_id", c.LeaseID, "lease_duration_s", c.LeaseDuration)
}

func ping(ctx context.Context, pool *pgxpool.Pool) error {
	if pool == nil {
		return errors.New("no pool yet")
	}
	c, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	var v int
	return pool.QueryRow(c, "SELECT 1").Scan(&v)
}
