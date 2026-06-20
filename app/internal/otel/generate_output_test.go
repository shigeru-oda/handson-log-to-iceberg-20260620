package otel_test

import (
	"bytes"
	"encoding/json"
	"math/rand"
	"strings"
	"testing"
	"time"

	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/otel"
)

// TestGenerateMarshalsToSingleJSONLine verifies that a generated LogRecord can be
// serialized as a single-line JSON Lines record (no embedded newline) (Req 1.4).
func TestGenerateMarshalsToSingleJSONLine(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	now := time.Date(2026, 6, 20, 12, 34, 56, 789012345, time.UTC)

	rec := otel.Generate(rng, now)

	data, err := json.Marshal(rec)
	if err != nil {
		t.Fatalf("json.Marshal returned error: %v", err)
	}

	if bytes.ContainsRune(data, '\n') {
		t.Errorf("marshaled record contains an embedded newline; want a single line: %q", data)
	}
	if strings.Count(string(data), "\n") != 0 {
		t.Errorf("marshaled record must be a single line, got %d newlines", strings.Count(string(data), "\n"))
	}
}

// TestGenerateWritableToInjectedWriter verifies that a generated LogRecord can be
// written as a JSON Lines entry into an injected io.Writer (bytes.Buffer) (Req 1.4).
func TestGenerateWritableToInjectedWriter(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	now := time.Date(2026, 6, 20, 0, 0, 0, 0, time.UTC)

	rec := otel.Generate(rng, now)

	data, err := json.Marshal(rec)
	if err != nil {
		t.Fatalf("json.Marshal returned error: %v", err)
	}

	// Write the record followed by a single newline (JSON Lines convention)
	// into an injected writer.
	var buf bytes.Buffer
	if _, err := buf.Write(data); err != nil {
		t.Fatalf("buf.Write returned error: %v", err)
	}
	if _, err := buf.WriteString("\n"); err != nil {
		t.Fatalf("buf.WriteString returned error: %v", err)
	}

	out := buf.String()

	if !strings.HasSuffix(out, "\n") {
		t.Errorf("buffer contents must end with a newline, got %q", out)
	}

	// Exactly one line of content plus the trailing newline.
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != 1 {
		t.Errorf("expected exactly 1 JSON line in buffer, got %d: %q", len(lines), out)
	}

	// The buffered line must round-trip back into an equivalent record.
	var decoded otel.LogRecord
	if err := json.Unmarshal([]byte(lines[0]), &decoded); err != nil {
		t.Fatalf("json.Unmarshal of buffered line returned error: %v", err)
	}
	if decoded.SeverityNumber != rec.SeverityNumber {
		t.Errorf("severityNumber mismatch after round-trip: got %d, want %d", decoded.SeverityNumber, rec.SeverityNumber)
	}
	if decoded.SeverityText != rec.SeverityText {
		t.Errorf("severityText mismatch after round-trip: got %q, want %q", decoded.SeverityText, rec.SeverityText)
	}
	if decoded.Body != rec.Body {
		t.Errorf("body mismatch after round-trip: got %q, want %q", decoded.Body, rec.Body)
	}
}
