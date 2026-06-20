package iceberg_test

import (
	"math/rand"
	"strings"
	"testing"
	"time"

	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/iceberg"
	"github.com/shigeruoda/handson-log-to-iceberg-20260620/app/internal/otel"
	"pgregory.net/rapid"
)

// TestProperty4LowercaseColumnInvariant verifies that for any set of OTel field
// names, every column name produced by the Iceberg schema mapping is lowercase
// (for each column name c, strings.ToLower(c) == c). The invariant must hold for
// BOTH the S3 Tables target and the Glue target: the column names returned by
// Schema(target) as well as the map keys returned by MapRecord(rec, target).
//
// Feature: ecs-otel-log-pipeline, Property 4: Iceberg スキーマの小文字カラム不変条件
// Validates: Requirements 5.4
func TestProperty4LowercaseColumnInvariant(t *testing.T) {
	targets := []iceberg.Target{iceberg.TargetS3Tables, iceberg.TargetGlue}

	assertLower := func(t *rapid.T, name string) {
		if strings.ToLower(name) != name {
			t.Fatalf("column name %q is not lowercase", name)
		}
	}

	rapid.Check(t, func(t *rapid.T) {
		// Deterministic random source from a drawn seed, used by Generate.
		seed := rapid.Int64().Draw(t, "seed")
		rng := rand.New(rand.NewSource(seed))

		sec := rapid.Int64Range(0, 4102444800).Draw(t, "unixSec")
		nsec := rapid.Int64Range(0, 999999999).Draw(t, "unixNsec")
		now := time.Unix(sec, nsec).UTC()

		rec := otel.Generate(rng, now)

		// Inject arbitrary (including mixed-case / uppercase) OTel field names
		// into resource and attributes. These keys live INSIDE the JSON string
		// columns and must NOT leak into the Iceberg column names regardless of
		// their casing.
		keyGen := rapid.StringMatching(`[A-Za-z][A-Za-z0-9._]{0,15}`)
		nKeys := rapid.IntRange(0, 6).Draw(t, "nKeys")
		rec.Resource = map[string]any{}
		rec.Attributes = map[string]any{}
		for i := 0; i < nKeys; i++ {
			rk := keyGen.Draw(t, "resourceKey")
			ak := keyGen.Draw(t, "attrKey")
			rec.Resource[rk] = rapid.String().Draw(t, "resourceVal")
			rec.Attributes[ak] = rapid.Int().Draw(t, "attrVal")
		}

		for _, target := range targets {
			// Schema column names must all be lowercase.
			cols := iceberg.Schema(target)
			if len(cols) == 0 {
				t.Fatalf("Schema(%v) returned no columns", target)
			}
			for _, c := range cols {
				assertLower(t, c.Name)
			}

			// MapRecord keys (the actual column names of an emitted row) must
			// all be lowercase, even with arbitrary-cased OTel field names.
			row, err := iceberg.MapRecord(rec, target)
			if err != nil {
				t.Fatalf("MapRecord(%v) failed: %v", target, err)
			}
			for k := range row {
				assertLower(t, k)
			}
		}
	})
}
