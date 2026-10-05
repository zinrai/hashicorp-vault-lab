package main

import (
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/goccy/go-yaml"
)

type Config struct {
	Name        string     `yaml:"name"`
	LogInterval string     `yaml:"log_interval"`
	KV          []KVConfig `yaml:"kv"`
	DB          []DBConfig `yaml:"db"`
	PKI         *PKIConfig `yaml:"pki"`
	interval    time.Duration
}

type KVConfig struct {
	Name string `yaml:"name"`
	File string `yaml:"file"`
}

type DBConfig struct {
	Name      string `yaml:"name"`
	Host      string `yaml:"host"`
	CredsFile string `yaml:"creds_file"`
}

type PKIConfig struct {
	File string `yaml:"file"`
}

// Strict, not lenient: a misspelt key in apps/<name>.yaml would otherwise
// leave an application quietly without the credentials it is meant to show.
func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := yaml.UnmarshalWithOptions(data, &c, yaml.Strict()); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if c.Name == "" || c.LogInterval == "" {
		return nil, fmt.Errorf("%s: name and log_interval are required", path)
	}
	if c.interval, err = time.ParseDuration(c.LogInterval); err != nil {
		return nil, fmt.Errorf("%s: log_interval: %w", path, err)
	}
	if c.interval <= 0 {
		return nil, errors.New(path + ": log_interval must be positive")
	}
	return &c, nil
}
