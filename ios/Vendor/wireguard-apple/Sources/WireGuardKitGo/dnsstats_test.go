package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

type timeoutErr struct{}

func (timeoutErr) Error() string   { return "i/o timeout" }
func (timeoutErr) Timeout() bool   { return true }
func (timeoutErr) Temporary() bool { return true }

func TestOutcomesAreCountedApartAndOnlyAnsweredLookupsAreTimed(t *testing.T) {
	s := newResolverStats()
	s.ok(10 * time.Millisecond)  // bucket 0 (<=25)
	s.ok(120 * time.Millisecond) // bucket 3 (<=200)
	s.ok(5 * time.Second)        // above the last limit
	s.fail(context.DeadlineExceeded)
	s.fail(timeoutErr{})
	s.fail(errors.New("connection reset"))
	s.cacheHit()
	s.cacheHit()
	snap := s.snapshot()
	if snap.Answered != 3 || snap.Timeouts != 2 || snap.Errors != 1 || snap.CacheHits != 2 {
		t.Fatalf("unexpected counts: %+v", snap)
	}
	var timed uint64
	for _, c := range snap.RTT {
		timed += c
	}
	if timed != 3 || snap.RTT[0] != 1 || snap.RTT[3] != 1 || snap.RTT[7] != 1 {
		t.Fatalf("only the three answered lookups are timed, and a cache hit or failure never is: %v", snap.RTT)
	}
}

func TestEachTunnelRunHasItsOwnGenerationAndWindow(t *testing.T) {
	a, b := newResolverStats(), newResolverStats()
	if b.snapshot().Generation <= a.snapshot().Generation || a.snapshot().WindowStart == 0 {
		t.Fatalf("a new run must carry a newer generation: %d then %d", a.snapshot().Generation, b.snapshot().Generation)
	}
	if b.snapshot().Answered != 0 {
		t.Fatal("a new run starts from zero")
	}
}

func TestANilStatsValueIsHarmless(t *testing.T) {
	var s *resolverStats
	s.ok(time.Millisecond)
	s.fail(errors.New("x"))
	s.cacheHit()
	if len(s.snapshot().RTT) != 8 {
		t.Fatal("a nil value still yields a well-formed snapshot")
	}
}
