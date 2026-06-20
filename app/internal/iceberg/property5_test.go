package iceberg_test

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/iceberg"
	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/otel"
	"pgregory.net/rapid"
)

// genJSONValue draws an arbitrary JSON-serializable scalar value
// (string / int / float / bool) used to populate nested resource and
// attribute maps.
func genJSONValue(t *rapid.T, label string) any {
	kind := rapid.IntRange(0, 3).Draw(t, label+"_kind")
	switch kind {
	case 0:
		return rapid.String().Draw(t, label+"_str")
	case 1:
		return rapid.IntRange(-1000000, 1000000).Draw(t, label+"_int")
	case 2:
		return rapid.Float64Range(-1e6, 1e6).Draw(t, label+"_float")
	default:
		return rapid.Bool().Draw(t, label+"_bool")
	}
}

// genStringAnyMap draws an arbitrary map[string]any with unique string keys
// and JSON-serializable scalar values. A nil map is occasionally produced to
// exercise the JSON "null" path in the mapping.
func genStringAnyMap(t *rapid.T, label string) map[string]any {
	if rapid.Bool().Draw(t, label+"_nil") {
		return nil
	}
	keys := rapid.SliceOfNDistinct(
		rapid.StringN(1, 16, 16),
		0, 8,
		func(s string) string { return s },
	).Draw(t, label+"_keys")

	m := make(map[string]any, len(keys))
	for i, k := range keys {
		m[k] = genJSONValue(t, label+"_v"+string(rune('a'+i)))
	}
	return m
}

// genLogRecord draws an arbitrary otel.LogRecord with arbitrary nested
// resource/attributes maps and arbitrary primary fields.
func genLogRecord(t *rapid.T) otel.LogRecord {
	sec := rapid.Int64Range(0, 4102444800).Draw(t, "unixSec")
	nsec := rapid.Int64Range(0, 999999999).Draw(t, "unixNsec")
	return otel.LogRecord{
		Timestamp:      time.Unix(sec, nsec).UTC(),
		SeverityNumber: otel.SeverityNumber(rapid.IntRange(1, 24).Draw(t, "severityNumber")),
		SeverityText:   rapid.String().Draw(t, "severityText"),
		Body:           rapid.String().Draw(t, "body"),
		Resource:       genStringAnyMap(t, "resource"),
		Attributes:     genStringAnyMap(t, "attributes"),
	}
}

// jsonNormalize marshals an arbitrary value to JSON and unmarshals it back
// into a generic any. This yields the canonical JSON shape (e.g. all numbers
// become float64), making structural comparison via reflect.DeepEqual robust
// against int-vs-float64 representation differences.
func jsonNormalize(t *testing.T, v any) any {
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal for normalization failed: %v", err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal for normalization failed: %v", err)
	}
	return out
}

// TestProperty5_SchemaMappingNestPreservingRoundTripAndTargetEquivalence
// verifies that, for any LogRecord, the Iceberg schema mapping (MapRecord):
//
//	(a) flattens the primary fields (event_time, severity_number,
//	    severity_text, body) into independent flat columns,
//	(b) serializes resource and attributes into JSON string columns
//	    (resource_json, attributes_json) such that parsing the JSON back
//	    reconstructs a structure equivalent to the original nested maps, and
//	(c) the S3 Tables mapping result and the Glue mapping result are logically
//	    equivalent (same column set, same types, same lowercase names, same
//	    values).
//
// Feature: ecs-otel-log-pipeline, Property 5: スキーママッピングのネスト保持ラウンドトリップと両ターゲット等価性
// Validates: Requirements 5.5, 6.5
func TestProperty5_SchemaMappingNestPreservingRoundTripAndTargetEquivalence(t *testing.T) {
	rapid.Check(t, func(rt *rapid.T) {
		rec := genLogRecord(rt)

		s3Row, err := iceberg.MapRecord(rec, iceberg.TargetS3Tables)
		if err != nil {
			t.Fatalf("MapRecord(S3Tables) failed: %v", err)
		}
		glueRow, err := iceberg.MapRecord(rec, iceberg.TargetGlue)
		if err != nil {
			t.Fatalf("MapRecord(Glue) failed: %v", err)
		}

		// (a) Primary fields are flattened into independent flat columns
		// carrying the original scalar values.
		if got := s3Row[iceberg.ColEventTime]; got != rec.Timestamp.UTC().Format(time.RFC3339Nano) {
			t.Fatalf("event_time mismatch: got %v want %v", got, rec.Timestamp.UTC().Format(time.RFC3339Nano))
		}
		if got := s3Row[iceberg.ColSeverityNumber]; got != int(rec.SeverityNumber) {
			t.Fatalf("severity_number mismatch: got %v want %v", got, int(rec.SeverityNumber))
		}
		if got := s3Row[iceberg.ColSeverityText]; got != rec.SeverityText {
			t.Fatalf("severity_text mismatch: got %v want %v", got, rec.SeverityText)
		}
		if got := s3Row[iceberg.ColBody]; got != rec.Body {
			t.Fatalf("body mismatch: got %v want %v", got, rec.Body)
		}
		// The nested maps must NOT leak into the primary flat columns as
		// nested values; they live only in the JSON string columns.
		for _, col := range []string{iceberg.ColResourceJSON, iceberg.ColAttributesJSON} {
			if _, ok := s3Row[col].(string); !ok {
				t.Fatalf("column %q must be a JSON string, got %T", col, s3Row[col])
			}
		}

		// (b) Round trip: parsing the JSON string columns must reconstruct a
		// structure equivalent to the original nested maps. Compare against the
		// JSON-normalized originals to avoid int-vs-float64 representation
		// mismatches.
		resStr, ok := s3Row[iceberg.ColResourceJSON].(string)
		if !ok {
			t.Fatalf("resource_json is not a string: %T", s3Row[iceberg.ColResourceJSON])
		}
		var resParsed any
		if err := json.Unmarshal([]byte(resStr), &resParsed); err != nil {
			t.Fatalf("resource_json is not valid JSON: %v (%q)", err, resStr)
		}
		if !reflect.DeepEqual(resParsed, jsonNormalize(t, rec.Resource)) {
			t.Fatalf("resource round trip not equivalent:\n parsed=%#v\n want=%#v", resParsed, jsonNormalize(t, rec.Resource))
		}

		attrStr, ok := s3Row[iceberg.ColAttributesJSON].(string)
		if !ok {
			t.Fatalf("attributes_json is not a string: %T", s3Row[iceberg.ColAttributesJSON])
		}
		var attrParsed any
		if err := json.Unmarshal([]byte(attrStr), &attrParsed); err != nil {
			t.Fatalf("attributes_json is not valid JSON: %v (%q)", err, attrStr)
		}
		if !reflect.DeepEqual(attrParsed, jsonNormalize(t, rec.Attributes)) {
			t.Fatalf("attributes round trip not equivalent:\n parsed=%#v\n want=%#v", attrParsed, jsonNormalize(t, rec.Attributes))
		}

		// (c) The S3 Tables result and the Glue result must be logically
		// equivalent: identical column sets, types, lowercase names, and values.
		if !reflect.DeepEqual(s3Row, glueRow) {
			t.Fatalf("S3 Tables and Glue rows differ:\n s3=%#v\n glue=%#v", s3Row, glueRow)
		}

		s3Schema := iceberg.Schema(iceberg.TargetS3Tables)
		glueSchema := iceberg.Schema(iceberg.TargetGlue)
		if !reflect.DeepEqual(s3Schema, glueSchema) {
			t.Fatalf("S3 Tables and Glue schemas differ:\n s3=%#v\n glue=%#v", s3Schema, glueSchema)
		}

		// Column names must be lowercase and the row's key set must match the
		// schema's column set exactly (same column set, both targets).
		for _, col := range s3Schema {
			if col.Name != lower(col.Name) {
				t.Fatalf("column name %q is not lowercase", col.Name)
			}
			if _, ok := s3Row[col.Name]; !ok {
				t.Fatalf("row is missing schema column %q", col.Name)
			}
		}
		if len(s3Row) != len(s3Schema) {
			t.Fatalf("row column count %d does not match schema column count %d", len(s3Row), len(s3Schema))
		}
	})
}

// lower returns the ASCII-lowercased form of s, used to assert column names
// are lowercase without pulling in extra dependencies.
func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	return string(b)
}
