package config

import (
	"testing"
)

func TestLoadConfig_ValidValue(t *testing.T) {
	env := map[string]string{"LOG_INTERVAL_MS": "1000"}
	cfg, err := LoadConfig(env)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if cfg.IntervalMillis != 1000 {
		t.Fatalf("expected IntervalMillis=1000, got %d", cfg.IntervalMillis)
	}
}

func TestLoadConfig_MinValidValue(t *testing.T) {
	env := map[string]string{"LOG_INTERVAL_MS": "1"}
	cfg, err := LoadConfig(env)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if cfg.IntervalMillis != 1 {
		t.Fatalf("expected IntervalMillis=1, got %d", cfg.IntervalMillis)
	}
}

func TestLoadConfig_Empty(t *testing.T) {
	env := map[string]string{"LOG_INTERVAL_MS": ""}
	_, err := LoadConfig(env)
	if err == nil {
		t.Fatal("expected error for empty value, got nil")
	}
}

func TestLoadConfig_Missing(t *testing.T) {
	env := map[string]string{}
	_, err := LoadConfig(env)
	if err == nil {
		t.Fatal("expected error for missing key, got nil")
	}
}

func TestLoadConfig_Zero(t *testing.T) {
	env := map[string]string{"LOG_INTERVAL_MS": "0"}
	_, err := LoadConfig(env)
	if err == nil {
		t.Fatal("expected error for zero value, got nil")
	}
}

func TestLoadConfig_Negative(t *testing.T) {
	env := map[string]string{"LOG_INTERVAL_MS": "-5"}
	_, err := LoadConfig(env)
	if err == nil {
		t.Fatal("expected error for negative value, got nil")
	}
}

func TestLoadConfig_NonNumeric(t *testing.T) {
	env := map[string]string{"LOG_INTERVAL_MS": "abc"}
	_, err := LoadConfig(env)
	if err == nil {
		t.Fatal("expected error for non-numeric value, got nil")
	}
}

func TestLoadConfig_Float(t *testing.T) {
	env := map[string]string{"LOG_INTERVAL_MS": "3.14"}
	_, err := LoadConfig(env)
	if err == nil {
		t.Fatal("expected error for float value, got nil")
	}
}
