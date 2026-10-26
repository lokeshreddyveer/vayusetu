/* VayuSetu addition (see ios/Vendor/PATCHES.md). SPDX-License-Identifier: MIT
 *
 * DNS rebinding protection. A public name that answers with an address inside the home network (192.168.x.x, 10.x.x.x, loopback and so on) is
 * how a web page can reach into the router or a device in the house, so such an answer is replaced by "does not exist". Names that legitimately
 * point inward are left alone: local-network suffixes and single labels, and a few services that publish private addresses on purpose.
 * Not rebinding: 0.0.0.0 and :: (how filtering resolvers say "blocked") and 100.64.0.0/10 (carrier-grade NAT and overlay-VPN names).
 */

package main

import (
	"encoding/binary"
	"strings"
)

var rebindingExemptSuffixes = []string{"local", "lan", "home", "home.arpa", "internal", "localdomain", "localhost", "intranet", "corp", "plex.direct", "ts.net", "in-addr.arpa", "ip6.arpa"}

func rebindingExempt(name string) bool {
	n := strings.TrimSuffix(strings.ToLower(name), ".")
	if n == "" || !strings.Contains(n, ".") {
		return true
	}
	for _, s := range rebindingExemptSuffixes {
		if n == s || strings.HasSuffix(n, "."+s) {
			return true
		}
	}
	return false
}

func privateAddress(a []byte) bool {
	switch len(a) {
	case 4:
		switch {
		case a[0] == 0 && a[1] == 0 && a[2] == 0 && a[3] == 0:
			return false
		case a[0] == 10, a[0] == 127:
			return true
		case a[0] == 169 && a[1] == 254, a[0] == 192 && a[1] == 168:
			return true
		case a[0] == 172 && a[1] >= 16 && a[1] <= 31:
			return true
		}
	case 16:
		zero := true
		for _, b := range a {
			if b != 0 {
				zero = false
				break
			}
		}
		if zero {
			return false
		}
		allZero := func(s []byte) bool {
			for _, b := range s {
				if b != 0 {
					return false
				}
			}
			return true
		}
		switch {
		case allZero(a[:15]) && a[15] == 1: // ::1
			return true
		case a[0]&0xfe == 0xfc: // fc00::/7
			return true
		case a[0] == 0xfe && a[1]&0xc0 == 0x80: // fe80::/10
			return true
		case allZero(a[:10]) && a[10] == 0xff && a[11] == 0xff: // ::ffff:a.b.c.d
			return privateAddress(a[12:])
		}
	}
	return false
}

// answerAddresses lists the A and AAAA records in a reply's answer section, as raw bytes.
func answerAddresses(reply []byte) [][]byte {
	if len(reply) < 12 || reply[2]&0x80 == 0 {
		return nil
	}
	questions := int(binary.BigEndian.Uint16(reply[4:]))
	answers := int(binary.BigEndian.Uint16(reply[6:]))
	off := 12
	for i := 0; i < questions; i++ {
		_, next, ok := readName(reply, off)
		if !ok || next+4 > len(reply) {
			return nil
		}
		off = next + 4
	}
	var found [][]byte
	for i := 0; i < answers; i++ {
		_, next, ok := readName(reply, off)
		if !ok || next+10 > len(reply) {
			return found
		}
		rrType := binary.BigEndian.Uint16(reply[next:])
		rdLen := int(binary.BigEndian.Uint16(reply[next+8:]))
		rdata := next + 10
		if rdata+rdLen > len(reply) {
			return found
		}
		if (rrType == 1 && rdLen == 4) || (rrType == 28 && rdLen == 16) {
			found = append(found, reply[rdata:rdata+rdLen])
		}
		off = rdata + rdLen
	}
	return found
}

// rebindingBlocked reports whether the reply to `name` should be replaced.
func rebindingBlocked(name string, reply []byte) bool {
	if rebindingExempt(name) {
		return false
	}
	for _, a := range answerAddresses(reply) {
		if privateAddress(a) {
			return true
		}
	}
	return false
}
