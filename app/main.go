// Command vault-lab-app is every application of the lab: what it reads
// from Vault comes from its configuration, as files Vault Agent renders.
package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type source interface {
	loader
	report(ctx context.Context)
}

type app struct {
	interval time.Duration
	watchers []*fileWatcher
	sources  []source
}

func newApp(cfg *Config) *app {
	a := &app{interval: cfg.interval}
	for _, d := range cfg.DB {
		a.add(d.CredsFile, &dbState{cfg: d})
	}
	for _, k := range cfg.KV {
		a.add(k.File, &kvState{cfg: k})
	}
	if cfg.PKI != nil {
		a.add(cfg.PKI.File, &pkiState{})
	}
	return a
}

func (a *app) add(path string, s source) {
	a.watchers = append(a.watchers, &fileWatcher{path: path, target: s})
	a.sources = append(a.sources, s)
}

func (a *app) run(ctx context.Context) {
	poll := time.NewTicker(time.Second)
	defer poll.Stop()
	report := time.NewTicker(a.interval)
	defer report.Stop()
	for {
		select {
		case <-ctx.Done():
			slog.Info("app stopping")
			return
		case <-poll.C:
			a.poll(ctx)
		case <-report.C:
			a.report(ctx)
		}
	}
}

func (a *app) poll(ctx context.Context) {
	for _, w := range a.watchers {
		w.poll(ctx)
	}
}

func (a *app) report(ctx context.Context) {
	for _, s := range a.sources {
		s.report(ctx)
	}
}

func main() {
	configPath := flag.String("config", "/etc/app/config.yaml", "app config file")
	flag.Parse()
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	cfg, err := loadConfig(*configPath)
	if err != nil {
		slog.Error("load config", "err", err)
		os.Exit(1)
	}
	slog.Info("app starting", "name", cfg.Name, "kv_count", len(cfg.KV), "db_count", len(cfg.DB),
		"pki", cfg.PKI != nil, "log_interval", cfg.interval.String())

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	newApp(cfg).run(ctx)
}
