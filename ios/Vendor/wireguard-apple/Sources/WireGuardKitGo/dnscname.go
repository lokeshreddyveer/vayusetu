/* VayuSetu addition (see ios/Vendor/PATCHES.md). SPDX-License-Identifier: MIT
 *
 * CNAME uncloaking. Trackers hide behind a first-party name (metrics.example.com) that is only an alias for a tracker's server
 * (example.tracker-cdn.net). A list of tracker domains never sees the alias, so the answer is checked too: if any name in its CNAME
 * chain is blocked, the whole lookup is answered as blocked.
 */

package main

import (
	"encoding/binary"
	"strings"
)

// readName decodes a possibly compressed domain name at off and returns it lowercase, without a trailing dot, and the offset just after it
// in the original (uncompressed) position.
func readName(msg []byte, off int) (string, int, bool) {
	var labels []string
	next := -1
	for hops := 0; hops < 64; hops++ {
		if off >= len(msg) {
			return "", 0, false
		}
		n := int(msg[off])
		switch {
		case n == 0:
			if next < 0 {
				next = off + 1
			}
			return strings.ToLower(strings.Join(labels, ".")), next, true
		case n&0xC0 == 0xC0:
			if off+1 >= len(msg) {
				return "", 0, false
			}
			if next < 0 {
				next = off + 2
			}
			off = (n&0x3F)<<8 | int(msg[off+1])
		case n&0xC0 != 0:
			return "", 0, false
		default:
			if off+1+n > len(msg) {
				return "", 0, false
			}
			labels = append(labels, string(msg[off+1:off+1+n]))
			off += 1 + n
		}
	}
	return "", 0, false
}

// cnameTargets lists the alias targets in a reply's answer section (type 5 records), in order.
func cnameTargets(reply []byte) []string {
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
	var targets []string
	for i := 0; i < answers; i++ {
		_, next, ok := readName(reply, off)
		if !ok || next+10 > len(reply) {
			return targets
		}
		rrType := binary.BigEndian.Uint16(reply[next:])
		rdLen := int(binary.BigEndian.Uint16(reply[next+8:]))
		rdata := next + 10
		if rdata+rdLen > len(reply) {
			return targets
		}
		if rrType == 5 {
			if name, _, ok := readName(reply, rdata); ok && name != "" {
				targets = append(targets, name)
			}
		}
		off = rdata + rdLen
	}
	return targets
}

// uncloaked returns the first name in the CNAME chain that the rules block, or "" if none is. The caller has already decided that
// the queried name itself is not blocked; a user's allow rule for the queried name is honoured by not calling this at all.
func (r *ruleSet) uncloaked(reply []byte) string {
	if r == nil || r.count() == 0 {
		return ""
	}
	for _, target := range cnameTargets(reply) {
		if r.decide(target) == blocked {
			return target
		}
	}
	return ""
}
