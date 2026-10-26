package main

import "testing"

// a reply to `asked` with one A record
func aReply(asked string, ip [4]byte) []byte {
	r := []byte{0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0}
	r = append(r, nameBytes(asked)...)
	r = append(r, 0, 1, 0, 1)
	r = append(r, 0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, ip[0], ip[1], ip[2], ip[3])
	return r
}

func TestPrivateAddressesAreRecognised(t *testing.T) {
	for _, ip := range [][]byte{{10, 1, 2, 3}, {127, 0, 0, 1}, {169, 254, 1, 1}, {192, 168, 1, 1}, {172, 16, 0, 1}, {172, 31, 255, 255}} {
		if !privateAddress(ip) {
			t.Fatalf("%v is private", ip)
		}
	}
	for _, ip := range [][]byte{{8, 8, 8, 8}, {172, 15, 0, 1}, {172, 32, 0, 1}, {192, 169, 0, 1}, {100, 64, 0, 1}, {0, 0, 0, 0}} {
		if privateAddress(ip) {
			t.Fatalf("%v is not private (0.0.0.0 is how resolvers say blocked; 100.64/10 is carrier NAT and overlay VPNs)", ip)
		}
	}
	v6loop := make([]byte, 16)
	v6loop[15] = 1
	ula := make([]byte, 16)
	ula[0] = 0xfd
	link := make([]byte, 16)
	link[0], link[1] = 0xfe, 0x80
	mapped := []byte{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 0, 5}
	pub := make([]byte, 16)
	pub[0], pub[1] = 0x20, 0x01
	for _, ip := range [][]byte{v6loop, ula, link, mapped} {
		if !privateAddress(ip) {
			t.Fatalf("%v is private", ip)
		}
	}
	if privateAddress(pub) || privateAddress(make([]byte, 16)) {
		t.Fatal("a global IPv6 address and :: are not private")
	}
}

func TestPublicNameAnsweringPrivateIsBlocked(t *testing.T) {
	if !rebindingBlocked("evil.example.com", aReply("evil.example.com", [4]byte{192, 168, 1, 1})) {
		t.Fatal("a public name answering with a router address must be blocked")
	}
	if rebindingBlocked("example.com", aReply("example.com", [4]byte{93, 184, 216, 34})) {
		t.Fatal("an ordinary answer must pass")
	}
	if rebindingBlocked("blocked.example.com", aReply("blocked.example.com", [4]byte{0, 0, 0, 0})) {
		t.Fatal("0.0.0.0 is a resolver's own block, not rebinding")
	}
}

func TestLocalNamesAndKnownServicesAreExempt(t *testing.T) {
	for _, n := range []string{"printer", "nas.local", "router.lan", "x.home.arpa", "abc.plex.direct", "mac.tail1234.ts.net", "Host.Internal.", "1.0.168.192.in-addr.arpa"} {
		if !rebindingExempt(n) {
			t.Fatalf("%q should be exempt", n)
		}
		if rebindingBlocked(n, aReply(n, [4]byte{192, 168, 1, 9})) {
			t.Fatalf("%q must not be blocked", n)
		}
	}
	if rebindingExempt("evil.example.com") || rebindingExempt("notlocal.com") {
		t.Fatal("public names are not exempt, and a name that merely ends in letters of an exempt suffix is not exempt")
	}
}

func TestMalformedRepliesNeverPanic(t *testing.T) {
	r := aReply("evil.example.com", [4]byte{10, 0, 0, 1})
	for n := 0; n <= len(r); n++ {
		_ = rebindingBlocked("evil.example.com", r[:n])
	}
	if rebindingBlocked("evil.example.com", nil) {
		t.Fatal("no reply, no block")
	}
}

// An explicit allow for the asked name must beat rebinding protection (the filter checks `decision != allowed` before calling rebindingBlocked).
func TestAllowRuleDecisionIsDistinguishableFromBlock(t *testing.T) {
	rules := &ruleSet{allowExact: map[uint64]struct{}{fnv64("evil.example.com"): {}}, blockExact: map[uint64]struct{}{}, blockSuffix: map[uint64]struct{}{}, allowSuffix: map[uint64]struct{}{}}
	if rules.decide("evil.example.com") != allowed {
		t.Fatal("an exact allow rule must decide `allowed`, which is what exempts the name from rebinding protection")
	}
	if rules.decide("other.example.com") == allowed {
		t.Fatal("the allow rule is for one name only")
	}
}
