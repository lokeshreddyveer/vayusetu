package main

import "testing"

func nameBytes(name string) []byte {
	var out []byte
	start := 0
	for i := 0; i <= len(name); i++ {
		if i == len(name) || name[i] == '.' {
			out = append(out, byte(i-start))
			out = append(out, name[start:i]...)
			start = i + 1
		}
	}
	return append(out, 0)
}

// reply to a query for `asked`: asked CNAME alias (compressed pointer to the question name), alias A 1.2.3.4
func cnameReply(asked, alias string) []byte {
	r := []byte{0x12, 0x34, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0}
	r = append(r, nameBytes(asked)...)
	r = append(r, 0, 1, 0, 1) // A IN
	// answer 1: pointer to the question name, CNAME IN ttl 60, rdata = alias name
	r = append(r, 0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 60)
	a := nameBytes(alias)
	r = append(r, byte(len(a)>>8), byte(len(a)))
	aliasOff := len(r)
	r = append(r, a...)
	// answer 2: pointer to the alias name inside answer 1, A record
	r = append(r, 0xC0|byte(aliasOff>>8), byte(aliasOff), 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 1, 2, 3, 4)
	return r
}

func TestCNAMETargetsAreParsed(t *testing.T) {
	got := cnameTargets(cnameReply("metrics.example.com", "Collector.Tracker-CDN.net"))
	if len(got) != 1 || got[0] != "collector.tracker-cdn.net" {
		t.Fatalf("got %v", got)
	}
	if len(cnameTargets([]byte{1, 2, 3})) != 0 || len(cnameTargets(nil)) != 0 {
		t.Fatal("garbage must yield nothing")
	}
	trunc := cnameReply("a.example.com", "b.example.net")
	for n := 0; n < len(trunc); n++ { // no truncation may panic
		_ = cnameTargets(trunc[:n])
	}
}

func TestUncloakedBlocksAliasToBlockedName(t *testing.T) {
	rules := &ruleSet{blockSuffix: map[uint64]struct{}{fnv64("tracker-cdn.net"): {}}, blockExact: map[uint64]struct{}{}, allowSuffix: map[uint64]struct{}{}, allowExact: map[uint64]struct{}{}, threatSuffix: map[uint64]struct{}{}, threatExact: map[uint64]struct{}{}}
	if got := rules.uncloaked(cnameReply("metrics.example.com", "collector.tracker-cdn.net")); got != "collector.tracker-cdn.net" {
		t.Fatalf("alias to a blocked suffix must be caught, got %q", got)
	}
	if got := rules.uncloaked(cnameReply("www.example.com", "example.cdn.cloudflare.net")); got != "" {
		t.Fatalf("an ordinary CDN alias must pass, got %q", got)
	}
	var none *ruleSet
	if none.uncloaked(cnameReply("a.example.com", "b.tracker-cdn.net")) != "" {
		t.Fatal("no rules means nothing is blocked")
	}
}
