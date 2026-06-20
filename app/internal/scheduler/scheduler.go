// Package scheduler controls the log output interval timing.
package scheduler

import "time"

// Scheduler computes successive log output times based on a fixed interval.
// It holds no internal clock state, so its behavior is purely a function of
// its inputs, making it deterministic and easy to test via time injection.
type Scheduler struct {
	Interval time.Duration // 出力間隔 (Req 2.2, 2.3)
}

// Next returns the next scheduled time after prev, computed as prev + Interval.
func (s Scheduler) Next(prev time.Time) time.Time {
	return prev.Add(s.Interval)
}
