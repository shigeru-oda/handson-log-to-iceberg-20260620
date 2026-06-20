// Package routing provides severity-based log routing decisions
// equivalent to the Fluent Bit rewrite_tag configuration.
package routing

// ErrorSeverityThreshold は ERROR 以上とみなす severityNumber の下限である。
// OTel Log Data Model では severityNumber>=17 が ERROR 以上 (ERROR/FATAL) を表す。
const ErrorSeverityThreshold = 17

// Destination はログレコードの配信先を表す。
type Destination int

const (
	// DestS3 は全ログを格納する S3 (full-logs) 配信先。
	DestS3 Destination = iota
	// DestCloudWatch は Error_Log を配信する CloudWatch Logs 配信先。
	DestCloudWatch
	// DestS3TablesIceberg は Error_Log を書き込む S3 Tables マネージド Iceberg 配信先。
	DestS3TablesIceberg
	// DestGlueIceberg は Error_Log を書き込む Glue Data Catalog Iceberg 配信先。
	DestGlueIceberg
)

// String は Destination の人間可読な名称を返す。
func (d Destination) String() string {
	switch d {
	case DestS3:
		return "S3"
	case DestCloudWatch:
		return "CloudWatch"
	case DestS3TablesIceberg:
		return "S3TablesIceberg"
	case DestGlueIceberg:
		return "GlueIceberg"
	default:
		return "Unknown"
	}
}

// IsError は severityNumber が ERROR 以上 (>=17) か判定する正典ロジックである。
// Fluent Bit 設定の severity 閾値判定と同等。
func IsError(severityNumber int) bool {
	return severityNumber >= ErrorSeverityThreshold
}

// Route は与えられた severityNumber に対する配信先集合を返す。
// これは Fluent Bit (FireLens) のルーティング設定と同等のリファレンス実装である。
//
//   - すべてのレコード      → DestS3 (severity 非依存)
//   - ERROR 以上 (>=17)     → DestCloudWatch / DestS3TablesIceberg / DestGlueIceberg を追加
//
// 返り値の順序は決定的 (S3, CloudWatch, S3TablesIceberg, GlueIceberg)。
func Route(severityNumber int) []Destination {
	// 全ログは severity に関わらず S3 (full-logs) へ配信される。
	dests := []Destination{DestS3}
	if IsError(severityNumber) {
		dests = append(dests, DestCloudWatch, DestS3TablesIceberg, DestGlueIceberg)
	}
	return dests
}
