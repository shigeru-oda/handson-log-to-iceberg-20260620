// Package iceberg provides the schema mapping from OTel log records
// to Iceberg table rows (S3 Tables and Glue targets).
//
// マッピング方針 (design.md / Req 5.5, 6.5):
//   - 主要フィールド (timestamp / severity / body) を独立した平坦カラムへフラット化する。
//   - ネスト構造 (resource / attributes) は JSON 文字列カラムへシリアライズする。
//   - 全カラム名は小文字に統一する (Req 5.4)。
//   - S3 Tables 用と Glue 用は同一論理スキーマ (同一カラム集合・型・小文字名・値) を返す。
package iceberg

import (
	"encoding/json"
	"time"

	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/otel"
)

// Target は Iceberg の書き込み先カタログ種別を表す。
// S3 Tables 用・Glue 用のいずれでも論理スキーマは同一である (Req 6.5)。
type Target int

const (
	// TargetS3Tables は Amazon S3 Tables のマネージド Iceberg テーブルを表す。
	TargetS3Tables Target = iota
	// TargetGlue は AWS Glue Data Catalog 管理のセルフマネージド Iceberg テーブルを表す。
	TargetGlue
)

// Iceberg テーブルのカラム名 (すべて小文字; Req 5.4)。
const (
	ColEventTime      = "event_time"
	ColSeverityNumber = "severity_number"
	ColSeverityText   = "severity_text"
	ColBody           = "body"
	ColResourceJSON   = "resource_json"
	ColAttributesJSON = "attributes_json"
	ColIngestDate     = "ingest_date"
)

// Column は Iceberg テーブルの 1 カラムの論理定義 (名前と型) を表す。
type Column struct {
	Name string // 小文字カラム名
	Type string // Iceberg 論理型 ("timestamp", "int", "string")
}

// Schema は指定ターゲット向けの Iceberg テーブルスキーマ (カラム定義の順序付きリスト) を返す。
// S3 Tables 用・Glue 用で同一の論理スキーマを返す (Req 6.5)。全カラム名は小文字 (Req 5.4)。
func Schema(target Target) []Column {
	// target に依らず同一スキーマを返す (両ターゲットの論理等価性を保証)。
	_ = target
	return []Column{
		{Name: ColEventTime, Type: "timestamp"},
		{Name: ColSeverityNumber, Type: "int"},
		{Name: ColSeverityText, Type: "string"},
		{Name: ColBody, Type: "string"},
		{Name: ColResourceJSON, Type: "string"},
		{Name: ColAttributesJSON, Type: "string"},
		{Name: ColIngestDate, Type: "string"},
	}
}

// MapRecord は 1 件の otel.LogRecord を Iceberg 行 (map[string]any) へマッピングする。
//
//   - event_time:       Timestamp を RFC3339Nano 文字列へ整形 (Iceberg timestamp 値)
//   - severity_number:  SeverityNumber を int として格納
//   - severity_text:    SeverityText をそのまま格納
//   - body:             Body をそのまま格納
//   - resource_json:    Resource を JSON 文字列へシリアライズ
//   - attributes_json:  Attributes を JSON 文字列へシリアライズ
//   - ingest_date:      Timestamp (UTC) の YYYY-MM-DD 文字列 (パーティション列)
//
// S3 Tables 用・Glue 用で論理的に等価な行を返す (Req 5.5, 6.5)。
func MapRecord(rec otel.LogRecord, target Target) (map[string]any, error) {
	// target に依らず同一の行を生成する (両ターゲットの論理等価性を保証)。
	_ = target

	resourceJSON, err := marshalJSON(rec.Resource)
	if err != nil {
		return nil, err
	}
	attributesJSON, err := marshalJSON(rec.Attributes)
	if err != nil {
		return nil, err
	}

	row := map[string]any{
		ColEventTime:      rec.Timestamp.UTC().Format(time.RFC3339Nano),
		ColSeverityNumber: int(rec.SeverityNumber),
		ColSeverityText:   rec.SeverityText,
		ColBody:           rec.Body,
		ColResourceJSON:   resourceJSON,
		ColAttributesJSON: attributesJSON,
		ColIngestDate:     rec.Timestamp.UTC().Format("2006-01-02"),
	}
	return row, nil
}

// marshalJSON はネスト属性マップを JSON 文字列へシリアライズする。
// nil マップは JSON の "null" として表現され、パース時に nil マップへ復元できる。
func marshalJSON(m map[string]any) (string, error) {
	b, err := json.Marshal(m)
	if err != nil {
		return "", err
	}
	return string(b), nil
}
