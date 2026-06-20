package routing

import (
	"testing"

	"pgregory.net/rapid"
)

// Feature: ecs-otel-log-pipeline, Property 3: Error_Log のルーティング正当性
//
// 任意の LogRecord 集合 (ここでは severityNumber 集合で表現) について、
// CloudWatch Logs 経路・S3 Tables Iceberg 経路・Glue Iceberg 経路のそれぞれへ
// 振り分けられるレコード集合は、severityNumber >= 17 (ERROR 以上) を満たす
// レコードの集合と正確に一致する。すなわち非エラーログはこれら 3 経路に一切入らず、
// エラーログは必ず 3 経路すべてに入る。
//
// Validates: Requirements 3.3, 3.5, 4.1, 5.2, 6.3
func TestProperty3ErrorLogRoutingCorrectness(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		// 任意の severityNumber 集合を生成する。
		// OTel severityNumber は 1..24 が正典だが、境界外の値も含めて
		// 閾値ロジックの正当性を広く検証するため範囲を広げる。
		severities := rapid.SliceOfN(
			rapid.IntRange(-5, 30),
			0, 50,
		).Draw(t, "severities")

		// 各 severity を Route に通し、配信先ごとにルーティングされた
		// インデックス集合を収集する。
		routedTo := map[Destination]map[int]bool{
			DestCloudWatch:      {},
			DestS3TablesIceberg: {},
			DestGlueIceberg:     {},
		}

		// 期待されるエラーレコードのインデックス集合 (severityNumber >= 17)。
		expectedErrors := map[int]bool{}

		for i, sev := range severities {
			if sev >= ErrorSeverityThreshold {
				expectedErrors[i] = true
			}

			for _, dest := range Route(sev) {
				if set, ok := routedTo[dest]; ok {
					set[i] = true
				}
			}
		}

		// エラー判定の 3 経路集合が、期待されるエラー集合と正確に一致することを検証する。
		errorDests := []Destination{DestCloudWatch, DestS3TablesIceberg, DestGlueIceberg}
		for _, dest := range errorDests {
			got := routedTo[dest]

			if len(got) != len(expectedErrors) {
				t.Fatalf("dest %v: routed set size %d != expected error set size %d (severities=%v)",
					dest, len(got), len(expectedErrors), severities)
			}

			for idx := range expectedErrors {
				if !got[idx] {
					t.Fatalf("dest %v: error log idx %d (severity=%d) missing from route (severities=%v)",
						dest, idx, severities[idx], severities)
				}
			}

			for idx := range got {
				if !expectedErrors[idx] {
					t.Fatalf("dest %v: non-error log idx %d (severity=%d) incorrectly routed (severities=%v)",
						dest, idx, severities[idx], severities)
				}
			}
		}
	})
}
