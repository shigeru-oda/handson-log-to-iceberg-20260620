// Package main is the entry point for the OTel log generator application.
//
// It wires together the config, otel, and scheduler packages: it loads the
// output interval from the environment, generates OTel Log Data Model records,
// writes each record as a single JSON Lines entry to stdout, and sleeps between
// records according to the configured interval. On invalid configuration it
// fails fast with a clear message and a non-zero exit code (Req 1.4, 2.2, 2.3).
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"os"
	"strings"
	"time"

	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/config"
	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/otel"
	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/scheduler"
)

func main() {
	cfg, err := config.LoadConfig(environMap(os.Environ()))
	if err != nil {
		// フェイルファスト: 設定エラーは明確なログを出して非ゼロ終了する (Req 2.3)。
		fmt.Fprintf(os.Stderr, "fatal: invalid configuration: %v\n", err)
		os.Exit(1)
	}

	sched := scheduler.Scheduler{Interval: time.Duration(cfg.IntervalMillis) * time.Millisecond}
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))

	// maxIterations <= 0 は無限ループを意味する (常駐稼働; Req 2.2)。
	if err := runLoop(os.Stdout, rng, sched, time.Now, time.Sleep, 0); err != nil {
		fmt.Fprintf(os.Stderr, "fatal: %v\n", err)
		os.Exit(1)
	}
}

// runLoop はログ生成ループの中核ロジックである。副作用 (出力先・乱数源・時計・
// スリープ・反復回数) をすべて引数として注入することで、テストから bytes.Buffer・
// 短い間隔・有限回数で実行できるようにしている。
//
// 各反復で 1 件の LogRecord を生成し、JSON Lines (1 行 + 改行) として w へ書き出し、
// scheduler.Next が示す次回時刻までの間隔だけ sleepFn で待機する。
// maxIterations が 0 以下のときは無限に繰り返す (本番の常駐稼働)。
func runLoop(
	w io.Writer,
	rng *rand.Rand,
	sched scheduler.Scheduler,
	nowFn func() time.Time,
	sleepFn func(time.Duration),
	maxIterations int,
) error {
	// json.Encoder は各値の後に改行を付与するため JSON Lines 出力に適する。
	enc := json.NewEncoder(w)

	for i := 0; maxIterations <= 0 || i < maxIterations; i++ {
		now := nowFn()
		rec := otel.Generate(rng, now)
		if err := enc.Encode(rec); err != nil {
			return fmt.Errorf("failed to write log record: %w", err)
		}

		next := sched.Next(now)
		sleepFn(next.Sub(now))
	}

	return nil
}

// environMap は os.Environ() が返す "KEY=VALUE" 形式のスライスを
// config.LoadConfig が要求する map[string]string へ変換する。
func environMap(environ []string) map[string]string {
	m := make(map[string]string, len(environ))
	for _, kv := range environ {
		key, value, found := strings.Cut(kv, "=")
		if !found {
			continue
		}
		m[key] = value
	}
	return m
}
