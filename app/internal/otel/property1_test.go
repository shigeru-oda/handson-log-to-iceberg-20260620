package otel_test

import (
	"bytes"
	"encoding/json"
	"math/rand"
	"testing"
	"time"

	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/otel"
	"pgregory.net/rapid"
)

// TestProperty1SchemaValidityAndJSONRoundTrip verifies that for any random
// source and time, Generate produces a LogRecord that (a) populates all
// required OTel fields, (b) has a severityNumber within 1..24, and (c) is
// equivalent to itself after a JSON serialize/deserialize round trip.
//
// Feature: ecs-otel-log-pipeline, Property 1: OTel レコードのスキーマ妥当性と JSON ラウンドトリップ
// Validates: Requirements 1.2, 1.3
func TestProperty1SchemaValidityAndJSONRoundTrip(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		// Random source: a deterministic *rand.Rand from a drawn seed.
		seed := rapid.Int64().Draw(t, "seed")
		rng := rand.New(rand.NewSource(seed))

		// Random time: build from drawn unix seconds + nanoseconds so the
		// timestamp carries nanosecond precision (RFC3339Nano).
		sec := rapid.Int64Range(0, 4102444800).Draw(t, "unixSec") // up to year ~2100
		nsec := rapid.Int64Range(0, 999999999).Draw(t, "unixNsec")
		now := time.Unix(sec, nsec).UTC()

		rec := otel.Generate(rng, now)

		// (a) All required fields must be populated.
		if rec.Timestamp.IsZero() {
			t.Fatalf("Timestamp is zero, expected populated value")
		}
		if rec.SeverityText == "" {
			t.Fatalf("SeverityText is empty, expected populated value")
		}
		if rec.Body == "" {
			t.Fatalf("Body is empty, expected populated value")
		}
		if rec.Resource == nil {
			t.Fatalf("Resource is nil, expected non-nil map")
		}
		if rec.Attributes == nil {
			t.Fatalf("Attributes is nil, expected non-nil map")
		}

		// (b) severityNumber must be within the OTel range 1..24.
		if rec.SeverityNumber < 1 || rec.SeverityNumber > 24 {
			t.Fatalf("SeverityNumber %d out of range 1..24", rec.SeverityNumber)
		}

		// (c) JSON serialize then deserialize must be equivalent to the
		// original record. Generate populates map[string]any with integer
		// values that JSON decodes back as float64, so a direct DeepEqual
		// would spuriously fail. Instead we assert the serialized form is
		// stable across the round trip: marshal(rec) must equal
		// marshal(unmarshal(marshal(rec))). This proves no information is
		// lost or altered by the round trip.
		first, err := json.Marshal(rec)
		if err != nil {
			t.Fatalf("first marshal failed: %v", err)
		}

		var decoded otel.LogRecord
		if err := json.Unmarshal(first, &decoded); err != nil {
			t.Fatalf("unmarshal failed: %v", err)
		}

		// Required fields must survive the round trip as well.
		if decoded.Resource == nil {
			t.Fatalf("decoded Resource is nil after round trip")
		}
		if decoded.Attributes == nil {
			t.Fatalf("decoded Attributes is nil after round trip")
		}

		second, err := json.Marshal(decoded)
		if err != nil {
			t.Fatalf("second marshal failed: %v", err)
		}

		if !bytes.Equal(first, second) {
			t.Fatalf("JSON round trip not equivalent:\n first=%s\nsecond=%s", first, second)
		}

		// Scalar fields must be preserved exactly across the round trip.
		if !decoded.Timestamp.Equal(rec.Timestamp) {
			t.Fatalf("Timestamp mismatch after round trip: got %v want %v", decoded.Timestamp, rec.Timestamp)
		}
		if decoded.SeverityNumber != rec.SeverityNumber {
			t.Fatalf("SeverityNumber mismatch: got %d want %d", decoded.SeverityNumber, rec.SeverityNumber)
		}
		if decoded.SeverityText != rec.SeverityText {
			t.Fatalf("SeverityText mismatch: got %q want %q", decoded.SeverityText, rec.SeverityText)
		}
		if decoded.Body != rec.Body {
			t.Fatalf("Body mismatch: got %q want %q", decoded.Body, rec.Body)
		}
	})
}
