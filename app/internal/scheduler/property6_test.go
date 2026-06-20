package scheduler

import (
	"strconv"
	"testing"
	"time"

	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/config"
	"pgregory.net/rapid"
)

// TestProperty6_ConfiguredIntervalApplied は、有効な間隔設定値が config.LoadConfig
// を通じて Scheduler.Interval に反映され、Scheduler.Next(prev) が常に prev + Interval
// を返すこと、および無効な設定値 (負値・非数値・空) に対して config.LoadConfig が
// エラーを返すことを検証する。
//
// Feature: ecs-otel-log-pipeline, Property 6: 設定された出力間隔の適用
// Validates: Requirements 2.2, 2.3
func TestProperty6_ConfiguredIntervalApplied(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		// --- 有効値の経路 ---
		// 正の整数 (ミリ秒) を有効な間隔設定値として生成する。
		intervalMs := rapid.IntRange(1, 86_400_000).Draw(t, "intervalMs")
		env := map[string]string{"LOG_INTERVAL_MS": strconv.Itoa(intervalMs)}

		cfg, err := config.LoadConfig(env)
		if err != nil {
			t.Fatalf("LoadConfig returned error for valid value %d: %v", intervalMs, err)
		}
		if cfg.IntervalMillis != intervalMs {
			t.Fatalf("expected IntervalMillis=%d, got %d", intervalMs, cfg.IntervalMillis)
		}

		// 設定値から Scheduler を構築する。
		interval := time.Duration(cfg.IntervalMillis) * time.Millisecond
		s := Scheduler{Interval: interval}

		// LoadConfig が読み込んだ間隔が Scheduler.Interval に反映されている。
		if s.Interval != interval {
			t.Fatalf("expected Scheduler.Interval=%v, got %v", interval, s.Interval)
		}

		// 任意の prev 時刻について Next(prev) == prev + Interval が成り立つ。
		unixNanos := rapid.Int64Range(0, 4_000_000_000_000_000_000).Draw(t, "unixNanos")
		prev := time.Unix(0, unixNanos).UTC()

		got := s.Next(prev)
		want := prev.Add(interval)
		if !got.Equal(want) {
			t.Fatalf("Next(%v) = %v, want %v (prev + interval)", prev, got, want)
		}

		// --- 無効値の経路 ---
		// 負値・非数値・空のいずれかを生成し、LoadConfig がエラーを返すことを検証する。
		var invalid string
		switch rapid.IntRange(0, 2).Draw(t, "invalidKind") {
		case 0:
			// 負の整数
			invalid = strconv.Itoa(rapid.IntRange(-1_000_000, -1).Draw(t, "negative"))
		case 1:
			// 非数値の文字列
			invalid = rapid.StringMatching(`[a-zA-Z][a-zA-Z0-9]*`).Draw(t, "nonNumeric")
		default:
			// 空文字列
			invalid = ""
		}

		invalidEnv := map[string]string{"LOG_INTERVAL_MS": invalid}
		if _, err := config.LoadConfig(invalidEnv); err == nil {
			t.Fatalf("expected error for invalid value %q, got nil", invalid)
		}
	})
}
