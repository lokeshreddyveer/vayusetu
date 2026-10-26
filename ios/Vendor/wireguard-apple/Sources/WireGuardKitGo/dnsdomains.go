/* VayuSetu addition (see ios/Vendor/PATCHES.md). SPDX-License-Identifier: MIT */

package main

// #include <stdlib.h>
import "C"

import (
	"encoding/json"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
)

// Per-domain counts for the optional domain history. It is off until the app switches it on, and while it is off the only cost on the
// lookup path is one atomic load. When it is on, the tunnel keeps counts only (name, allowed, blocked) in memory, never a list of
// lookups with times. The app collects them with take(), which empties the tally, so the tunnel never holds more than a few seconds of it.
const (
	tallyMaxNames = 4000 // distinct names held at once; further new names are counted under "other"
	tallyMaxTake  = 600  // names returned per take, most active first
)

type domainCount struct {
	Name    string `json:"n"`
	Allowed uint32 `json:"a"`
	Blocked uint32 `json:"b"`
}

type domainTally struct {
	on     atomic.Bool
	mu     sync.Mutex
	counts map[string]*[2]uint32 // [allowed, blocked]
	other  [2]uint32
}

var tally = &domainTally{counts: map[string]*[2]uint32{}}

func (t *domainTally) enable(on bool) {
	t.on.Store(on)
	if !on {
		t.mu.Lock()
		t.counts = map[string]*[2]uint32{}
		t.other = [2]uint32{}
		t.mu.Unlock()
	}
}

// record counts one decided lookup. name is lowercase without a trailing dot.
func (t *domainTally) record(name string, blocked bool) {
	if !t.on.Load() || name == "" {
		return
	}
	i := 0
	if blocked {
		i = 1
	}
	t.mu.Lock()
	if c, ok := t.counts[name]; ok {
		c[i]++
	} else if len(t.counts) < tallyMaxNames {
		c := &[2]uint32{}
		c[i] = 1
		t.counts[name] = c
	} else {
		t.other[i]++
	}
	t.mu.Unlock()
}

// take returns the counts since the last take, most active first, and empties the tally.
func (t *domainTally) take() []domainCount {
	t.mu.Lock()
	counts, other := t.counts, t.other
	t.counts = map[string]*[2]uint32{}
	t.other = [2]uint32{}
	t.mu.Unlock()
	out := make([]domainCount, 0, len(counts)+1)
	for name, c := range counts {
		out = append(out, domainCount{Name: name, Allowed: c[0], Blocked: c[1]})
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i].Allowed+out[i].Blocked, out[j].Allowed+out[j].Blocked
		if a != b {
			return a > b
		}
		return strings.Compare(out[i].Name, out[j].Name) < 0
	})
	if len(out) > tallyMaxTake {
		for _, c := range out[tallyMaxTake:] {
			other[0] += c.Allowed
			other[1] += c.Blocked
		}
		out = out[:tallyMaxTake]
	}
	if other[0] > 0 || other[1] > 0 {
		out = append(out, domainCount{Name: "", Allowed: other[0], Blocked: other[1]})
	}
	return out
}

// wgDNSDomainsEnable switches the per-domain tally on or off. Switching it off discards what was counted.
//
//export wgDNSDomainsEnable
func wgDNSDomainsEnable(on int32) {
	tally.enable(on != 0)
}

// wgDNSDomainsTake returns the counts since the last call as JSON ([{"n":name,"a":allowed,"b":blocked}], the entry with an empty
// name being everything not listed) and empties the tally. Free with free().
//
//export wgDNSDomainsTake
func wgDNSDomainsTake() *C.char {
	data, err := json.Marshal(tally.take())
	if err != nil {
		return nil
	}
	return C.CString(string(data))
}
