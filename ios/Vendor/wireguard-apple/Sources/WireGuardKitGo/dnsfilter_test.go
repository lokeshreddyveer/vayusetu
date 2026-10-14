package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"os"
	"testing"
	"time"
)

// The Swift host test (ios/Tests/DNSOnlyTests.swift) writes a fixture when VS_RULE_FIXTURE is set;
// this proves the app's writer and this reader agree on hashing and layout.
func TestSwiftSnapshot(t *testing.T) {
	path := os.Getenv("VS_RULE_FIXTURE")
	if path == "" {
		t.Skip("VS_RULE_FIXTURE not set")
	}
	r, err := loadRules(path)
	if err != nil {
		t.Fatal(err)
	}
	if r.count() != 5 {
		t.Fatalf("expected 5 rules, got %d", r.count())
	}
	cases := map[string]decision{
		"ads.example": blocked, "x.y.ads.example": blocked, "notads.example": noMatch, "example": noMatch,
		"exact.org": blocked, "sub.exact.org": noMatch, "www.ads.example": allowed, "ok.tracker.net": allowed,
		"a.ok.tracker.net": allowed, "tracker.net": blocked, "other.tracker.net": blocked, "": noMatch,
	}
	for name, want := range cases {
		if got := r.decide(name); got != want {
			t.Errorf("decide(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestRejectsBadSnapshots(t *testing.T) {
	dir := t.TempDir()
	for name, data := range map[string][]byte{"junk": []byte("junk"), "short": append(append([]byte{}, rulesMagic...), 1, 0, 0, 0)} {
		p := dir + "/" + name
		_ = os.WriteFile(p, data, 0o600)
		if _, err := loadRules(p); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	inflated := append(append([]byte{}, rulesMagic...), make([]byte, 16)...)
	binary.LittleEndian.PutUint32(inflated[8:], 1<<30)
	p := dir + "/inflated"
	_ = os.WriteFile(p, inflated, 0o600)
	if _, err := loadRules(p); err == nil {
		t.Error("inflated counts must be rejected")
	}
}

func testFilter() *dnsFilter {
	return &dnsFilter{server: net.ParseIP("198.18.0.2").To4()}
}

var exampleQuery = []byte{0xab, 0xcd, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1}

func datagram(payload []byte, dst net.IP, dport uint16) []byte {
	udp := 8 + len(payload)
	p := make([]byte, 20+udp)
	p[0] = 0x45
	binary.BigEndian.PutUint16(p[2:], uint16(len(p)))
	p[6], p[8], p[9] = 0x40, 64, 17
	copy(p[12:16], []byte{198, 18, 0, 1})
	copy(p[16:20], dst.To4())
	binary.BigEndian.PutUint16(p[20:], 51000)
	binary.BigEndian.PutUint16(p[22:], dport)
	binary.BigEndian.PutUint16(p[24:], uint16(udp))
	copy(p[28:], payload)
	return p
}

func TestPacketParseAndReply(t *testing.T) {
	f := testFilter()
	q, ok := f.parse(datagram(exampleQuery, f.server, 53))
	if !ok || !bytes.Equal(q.payload, exampleQuery) || q.srcPort != 51000 {
		t.Fatal("valid query was not parsed")
	}
	for name, p := range map[string][]byte{
		"other server": datagram(exampleQuery, net.ParseIP("8.8.8.8"), 53),
		"other port":   datagram(exampleQuery, f.server, 853),
		"short":        datagram(exampleQuery[:8], f.server, 53),
	} {
		if _, ok := f.parse(p); ok {
			t.Errorf("%s must not be intercepted", name)
		}
	}
	answer := append(append([]byte{}, exampleQuery[:2]...), 0x81, 0x80, 0, 0, 0, 0, 0, 0, 0, 0)
	out := f.reply(q, answer)
	p := out[tunOffset:]
	if checksum(p[:20]) != 0 {
		t.Error("IPv4 header checksum is invalid")
	}
	udp := int(binary.BigEndian.Uint16(p[24:]))
	pseudo := append(append([]byte{}, p[12:20]...), 0, 17, byte(udp>>8), byte(udp))
	if checksum(append(pseudo, p[20:]...)) != 0 {
		t.Error("UDP checksum is invalid")
	}
	if !bytes.Equal(p[16:20], []byte{198, 18, 0, 1}) || binary.BigEndian.Uint16(p[22:]) != 51000 {
		t.Error("reply is not addressed to the asking socket")
	}
}

func TestQuestionAndBlockedResponse(t *testing.T) {
	name, end, ok := question(exampleQuery)
	if !ok || name != "example.com" || end != len(exampleQuery) {
		t.Fatalf("question = %q %d %v", name, end, ok)
	}
	b := blockedResponse(exampleQuery, end)
	if b[0] != 0xab || b[1] != 0xcd || b[2]&0x80 == 0 || b[3]&0x0f != 3 || !bytes.Equal(b[12:], exampleQuery[12:]) {
		t.Error("blocked response is not an NXDOMAIN echoing the question")
	}
	pointer := append([]byte{}, exampleQuery...)
	pointer[12] = 0xc0
	if _, _, ok := question(pointer); ok {
		t.Error("compressed question must be rejected")
	}
}

// Live check (skipped unless VS_LIVE=1): the shared client must reach an HTTP/2-only resolver through its bootstrap address.
func TestLiveUpstreamHTTP2(t *testing.T) {
	if os.Getenv("VS_LIVE") != "1" {
		t.Skip("VS_LIVE not set")
	}
	u, err := newUpstream(dnsConfig{Resolver: "https://dns.quad9.net/dns-query", Bootstrap: []string{"9.9.9.9", "149.112.112.112"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	reply, err := u.exchange(ctx, exampleQuery)
	if err != nil {
		t.Fatal(err)
	}
	if reply[0] != 0xab || reply[1] != 0xcd || reply[3]&0x0f != 0 || len(reply) < 40 {
		t.Fatalf("unexpected reply % x", reply)
	}
}

func TestUpstreamHandles(t *testing.T) {
	if _, err := newUpstream(dnsConfig{Resolver: "https://dns.example/q"}, nil); err == nil {
		t.Error("bootstrap addresses are required")
	}
	if _, err := newUpstream(dnsConfig{Resolver: "http://dns.example/q", Bootstrap: []string{"9.9.9.9"}}, nil); err == nil {
		t.Error("plain http resolvers must be rejected")
	}
	if _, err := newUpstream(dnsConfig{Resolver: "https://dns.example/q", Bootstrap: []string{"9.9.9.9"}, ViaVPN: true}, nil); err == nil {
		t.Error("VPN binding without a device must fail")
	}
}
