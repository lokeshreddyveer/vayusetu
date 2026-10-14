/* VayuSetu addition (see ios/Vendor/PATCHES.md). SPDX-License-Identifier: MIT
 *
 * A small answer cache in front of the encrypted resolver. Repeated lookups (every page load asks for the same names
 * many times) are answered from memory instead of a network round trip. Only complete NOERROR/NXDOMAIN answers are kept,
 * for no longer than their own TTL and never longer than cacheMaxTTL. Blocked names never reach it (they are answered earlier).
 */

package main

import (
	"encoding/binary"
	"sync"
	"time"
)

const (
	cacheMaxEntries = 2048
	cacheMaxTTL     = 120 // seconds; a cached answer is never served older than this
)

type cacheEntry struct {
	reply   []byte
	expires time.Time
}

type dnsCache struct {
	mu  sync.Mutex
	m   map[string]cacheEntry
	now func() time.Time
}

func newDNSCache() *dnsCache {
	return &dnsCache{m: make(map[string]cacheEntry), now: time.Now}
}

// cacheKey identifies a query by everything that can change its answer: the RD and CD flags and every byte after the
// header's ID and flags (counts, question, and any EDNS options such as the DNSSEC-OK bit).
func cacheKey(q []byte) (string, bool) {
	if len(q) < 17 || q[2]&0x80 != 0 || q[2]&0x78 != 0 { // a response, or not a standard query
		return "", false
	}
	return string([]byte{q[2] & 0x01, q[3] & 0x10}) + string(q[4:]), true
}

// skipName returns the offset just after a (possibly compressed) name that starts at off.
func skipName(m []byte, off int) (int, bool) {
	for {
		if off >= len(m) {
			return 0, false
		}
		n := int(m[off])
		switch {
		case n == 0:
			return off + 1, true
		case n&0xC0 == 0xC0:
			if off+2 > len(m) {
				return 0, false
			}
			return off + 2, true
		case n&0xC0 != 0:
			return 0, false
		default:
			off += 1 + n
		}
	}
}

// answerTTL is the smallest TTL among the answer and authority records, and whether the reply is cacheable at all.
func answerTTL(reply []byte) (uint32, bool) {
	if len(reply) < 12 || reply[2]&0x80 == 0 || reply[2]&0x02 != 0 { // not a response, or truncated
		return 0, false
	}
	if rcode := reply[3] & 0x0f; rcode != 0 && rcode != 3 {
		return 0, false
	}
	qd := int(binary.BigEndian.Uint16(reply[4:]))
	records := int(binary.BigEndian.Uint16(reply[6:])) + int(binary.BigEndian.Uint16(reply[8:]))
	off := 12
	for i := 0; i < qd; i++ {
		next, ok := skipName(reply, off)
		if !ok || next+4 > len(reply) {
			return 0, false
		}
		off = next + 4
	}
	if records == 0 {
		return 0, false
	}
	min := uint32(0xFFFFFFFF)
	for i := 0; i < records; i++ {
		next, ok := skipName(reply, off)
		if !ok || next+10 > len(reply) {
			return 0, false
		}
		ttl := binary.BigEndian.Uint32(reply[next+4:])
		rdlen := int(binary.BigEndian.Uint16(reply[next+8:]))
		if next+10+rdlen > len(reply) {
			return 0, false
		}
		if ttl < min {
			min = ttl
		}
		off = next + 10 + rdlen
	}
	return min, true
}

func (c *dnsCache) get(q []byte) ([]byte, bool) {
	key, ok := cacheKey(q)
	if !ok {
		return nil, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e, hit := c.m[key]
	if !hit {
		return nil, false
	}
	if !c.now().Before(e.expires) {
		delete(c.m, key)
		return nil, false
	}
	out := append([]byte(nil), e.reply...)
	out[0], out[1] = q[0], q[1] // the answer belongs to this query's ID
	return out, true
}

func (c *dnsCache) put(q, reply []byte) {
	key, ok := cacheKey(q)
	if !ok {
		return
	}
	ttl, ok := answerTTL(reply)
	if !ok || ttl == 0 {
		return
	}
	if ttl > cacheMaxTTL {
		ttl = cacheMaxTTL
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.m) >= cacheMaxEntries {
		now := c.now()
		for k, e := range c.m {
			if !now.Before(e.expires) {
				delete(c.m, k)
			}
		}
		for k := range c.m { // still full: drop an arbitrary tenth
			if len(c.m) < cacheMaxEntries-cacheMaxEntries/10 {
				break
			}
			delete(c.m, k)
		}
	}
	c.m[key] = cacheEntry{reply: append([]byte(nil), reply...), expires: c.now().Add(time.Duration(ttl) * time.Second)}
}
