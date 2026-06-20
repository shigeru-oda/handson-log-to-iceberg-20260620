// Package otel defines the OTel Log Data Model record and generation logic.
package otel

import (
	"fmt"
	"math/rand"
	"time"
)

// SeverityNumber represents the OTel severity level (1..24).
type SeverityNumber int

const (
	SeverityTrace SeverityNumber = 1
	SeverityDebug SeverityNumber = 5
	SeverityInfo  SeverityNumber = 9
	SeverityWarn  SeverityNumber = 13
	SeverityError SeverityNumber = 17 // ERROR の下限
	SeverityFatal SeverityNumber = 21
)

// LogRecord represents an OpenTelemetry Log Data Model record.
type LogRecord struct {
	Timestamp      time.Time      `json:"timestamp"` // ナノ秒精度 (RFC3339Nano)
	SeverityNumber SeverityNumber `json:"severityNumber"`
	SeverityText   string         `json:"severityText"` // "ERROR", "FATAL" 等
	Body           string         `json:"body"`
	Resource       map[string]any `json:"resource"`   // ネスト属性
	Attributes     map[string]any `json:"attributes"` // ネスト属性
}

// IsError は severity が ERROR 以上 (>=17) か判定する (ルーティング判定の正典)
func (r LogRecord) IsError() bool { return r.SeverityNumber >= SeverityError }

// severityChoice は Generate が選択しうる severity の候補 (number と text の対) を表す。
type severityChoice struct {
	Number SeverityNumber
	Text   string
}

// severityChoices は生成対象となる複数の severity レベル。
// ERROR / FATAL を含む (Req 1.5)。
var severityChoices = []severityChoice{
	{SeverityTrace, "TRACE"},
	{SeverityDebug, "DEBUG"},
	{SeverityInfo, "INFO"},
	{SeverityWarn, "WARN"},
	{SeverityError, "ERROR"},
	{SeverityFatal, "FATAL"},
}

// bodyMessages は body フィールドに割り当てる候補文。
var bodyMessages = []string{
	"request handled successfully",
	"cache miss, falling back to origin",
	"user session refreshed",
	"db connection failed",
	"upstream service timeout",
	"unhandled exception in worker",
}

// serviceNames は resource の service.name に割り当てる候補。
var serviceNames = []string{
	"log-generator",
	"order-service",
	"auth-service",
	"payment-service",
}

// errorTypes は attributes の error.type に割り当てる候補。
var errorTypes = []string{
	"timeout",
	"connection_reset",
	"validation_error",
	"internal",
}

// Generate は乱数源から 1 件の妥当な LogRecord を生成する (決定的にテスト可能)。
//
// rng と now を注入することで、同一の入力に対し同一のレコードを返し、
// テスト時に決定的な検証を可能にする。生成されるレコードは OTel Log Data Model
// の必須フィールド (Timestamp, SeverityNumber, SeverityText, Body, Resource,
// Attributes) をすべて備え、SeverityNumber は OTel の範囲 (1..24) に収まる。
// ERROR / FATAL を含む複数の severity レベルを生成する (Req 1.2, 1.3, 1.5)。
func Generate(rng *rand.Rand, now time.Time) LogRecord {
	sev := severityChoices[rng.Intn(len(severityChoices))]
	body := bodyMessages[rng.Intn(len(bodyMessages))]
	service := serviceNames[rng.Intn(len(serviceNames))]

	// ホスト名はランダムな末尾オクテットで擬似的に生成する。
	hostName := fmt.Sprintf("ip-10-0-%d-%d", rng.Intn(256), rng.Intn(256))

	resource := map[string]any{
		"service.name": service,
		"host.name":    hostName,
	}

	attributes := map[string]any{
		"trace_id": fmt.Sprintf("%016x", rng.Uint64()),
		"retry":    rng.Intn(5),
	}
	// ERROR 以上のレコードには error.type を付与して文脈を充実させる。
	if sev.Number >= SeverityError {
		attributes["error.type"] = errorTypes[rng.Intn(len(errorTypes))]
	}

	return LogRecord{
		Timestamp:      now,
		SeverityNumber: sev.Number,
		SeverityText:   sev.Text,
		Body:           body,
		Resource:       resource,
		Attributes:     attributes,
	}
}
