package routing

import (
	"testing"

	"pgregory.net/rapid"
)

// containsS3 は配信先集合に DestS3 が含まれるか判定する。
func containsS3(dests []Destination) bool {
	for _, d := range dests {
		if d == DestS3 {
			return true
		}
	}
	return false
}

// TestProperty2_AllLogsRoutedToS3 は全ログが severity に依存せず S3 (full-logs)
// 経路へ振り分けられることを検証する。
//
// Feature: ecs-otel-log-pipeline, Property 2: 全ログの S3 ルーティング (severity 非依存)
// Validates: Requirements 4.2, 4.3
func TestProperty2_AllLogsRoutedToS3(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		// 任意の severityNumber 集合 (LogRecord 群を表す) を生成する。
		// OTel severityNumber は 1..24 が正規範囲だが、範囲外の値でも
		// S3 ルーティングは severity 非依存であるべきため広めの範囲を用いる。
		severities := rapid.SliceOfN(
			rapid.IntRange(-100, 100),
			0, 50,
		).Draw(t, "severities")

		// S3 経路へ振り分けられたレコードのインデックス集合を構築する。
		routedToS3 := make([]bool, len(severities))
		for i, sev := range severities {
			dests := Route(sev)
			if containsS3(dests) {
				routedToS3[i] = true
			}
		}

		// S3 経路集合は入力集合全体と一致しなければならない
		// (severity による絞り込みは行われない)。
		for i := range severities {
			if !routedToS3[i] {
				t.Fatalf("severityNumber=%d (index %d) was not routed to S3; "+
					"all logs must be routed to S3 regardless of severity",
					severities[i], i)
			}
		}
	})
}
