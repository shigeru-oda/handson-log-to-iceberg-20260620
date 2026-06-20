package main

import (
	"bytes"
	"encoding/json"
	"math/rand"
	"strings"
	"testing"
	"time"

	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/otel"
	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/scheduler"
)

// TestRunLoopWritesBoundedJSONLines は main ループ (runLoop) の統合テストである。
//
// 出力先に bytes.Buffer、短い間隔の Scheduler、no-op の sleepFn、有限の反復回数を
// 注入することで、実際の待機を発生させずに複数行の JSON Lines が出力されることを
// 検証する。各行は otel.LogRecord として再パースでき、必須フィールドが埋まっている
// ことを確認する (Req 1.4, 2.2)。
func TestRunLoopWritesBoundedJSONLines(t *testing.T) {
	const (
		maxIterations = 5
		interval      = 10 * time.Millisecond
	)

	var buf bytes.Buffer
	rng := rand.New(rand.NewSource(1))
	sched := scheduler.Scheduler{Interval: interval}

	// 時計は決定的に進める。各反復で interval ずつ進む固定の now を返す。
	base := time.Date(2026, 6, 20, 12, 0, 0, 0, time.UTC)
	calls := 0
	nowFn := func() time.Time {
		t := base.Add(time.Duration(calls) * interval)
		calls++
		return t
	}

	// sleepFn は実際には待機せず、呼び出された間隔を記録する。
	var sleepDurations []time.Duration
	sleepFn := func(d time.Duration) {
		sleepDurations = append(sleepDurations, d)
	}

	if err := runLoop(&buf, rng, sched, nowFn, sleepFn, maxIterations); err != nil {
		t.Fatalf("runLoop returned error: %v", err)
	}

	// 出力は厳密に maxIterations 行の非空 JSON Lines であること。
	out := buf.String()
	if !strings.HasSuffix(out, "\n") {
		t.Errorf("output must end with a newline, got %q", out)
	}

	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != maxIterations {
		t.Fatalf("expected %d JSON lines, got %d: %q", maxIterations, len(lines), out)
	}

	for i, line := range lines {
		if strings.TrimSpace(line) == "" {
			t.Errorf("line %d is empty", i)
			continue
		}

		var rec otel.LogRecord
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Errorf("line %d is not valid JSON: %v (%q)", i, err, line)
			continue
		}

		// 必須フィールドが埋まっていることを検証する (Req 1.3 経由の 1.4)。
		if rec.Timestamp.IsZero() {
			t.Errorf("line %d: timestamp is zero", i)
		}
		if rec.SeverityNumber < 1 || rec.SeverityNumber > 24 {
			t.Errorf("line %d: severityNumber %d out of OTel range 1..24", i, rec.SeverityNumber)
		}
		if rec.SeverityText == "" {
			t.Errorf("line %d: severityText is empty", i)
		}
		if rec.Body == "" {
			t.Errorf("line %d: body is empty", i)
		}
		if len(rec.Resource) == 0 {
			t.Errorf("line %d: resource is empty", i)
		}
		if len(rec.Attributes) == 0 {
			t.Errorf("line %d: attributes is empty", i)
		}
	}

	// sleepFn は反復ごとに 1 回、設定された間隔で呼ばれること (Req 2.2)。
	if len(sleepDurations) != maxIterations {
		t.Fatalf("expected sleepFn to be called %d times, got %d", maxIterations, len(sleepDurations))
	}
	for i, d := range sleepDurations {
		if d != interval {
			t.Errorf("sleep call %d: got %v, want %v", i, d, interval)
		}
	}
}
