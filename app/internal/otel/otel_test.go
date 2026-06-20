package otel_test

import (
	"testing"

	"pgregory.net/rapid"
)

// TestPlaceholder verifies that the rapid PBT library is importable and functional.
func TestPlaceholder(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		_ = rapid.Int().Draw(t, "n")
	})
}
