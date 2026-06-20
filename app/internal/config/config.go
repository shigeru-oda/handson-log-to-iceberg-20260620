// Package config handles application configuration loading from environment variables.
package config

import (
	"fmt"
	"strconv"
)

// Config holds the application configuration values.
type Config struct {
	IntervalMillis int // 環境変数 LOG_INTERVAL_MS から読み込む (Req 2.3)
}

// LoadConfig reads configuration from the provided environment variable map.
// It returns an error if LOG_INTERVAL_MS is missing, empty, non-numeric, zero, or negative.
func LoadConfig(env map[string]string) (Config, error) {
	raw, ok := env["LOG_INTERVAL_MS"]
	if !ok || raw == "" {
		return Config{}, fmt.Errorf("LOG_INTERVAL_MS is required but not set or empty")
	}

	val, err := strconv.Atoi(raw)
	if err != nil {
		return Config{}, fmt.Errorf("LOG_INTERVAL_MS must be a valid integer: %w", err)
	}

	if val <= 0 {
		return Config{}, fmt.Errorf("LOG_INTERVAL_MS must be a positive integer, got %d", val)
	}

	return Config{IntervalMillis: val}, nil
}
