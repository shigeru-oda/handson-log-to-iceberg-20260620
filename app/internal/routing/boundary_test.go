package routing

import (
	"reflect"
	"testing"
)

// TestRouteSeverityBoundary は severity 閾値 (17) の境界における
// Route と IsError の挙動を検証する。
//
// Validates: Requirements 3.3, 3.5
func TestRouteSeverityBoundary(t *testing.T) {
	tests := []struct {
		name           string
		severityNumber int
		wantDests      []Destination
		wantIsError    bool
	}{
		{
			name:           "severity 16 (閾値未満) は S3 のみ・非エラー",
			severityNumber: 16,
			wantDests:      []Destination{DestS3},
			wantIsError:    false,
		},
		{
			name:           "severity 17 (閾値) は全配信先・エラー",
			severityNumber: 17,
			wantDests:      []Destination{DestS3, DestCloudWatch, DestS3TablesIceberg, DestGlueIceberg},
			wantIsError:    true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotDests := Route(tt.severityNumber)
			if !reflect.DeepEqual(gotDests, tt.wantDests) {
				t.Errorf("Route(%d) = %v, want %v", tt.severityNumber, gotDests, tt.wantDests)
			}

			gotIsError := IsError(tt.severityNumber)
			if gotIsError != tt.wantIsError {
				t.Errorf("IsError(%d) = %v, want %v", tt.severityNumber, gotIsError, tt.wantIsError)
			}
		})
	}
}
