/* VayuSetu addition (see ios/Vendor/PATCHES.md). SPDX-License-Identifier: MIT */

package main

// #include <stdlib.h>
import "C"

import (
	"context"
	"encoding/json"
	"sync"
	"time"
	"unsafe"
)

// wgDNSConfigure stages the DNS filter for the next wgTurnOn. A nil or empty configuration disables it.
// Returns 0 on success, -1 when the JSON is invalid (the filter is then disabled).
//
//export wgDNSConfigure
func wgDNSConfigure(settings *C.char) int32 {
	pendingMu.Lock()
	defer pendingMu.Unlock()
	pending = nil
	if settings == nil {
		return 0
	}
	var cfg dnsConfig
	if err := json.Unmarshal([]byte(C.GoString(settings)), &cfg); err != nil {
		return -1
	}
	if cfg.Resolver == "" {
		return 0
	}
	pending = &cfg
	return 0
}

// wgDNSReload re-reads the rule snapshot of the running filter.
//
//export wgDNSReload
func wgDNSReload() {
	activeMu.Lock()
	f := active
	activeMu.Unlock()
	if f != nil {
		f.reloadRules()
	}
}

// wgDNSStats returns the running filter's counters as JSON, or NULL when no filter is active. Free with free().
//
//export wgDNSStats
func wgDNSStats() *C.char {
	activeMu.Lock()
	f := active
	activeMu.Unlock()
	if f == nil {
		return nil
	}
	data, err := json.Marshal(f.counters())
	if err != nil {
		return nil
	}
	return C.CString(string(data))
}

// The local DNS-only tunnel (Swift, packetFlow) reuses this upstream client: it speaks HTTP/2 (some resolvers such as
// Quad9 reject HTTP/1.1), connects to bootstrap addresses so resolving the resolver never re-enters the tunnel, and
// reuses connections.
var (
	upstreamMu   sync.Mutex
	upstreamsOpen = map[int32]*upstream{}
	upstreamNext  int32
)

// wgDNSUpstreamOpen validates the settings JSON (resolver, bootstrap) and returns a handle, or -1.
//
//export wgDNSUpstreamOpen
func wgDNSUpstreamOpen(settings *C.char) int32 {
	if settings == nil {
		return -1
	}
	var cfg dnsConfig
	if err := json.Unmarshal([]byte(C.GoString(settings)), &cfg); err != nil {
		return -1
	}
	cfg.ViaVPN = false // there is no VPN interface to bind to in the DNS-only tunnel
	u, err := newUpstream(cfg, nil)
	if err != nil {
		return -1
	}
	upstreamMu.Lock()
	defer upstreamMu.Unlock()
	upstreamNext++
	upstreamsOpen[upstreamNext] = u
	return upstreamNext
}

// wgDNSUpstreamExchange sends one DNS message and copies the reply into out. Returns the reply length,
// -1 on failure (the caller answers SERVFAIL; there is never a plaintext fallback) or -2 if out is too small.
//
//export wgDNSUpstreamExchange
func wgDNSUpstreamExchange(handle int32, query *C.uchar, queryLength C.int, out *C.uchar, outCapacity C.int) C.int {
	upstreamMu.Lock()
	u := upstreamsOpen[handle]
	upstreamMu.Unlock()
	if u == nil || query == nil || out == nil || queryLength < 12 || queryLength > 65535 {
		return -1
	}
	q := C.GoBytes(unsafe.Pointer(query), queryLength)
	ctx, cancel := context.WithTimeout(context.Background(), upstreamTimeout+time.Second)
	defer cancel()
	reply, err := u.exchange(ctx, q)
	if err != nil {
		return -1
	}
	if C.int(len(reply)) > outCapacity {
		return -2
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(out)), len(reply)), reply)
	return C.int(len(reply))
}

//export wgDNSUpstreamClose
func wgDNSUpstreamClose(handle int32) {
	upstreamMu.Lock()
	u := upstreamsOpen[handle]
	delete(upstreamsOpen, handle)
	upstreamMu.Unlock()
	if u != nil && u.client != nil {
		u.client.CloseIdleConnections()
	}
}
