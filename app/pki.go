package main

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

type pkiBundle struct {
	Certificate string `json:"certificate"`
}

type pkiState struct {
	mu   sync.RWMutex
	cert *x509.Certificate
}

func (s *pkiState) reload(_ context.Context, data []byte) error {
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
	s.cert = cert
	s.mu.Unlock()
	slog.Info("pki cert rotated", "cn", cert.Subject.CommonName, "sans", cert.DNSNames,
		"not_after", cert.NotAfter.Format(time.RFC3339))
	return nil
}

func (s *pkiState) report(_ context.Context) {
	s.mu.RLock()
	cert := s.cert
	s.mu.RUnlock()
	if cert == nil {
		slog.Warn("pki not loaded")
		return
	}
	slog.Info("pki state", "cn", cert.Subject.CommonName, "sans", cert.DNSNames,
		"not_after", cert.NotAfter.Format(time.RFC3339),
		"remaining_s", int(time.Until(cert.NotAfter).Seconds()))
}
