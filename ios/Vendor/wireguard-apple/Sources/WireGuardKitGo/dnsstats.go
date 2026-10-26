/* VayuSetu addition (see ios/Vendor/PATCHES.md). SPDX-License-Identifier: MIT
 *
 * Resolver health. What the encrypted resolver actually did, counted by outcome and timed only when the lookup really went to the resolver:
 * answered (with its round trip), timed out, or failed some other way. Answers served from the cache and names blocked on the device never
 * reach the resolver, so they are counted apart and never enter the timing. The figures are bounded (a few counters and eight buckets, no
 * per-query record) and carry a generation that changes each time a tunnel starts, so numbers from an earlier run cannot be mistaken for this one.
 */

package main

import (
	"context"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

var rttLimitsMs = []float64{25, 50, 100, 200, 400, 800, 1600} // one more bucket above the last

var statsGeneration atomic.Uint64

type resolverStats struct {
	mu                                  sync.Mutex
	answered, timeouts, errs, cacheHits uint64
	buckets                             [8]uint64
	generation                          uint64
	windowStart                         time.Time
}

type resolverSnapshot struct {
	Answered    uint64   `json:"answered"`
	Timeouts    uint64   `json:"timeouts"`
	Errors      uint64   `json:"errors"`
	CacheHits   uint64   `json:"cacheHits"`
	RTT         []uint64 `json:"rtt"`
	Generation  uint64   `json:"generation"`
	WindowStart int64    `json:"windowStart"`
}

func newResolverStats() *resolverStats {
	return &resolverStats{generation: statsGeneration.Add(1), windowStart: time.Now()}
}

func (s *resolverStats) cacheHit() {
	if s == nil {
		return
	}
	s.mu.Lock()
	s.cacheHits++
	s.mu.Unlock()
}

func (s *resolverStats) ok(d time.Duration) {
	if s == nil {
		return
	}
	ms := float64(d) / float64(time.Millisecond)
	i := len(rttLimitsMs)
	for n, limit := range rttLimitsMs {
		if ms <= limit {
			i = n
			break
		}
	}
	s.mu.Lock()
	s.answered++
	s.buckets[i]++
	s.mu.Unlock()
}

// isTimeout reports a deadline or a network timeout, as opposed to a refusal, a reset or a malformed reply.
func isTimeout(err error) bool {
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

func (s *resolverStats) fail(err error) {
	if s == nil {
		return
	}
	s.mu.Lock()
	if isTimeout(err) {
		s.timeouts++
	} else {
		s.errs++
	}
	s.mu.Unlock()
}

func (s *resolverStats) snapshot() resolverSnapshot {
	if s == nil {
		return resolverSnapshot{RTT: make([]uint64, 8)}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rtt := make([]uint64, len(s.buckets))
	copy(rtt, s.buckets[:])
	return resolverSnapshot{Answered: s.answered, Timeouts: s.timeouts, Errors: s.errs, CacheHits: s.cacheHits, RTT: rtt, Generation: s.generation, WindowStart: s.windowStart.Unix()}
}
