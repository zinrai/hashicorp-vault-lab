package main

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"gopkg.in/yaml.v3"
)

type Config struct {
	Name           string `yaml:"name"`
	LogIntervalRaw string `yaml:"log_interval"`
	LogInterval    time.Duration
	KV             []KVConfig `yaml:"kv"`
	DB             []DBConfig `yaml:"db"`
	PKI            *PKIConfig `yaml:"pki"`
}

type KVConfig struct {
	Name string `yaml:"name"`
	File string `yaml:"file"`
}

type DBConfig struct {
	Name      string `yaml:"name"`
	Host      string `yaml:"host"`
	Port      int    `yaml:"port"`
	Database  string `yaml:"database"`
	CredsFile string `yaml:"creds_file"`
}

type PKIConfig struct {
	File string `yaml:"file"`
}

type dbCreds struct {
	Username      string `json:"username"`
	Password      string `json:"password"`
	LeaseID       string `json:"lease_id"`
	LeaseDuration int    `json:"lease_duration"`
}

type pkiBundle struct {
	Certificate string `json:"certificate"`
	PrivateKey  string `json:"private_key"`
	IssuingCA   string `json:"issuing_ca"`
}

type dbState struct {
	mu         sync.RWMutex
	cfg        DBConfig
	pool       *pgxpool.Pool
	creds      dbCreds
	closeAfter time.Duration
}

func newDBState(cfg DBConfig) *dbState {
	if cfg.Port == 0 {
		cfg.Port = 5432
	}
	if cfg.Database == "" {
		cfg.Database = "postgres"
	}
	return &dbState{cfg: cfg, closeAfter: 30 * time.Second}
}

func (s *dbState) reload(ctx context.Context, data []byte) error {
	var c dbCreds
	if err := json.Unmarshal(data, &c); err != nil {
		return fmt.Errorf("parse db creds: %w", err)
	}
	connStr := fmt.Sprintf(
		"host=%s port=%d dbname=%s user=%s password=%s sslmode=disable pool_max_conns=4",
		s.cfg.Host, s.cfg.Port, s.cfg.Database, c.Username, c.Password,
	)
	pool, err := pgxpool.New(ctx, connStr)
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
	s.pool = pool
	s.creds = c
	s.mu.Unlock()

	if old != nil {
		go func(p *pgxpool.Pool) {
			time.Sleep(s.closeAfter)
			p.Close()
		}(old)
	}

	slog.Info("db pool rotated",
		"db", s.cfg.Name,
		"username", c.Username,
		"lease_id", c.LeaseID,
		"lease_duration_s", c.LeaseDuration,
	)
	return nil
}

func (s *dbState) probe(ctx context.Context) (string, string, int, error) {
	s.mu.RLock()
	pool := s.pool
	creds := s.creds
	s.mu.RUnlock()
	if pool == nil {
		return "", "", 0, errors.New("no pool yet")
	}
	c, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	var v int
	if err := pool.QueryRow(c, "SELECT 1").Scan(&v); err != nil {
		return creds.Username, creds.LeaseID, creds.LeaseDuration, err
	}
	return creds.Username, creds.LeaseID, creds.LeaseDuration, nil
}

type kvState struct {
	mu   sync.RWMutex
	cfg  KVConfig
	data map[string]any
}

func (s *kvState) reload(data []byte) error {
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}
	s.mu.Lock()
	s.data = m
	s.mu.Unlock()
	slog.Info("kv reloaded", "kv", s.cfg.Name, "keys", keys(m))
	return nil
}

func (s *kvState) snapshot() map[string]any {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]any, len(s.data))
	for k, v := range s.data {
		out[k] = v
	}
	return out
}

func keys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

type pkiState struct {
	mu       sync.RWMutex
	cfg      PKIConfig
	cn       string
	sans     []string
	notAfter time.Time
}

func (s *pkiState) reload(data []byte) error {
	var b pkiBundle
	if err := json.Unmarshal(data, &b); err != nil {
		return err
	}
	block, _ := pem.Decode([]byte(b.Certificate))
	if block == nil {
		return errors.New("no PEM block in certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return fmt.Errorf("parse cert: %w", err)
	}
	s.mu.Lock()
	s.cn = cert.Subject.CommonName
	s.sans = cert.DNSNames
	s.notAfter = cert.NotAfter
	s.mu.Unlock()
	slog.Info("pki cert rotated",
		"cn", cert.Subject.CommonName,
		"sans", cert.DNSNames,
		"not_after", cert.NotAfter.Format(time.RFC3339),
	)
	return nil
}

func (s *pkiState) snapshot() (string, []string, time.Time) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cn, s.sans, s.notAfter
}

type fileWatcher struct {
	path   string
	mtime  time.Time
	onLoad func([]byte) error
	loaded bool
}

func (w *fileWatcher) poll(ctx context.Context) {
	info, err := os.Stat(w.path)
	if err != nil {
		if !w.loaded {
			slog.Debug("watcher: file not present yet", "path", w.path)
		}
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
	if err := w.onLoad(data); err != nil {
		slog.Warn("watcher: load failed", "path", w.path, "err", err)
		return
	}
	w.mtime = info.ModTime()
	w.loaded = true
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := yaml.Unmarshal(data, &c); err != nil {
		return nil, err
	}
	if c.Name == "" {
		return nil, errors.New("config: name is required")
	}
	if c.LogIntervalRaw != "" {
		d, err := time.ParseDuration(c.LogIntervalRaw)
		if err != nil {
			return nil, fmt.Errorf("parse log_interval: %w", err)
		}
		c.LogInterval = d
	}
	if c.LogInterval == 0 {
		c.LogInterval = 30 * time.Second
	}
	return &c, nil
}

func main() {
	configPath := flag.String("config", "/etc/app/config.yaml", "app config file")
	flag.Parse()

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	cfg, err := loadConfig(*configPath)
	if err != nil {
		slog.Error("load config", "err", err)
		os.Exit(1)
	}
	slog.Info("app starting",
		"name", cfg.Name,
		"kv_count", len(cfg.KV),
		"db_count", len(cfg.DB),
		"pki", cfg.PKI != nil,
		"log_interval", cfg.LogInterval.String(),
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigC := make(chan os.Signal, 1)
	signal.Notify(sigC, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigC
		slog.Info("shutdown signal received")
		cancel()
	}()

	var watchers []*fileWatcher
	var dbStates []*dbState
	var kvStates []*kvState
	var pkiSt *pkiState

	for _, d := range cfg.DB {
		st := newDBState(d)
		dbStates = append(dbStates, st)
		watchers = append(watchers, &fileWatcher{
			path:   d.CredsFile,
			onLoad: func(data []byte) error { return st.reload(ctx, data) },
		})
	}
	for _, k := range cfg.KV {
		st := &kvState{cfg: k}
		kvStates = append(kvStates, st)
		watchers = append(watchers, &fileWatcher{
			path:   k.File,
			onLoad: st.reload,
		})
	}
	if cfg.PKI != nil {
		pkiSt = &pkiState{cfg: *cfg.PKI}
		watchers = append(watchers, &fileWatcher{
			path:   cfg.PKI.File,
			onLoad: pkiSt.reload,
		})
	}

	pollTick := time.NewTicker(1 * time.Second)
	defer pollTick.Stop()
	logTick := time.NewTicker(cfg.LogInterval)
	defer logTick.Stop()

	for {
		select {
		case <-ctx.Done():
			slog.Info("app stopping")
			return
		case <-pollTick.C:
			for _, w := range watchers {
				w.poll(ctx)
			}
		case <-logTick.C:
			emitState(ctx, cfg, dbStates, kvStates, pkiSt)
		}
	}
}

func emitState(ctx context.Context, cfg *Config, dbs []*dbState, kvs []*kvState, pki *pkiState) {
	for _, d := range dbs {
		user, lease, dur, err := d.probe(ctx)
		if err != nil {
			slog.Warn("db check failed", "db", d.cfg.Name, "username", user, "lease_id", lease, "err", err.Error())
			continue
		}
		slog.Info("db check ok",
			"db", d.cfg.Name,
			"username", user,
			"lease_id", lease,
			"lease_duration_s", dur,
		)
	}
	for _, k := range kvs {
		snap := k.snapshot()
		if len(snap) == 0 {
			slog.Warn("kv empty", "kv", k.cfg.Name)
			continue
		}
		slog.Info("kv state", "kv", k.cfg.Name, "values", snap)
	}
	if pki != nil {
		cn, sans, notAfter := pki.snapshot()
		if cn == "" {
			slog.Warn("pki not loaded")
			return
		}
		slog.Info("pki state",
			"cn", cn,
			"sans", sans,
			"not_after", notAfter.Format(time.RFC3339),
			"remaining_s", int(time.Until(notAfter).Seconds()),
		)
	}
}
