package main

import (
	"bytes"
	"testing"
	"time"
)

// query for example.com A, ID 0x1234, RD set.
func cacheQuery(id1, id2 byte) []byte {
	q := []byte{id1, id2, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0}
	q = append(q, 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1)
	return q
}

// reply with one A record (compressed name), the given TTL, flags and rcode.
func cacheReply(q []byte, ttl uint32, flags2, rcode byte) []byte {
	r := append([]byte(nil), q...)
	r[2], r[3] = flags2, 0x80|rcode
	r[7] = 1
	r = append(r, 0xC0, 0x0C, 0, 1, 0, 1, byte(ttl>>24), byte(ttl>>16), byte(ttl>>8), byte(ttl), 0, 4, 93, 184, 216, 34)
	return r
}

func TestCacheHitRewritesID(t *testing.T) {
	c := newDNSCache()
	q1 := cacheQuery(0x12, 0x34)
	c.put(q1, cacheReply(q1, 60, 0x81, 0))
	q2 := cacheQuery(0xAB, 0xCD)
	got, ok := c.get(q2)
	if !ok || got[0] != 0xAB || got[1] != 0xCD {
		t.Fatalf("expected a hit with the new ID, got ok=%v %x", ok, got)
	}
	if !bytes.Equal(got[2:], cacheReply(q1, 60, 0x81, 0)[2:]) {
		t.Fatal("cached body changed")
	}
}

func TestCacheSkipsUncacheable(t *testing.T) {
	q := cacheQuery(1, 2)
	for name, reply := range map[string][]byte{
		"zero ttl":  cacheReply(q, 0, 0x81, 0),
		"truncated": cacheReply(q, 60, 0x83, 0),
		"servfail":  cacheReply(q, 60, 0x81, 2),
	} {
		c := newDNSCache()
		c.put(q, reply)
		if _, ok := c.get(q); ok {
			t.Fatalf("%s must not be cached", name)
		}
	}
}

func TestCacheExpiresAndClampsTTL(t *testing.T) {
	c := newDNSCache()
	now := time.Unix(1000, 0)
	c.now = func() time.Time { return now }
	q := cacheQuery(1, 2)
	c.put(q, cacheReply(q, 86400, 0x81, 0)) // a day, clamped to cacheMaxTTL
	now = now.Add((cacheMaxTTL - 1) * time.Second)
	if _, ok := c.get(q); !ok {
		t.Fatal("should still be cached just before the clamp")
	}
	now = now.Add(2 * time.Second)
	if _, ok := c.get(q); ok {
		t.Fatal("must expire after the clamp")
	}
}

func TestCacheKeySeparatesQueries(t *testing.T) {
	c := newDNSCache()
	q := cacheQuery(1, 2)
	c.put(q, cacheReply(q, 60, 0x81, 0))
	other := cacheQuery(1, 2)
	other[len(other)-2] = 28 // AAAA
	if _, ok := c.get(other); ok {
		t.Fatal("a different record type must not hit")
	}
	cd := cacheQuery(1, 2)
	cd[3] |= 0x10 // checking disabled
	if _, ok := c.get(cd); ok {
		t.Fatal("a different CD flag must not hit")
	}
	resp := cacheReply(q, 60, 0x81, 0)
	if _, ok := c.get(resp); ok {
		t.Fatal("a response is never a lookup key")
	}
}
