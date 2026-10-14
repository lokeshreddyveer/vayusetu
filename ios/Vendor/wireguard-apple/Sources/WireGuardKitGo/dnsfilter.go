/* VayuSetu addition (see ios/Vendor/PATCHES.md). SPDX-License-Identifier: MIT
 *
 * Intercepts DNS queries sent to a virtual in-tunnel DNS address before they enter WireGuard,
 * answers blocked names locally and forwards the rest to an encrypted resolver (DoH or DoT).
 * It is inactive unless wgDNSConfigure was called with filtering enabled, so the stock
 * WireGuard data path is unchanged otherwise. IPv4/UDP DNS only.
 */

package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/tun"
)

const (
	tunOffset         = 16 // WireGuard's MessageTransportOffsetContent: headroom the tun write path expects
	maxInFlight       = 32
	maxRules          = 700000
	maxPayload        = 1372 // 1400-byte tunnel MTU minus IPv4 and UDP headers
	upstreamTimeout   = 5 * time.Second
	maxUpstreamReply  = 65535
	rulesHeaderLength = 8 + 16
)

var rulesMagic = []byte("VSDR1\x00\x00\x00")

// VSDR2 adds two sets after the four of VSDR1: blocked names that belong to security (malware/phishing) lists, so
// the counters can tell a blocked threat from a blocked ad or tracker.
var rulesMagicV2 = []byte("VSDR2\x00\x00\x00")

type dnsConfig struct {
	RulesPath string   `json:"rulesPath"`
	Resolver  string   `json:"resolver"`
	Bootstrap []string `json:"bootstrap"`
	ViaVPN    bool     `json:"viaVPN"`
	Server    string   `json:"server"`
	Filtering bool     `json:"filtering"`
	// An optional second encrypted resolver, tried only when the first fails. Never plaintext.
	Fallback          string   `json:"fallback"`
	FallbackBootstrap []string `json:"fallbackBootstrap"`
}

type ruleSet struct {
	blockSuffix, blockExact, allowSuffix, allowExact map[uint64]struct{}
	threatSuffix, threatExact                       map[uint64]struct{}
}

func (r *ruleSet) count() int {
	if r == nil {
		return 0
	}
	return len(r.blockSuffix) + len(r.blockExact) + len(r.allowSuffix) + len(r.allowExact)
}

func fnv64(s string) uint64 {
	h := uint64(0xcbf29ce484222325)
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 0x100000001b3
	}
	return h
}

// loadRules reads the snapshot the app writes (see DNSRuleSnapshot.encoded in Secrets.swift).
func loadRules(path string) (*ruleSet, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	setCount := 4
	switch {
	case len(data) >= 8 && bytes.Equal(data[:8], rulesMagic):
	case len(data) >= 8 && bytes.Equal(data[:8], rulesMagicV2):
		setCount = 6
	default:
		return nil, errors.New("unknown rule snapshot format")
	}
	header := 8 + setCount*4
	if len(data) < header {
		return nil, errors.New("unknown rule snapshot format")
	}
	counts := make([]int, setCount)
	total := 0
	for i := range counts {
		counts[i] = int(binary.LittleEndian.Uint32(data[8+i*4:]))
		total += counts[i]
	}
	if total > maxRules || len(data) != header+total*8 {
		return nil, errors.New("rule snapshot is truncated or too large")
	}
	sets := make([]map[uint64]struct{}, 6)
	offset := header
	for i := 0; i < 6; i++ {
		c := 0
		if i < setCount {
			c = counts[i]
		}
		sets[i] = make(map[uint64]struct{}, c)
		for j := 0; j < c; j++ {
			sets[i][binary.LittleEndian.Uint64(data[offset:])] = struct{}{}
			offset += 8
		}
	}
	return &ruleSet{blockSuffix: sets[0], blockExact: sets[1], allowSuffix: sets[2], allowExact: sets[3], threatSuffix: sets[4], threatExact: sets[5]}, nil
}

// isThreat reports whether a blocked name is on a security list. name is lowercase without a trailing dot.
func (r *ruleSet) isThreat(name string) bool {
	if r == nil || (len(r.threatSuffix) == 0 && len(r.threatExact) == 0) {
		return false
	}
	if _, ok := r.threatExact[fnv64(name)]; ok {
		return true
	}
	for rest := name; rest != ""; {
		if _, ok := r.threatSuffix[fnv64(rest)]; ok {
			return true
		}
		dot := strings.IndexByte(rest, '.')
		if dot < 0 {
			break
		}
		rest = rest[dot+1:]
	}
	return false
}

type decision int

const (
	noMatch decision = iota
	allowed
	blocked
)

// decide: any allow match beats any block match. name is lowercase without a trailing dot.
func (r *ruleSet) decide(name string) decision {
	if r == nil || r.count() == 0 || name == "" {
		return noMatch
	}
	exact := fnv64(name)
	if _, ok := r.allowExact[exact]; ok {
		return allowed
	}
	isBlocked := false
	if _, ok := r.blockExact[exact]; ok {
		isBlocked = true
	}
	for rest := name; rest != ""; {
		h := fnv64(rest)
		if _, ok := r.allowSuffix[h]; ok {
			return allowed
		}
		if _, ok := r.blockSuffix[h]; ok {
			isBlocked = true
		}
		dot := strings.IndexByte(rest, '.')
		if dot < 0 {
			break
		}
		rest = rest[dot+1:]
	}
	if isBlocked {
		return blocked
	}
	return noMatch
}

type dnsCounters struct {
	Queries  uint64 `json:"queries"`
	Answered uint64 `json:"answered"`
	Failed   uint64 `json:"failed"`
	Dropped  uint64 `json:"dropped"`
	Blocked  uint64 `json:"blocked"`
	Threats  uint64 `json:"threats"`
	Rules    uint64 `json:"rules"`
}

type dnsFilter struct {
	cfg      dnsConfig
	server   net.IP
	rules    atomic.Pointer[ruleSet]
	up       *upstream
	backup   *upstream
	inflight chan struct{}
	queries, answered, failed, dropped, blockedCount, threatCount atomic.Uint64
	dev      tun.Device
}

var (
	pendingMu sync.Mutex
	pending   *dnsConfig
	activeMu  sync.Mutex
	active    *dnsFilter
)

func newDNSFilter(cfg dnsConfig, dev tun.Device) (*dnsFilter, error) {
	server := net.ParseIP(cfg.Server).To4()
	if server == nil {
		return nil, errors.New("invalid virtual DNS server address")
	}
	up, err := newUpstream(cfg, dev)
	if err != nil {
		return nil, err
	}
	f := &dnsFilter{cfg: cfg, server: server, up: up, inflight: make(chan struct{}, maxInFlight), dev: dev}
	if cfg.Fallback != "" {
		second := cfg
		second.Resolver, second.Bootstrap = cfg.Fallback, cfg.FallbackBootstrap
		// A bad backup must never stop the tunnel: it is simply not used.
		if b, err := newUpstream(second, dev); err == nil {
			f.backup = b
		}
	}
	f.reloadRules()
	return f, nil
}

func (f *dnsFilter) reloadRules() {
	if !f.cfg.Filtering {
		f.rules.Store(nil)
		return
	}
	// A missing or invalid snapshot means zero rules, reported as such: never a claim of protection.
	if r, err := loadRules(f.cfg.RulesPath); err == nil {
		f.rules.Store(r)
	} else {
		f.rules.Store(&ruleSet{})
	}
}

func (f *dnsFilter) counters() dnsCounters {
	return dnsCounters{Queries: f.queries.Load(), Answered: f.answered.Load(), Failed: f.failed.Load(), Dropped: f.dropped.Load(), Blocked: f.blockedCount.Load(), Threats: f.threatCount.Load(), Rules: uint64(f.rules.Load().count())}
}

// ---- tun wrapper -------------------------------------------------------------------------

type filterTUN struct {
	tun.Device
	f *dnsFilter
}

func (t *filterTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	n, err := t.Device.Read(bufs, sizes, offset)
	for i := 0; i < n; i++ {
		if sizes[i] < 1 {
			continue
		}
		if t.f.intercept(bufs[i][offset : offset+sizes[i]]) {
			// WireGuard skips zero-length entries; the buffer mapping stays intact.
			sizes[i] = 0
		}
	}
	return n, err
}

// ---- packets -----------------------------------------------------------------------------

type dnsQuery struct {
	src     net.IP
	srcPort uint16
	payload []byte
}

func (f *dnsFilter) parse(p []byte) (dnsQuery, bool) {
	if len(p) < 28 || p[0]>>4 != 4 {
		return dnsQuery{}, false
	}
	ihl := int(p[0]&0x0f) * 4
	total := int(binary.BigEndian.Uint16(p[2:4]))
	if ihl < 20 || total > len(p) || total < ihl+8 || p[9] != 17 || p[6]&0x3f != 0 || p[7] != 0 || !bytes.Equal(p[16:20], f.server) {
		return dnsQuery{}, false
	}
	if binary.BigEndian.Uint16(p[ihl+2:]) != 53 {
		return dnsQuery{}, false
	}
	udpLen := int(binary.BigEndian.Uint16(p[ihl+4:]))
	if udpLen < 8+12 || ihl+udpLen > total {
		return dnsQuery{}, false
	}
	return dnsQuery{src: net.IP(append([]byte(nil), p[12:16]...)), srcPort: binary.BigEndian.Uint16(p[ihl:]), payload: append([]byte(nil), p[ihl+8:ihl+udpLen]...)}, true
}

func checksum(b []byte) uint16 {
	var sum uint32
	for i := 0; i+1 < len(b); i += 2 {
		sum += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if len(b)%2 == 1 {
		sum += uint32(b[len(b)-1]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}

// reply builds an IPv4/UDP datagram with tunOffset bytes of headroom for the tun write path.
func (f *dnsFilter) reply(q dnsQuery, payload []byte) []byte {
	if len(payload) < 12 || len(payload) > maxPayload {
		return nil
	}
	udp := 8 + len(payload)
	total := 20 + udp
	buf := make([]byte, tunOffset+total)
	p := buf[tunOffset:]
	p[0] = 0x45
	binary.BigEndian.PutUint16(p[2:], uint16(total))
	p[6], p[8], p[9] = 0x40, 64, 17
	copy(p[12:16], f.server)
	copy(p[16:20], q.src)
	binary.BigEndian.PutUint16(p[10:], checksum(p[:20]))
	binary.BigEndian.PutUint16(p[20:], 53)
	binary.BigEndian.PutUint16(p[22:], q.srcPort)
	binary.BigEndian.PutUint16(p[24:], uint16(udp))
	copy(p[28:], payload)
	pseudo := append(append([]byte{}, p[12:20]...), 0, 17, byte(udp>>8), byte(udp))
	pseudo = append(pseudo, p[20:total]...)
	c := checksum(pseudo)
	if c == 0 {
		c = 0xffff
	}
	binary.BigEndian.PutUint16(p[26:], c)
	return buf
}

func (f *dnsFilter) send(q dnsQuery, payload []byte) {
	if buf := f.reply(q, payload); buf != nil {
		_, _ = f.dev.Write([][]byte{buf}, tunOffset)
	}
}

// question returns the single question of a standard query (no compression is valid there).
func question(p []byte) (name string, end int, ok bool) {
	if len(p) < 17 || p[2]&0xf8 != 0 || p[4] != 0 || p[5] != 1 {
		return "", 0, false
	}
	var labels []string
	off, length := 12, 0
	for {
		if off >= len(p) {
			return "", 0, false
		}
		n := int(p[off])
		if n == 0 {
			off++
			break
		}
		if n > 63 || off+1+n > len(p) {
			return "", 0, false
		}
		length += n + 1
		if length > 254 {
			return "", 0, false
		}
		labels = append(labels, strings.ToLower(string(p[off+1:off+1+n])))
		off += 1 + n
	}
	if len(labels) == 0 || off+4 > len(p) {
		return "", 0, false
	}
	return strings.Join(labels, "."), off + 4, true
}

func blockedResponse(q []byte, end int) []byte {
	out := []byte{q[0], q[1], 0x81, 0x83, 0, 1, 0, 0, 0, 0, 0, 0}
	return append(out, q[12:end]...)
}

func servfail(q []byte) []byte {
	return []byte{q[0], q[1], 0x81, 0x82, 0, 0, 0, 0, 0, 0, 0, 0}
}

// intercept returns true when the packet was a DNS query for the virtual server (it is then consumed).
func (f *dnsFilter) intercept(packet []byte) bool {
	q, ok := f.parse(packet)
	if !ok {
		return false
	}
	f.queries.Add(1)
	askedName, askedEnd, askedOK := question(q.payload)
	decision := noMatch
	if askedOK {
		decision = f.rules.Load().decide(askedName)
	}
	if askedOK && decision == blocked {
		name, end := askedName, askedEnd
		f.blockedCount.Add(1)
		if f.rules.Load().isThreat(name) {
			f.threatCount.Add(1)
		}
		f.send(q, blockedResponse(q.payload, end))
		return true
	}
	select {
	case f.inflight <- struct{}{}:
	default:
		f.dropped.Add(1)
		return true
	}
	go func() {
		defer func() { <-f.inflight }()
		ctx, cancel := context.WithTimeout(context.Background(), upstreamTimeout+time.Second)
		defer cancel()
		answer, err := f.up.exchange(ctx, q.payload)
		if err != nil && f.backup != nil {
			// The main resolver did not answer; ask the backup (also encrypted) rather than failing the lookup.
			answer, err = f.backup.exchange(ctx, q.payload)
		}
		if err != nil {
			f.failed.Add(1)
			f.send(q, servfail(q.payload)) // fail closed: never fall back to plaintext DNS
			return
		}
		// An explicit allow for the asked name wins; otherwise an alias that leads to a blocked name is blocked too.
		if askedOK && decision != allowed {
			if target := f.rules.Load().uncloaked(answer); target != "" {
				f.blockedCount.Add(1)
				if f.rules.Load().isThreat(target) {
					f.threatCount.Add(1)
				}
				f.send(q, blockedResponse(q.payload, askedEnd))
				return
			}
		}
		f.answered.Add(1)
		f.send(q, answer)
	}()
	return true
}

// ---- encrypted upstream ------------------------------------------------------------------

type upstream struct {
	host, path string
	dot        bool
	bootstrap  []net.IP
	ifIndex    int // utun index when queries must travel inside the VPN; 0 = outside
	client     *http.Client
	cache      *dnsCache
}

func newUpstream(cfg dnsConfig, dev tun.Device) (*upstream, error) {
	u, err := url.Parse(cfg.Resolver)
	if err != nil || u.Hostname() == "" || (u.Scheme != "https" && u.Scheme != "tls") {
		return nil, errors.New("invalid resolver endpoint")
	}
	up := &upstream{host: u.Hostname(), path: u.Path, dot: u.Scheme == "tls", cache: newDNSCache()}
	for _, a := range cfg.Bootstrap {
		if ip := net.ParseIP(a); ip != nil {
			up.bootstrap = append(up.bootstrap, ip)
		}
	}
	if len(up.bootstrap) == 0 {
		return nil, errors.New("resolver bootstrap addresses are required")
	}
	if cfg.ViaVPN {
		if dev == nil {
			return nil, errors.New("no tunnel device to bind the resolver connection to")
		}
		name, err := dev.Name()
		if err != nil {
			return nil, err
		}
		iface, err := net.InterfaceByName(name)
		if err != nil {
			return nil, err
		}
		up.ifIndex = iface.Index
	}
	up.client = &http.Client{
		Timeout: upstreamTimeout,
		Transport: &http.Transport{
			DialContext:         func(ctx context.Context, _, _ string) (net.Conn, error) { return up.dial(ctx, 443) },
			TLSClientConfig:     &tls.Config{ServerName: up.host, MinVersion: tls.VersionTLS12},
			ForceAttemptHTTP2:   true,
			MaxIdleConns:        4,
			IdleConnTimeout:     60 * time.Second,
			TLSHandshakeTimeout: upstreamTimeout,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	return up, nil
}

// dial connects to a bootstrap address directly: resolving the resolver's name would re-enter the tunnel.
// With ifIndex set the socket is bound to the tunnel interface, so the query travels inside the VPN.
func (u *upstream) dial(ctx context.Context, port int) (net.Conn, error) {
	last := errors.New("no resolver address is reachable")
	for _, ip := range u.bootstrap {
		ip := ip
		d := net.Dialer{Timeout: upstreamTimeout}
		if u.ifIndex != 0 {
			d.Control = func(_, _ string, c syscall.RawConn) error {
				var serr error
				if err := c.Control(func(fd uintptr) {
					if ip.To4() != nil {
						serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, u.ifIndex)
					} else {
						serr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, u.ifIndex)
					}
				}); err != nil {
					return err
				}
				return serr
			}
		}
		conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(ip.String(), strconv.Itoa(port)))
		if err == nil {
			return conn, nil
		}
		last = err
	}
	return nil, last
}

func (u *upstream) exchange(ctx context.Context, q []byte) ([]byte, error) {
	if cached, ok := u.cache.get(q); ok {
		return cached, nil
	}
	var reply []byte
	var err error
	if u.dot {
		reply, err = u.exchangeDoT(ctx, q)
	} else {
		reply, err = u.exchangeDoH(ctx, q)
	}
	if err != nil {
		return nil, err
	}
	if len(reply) < 12 || reply[0] != q[0] || reply[1] != q[1] || reply[2]&0x80 == 0 {
		return nil, errors.New("invalid upstream reply")
	}
	if len(reply) > maxPayload {
		// Too big for one tunnel packet: answer with the truncated flag and just the question, so the client sees a real
		// reply (and may retry elsewhere) rather than a SERVFAIL for a perfectly good answer.
		if _, end, ok := question(q); ok {
			return append([]byte{q[0], q[1], 0x83, 0x80, 0, 1, 0, 0, 0, 0, 0, 0}, q[12:end]...), nil
		}
		return nil, errors.New("upstream reply does not fit the tunnel MTU")
	}
	u.cache.put(q, reply)
	return reply, nil
}

func (u *upstream) exchangeDoH(ctx context.Context, q []byte) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+u.host+u.path, bytes.NewReader(q))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")
	resp, err := u.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(resp.Header.Get("Content-Type"), "application/dns-message") {
		return nil, errors.New("resolver did not return a DNS message")
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxUpstreamReply+1))
	if err != nil || len(body) > maxUpstreamReply {
		return nil, errors.New("resolver reply is unreadable or too large")
	}
	return body, nil
}

func (u *upstream) exchangeDoT(ctx context.Context, q []byte) ([]byte, error) {
	conn, err := u.dial(ctx, 853)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(upstreamTimeout))
	tc := tls.Client(conn, &tls.Config{ServerName: u.host, MinVersion: tls.VersionTLS12})
	if err := tc.HandshakeContext(ctx); err != nil {
		return nil, err
	}
	frame := make([]byte, 2+len(q))
	binary.BigEndian.PutUint16(frame, uint16(len(q)))
	copy(frame[2:], q)
	if _, err := tc.Write(frame); err != nil {
		return nil, err
	}
	var header [2]byte
	if _, err := io.ReadFull(tc, header[:]); err != nil {
		return nil, err
	}
	n := int(binary.BigEndian.Uint16(header[:]))
	if n < 12 {
		return nil, errors.New("invalid DoT frame")
	}
	reply := make([]byte, n)
	if _, err := io.ReadFull(tc, reply); err != nil {
		return nil, err
	}
	return reply, nil
}

// maybeWrapDNS installs the interceptor when the app configured one before starting the tunnel.
func maybeWrapDNS(dev tun.Device) (tun.Device, error) {
	pendingMu.Lock()
	cfg := pending
	pendingMu.Unlock()
	activeMu.Lock()
	active = nil
	activeMu.Unlock()
	if cfg == nil {
		return dev, nil
	}
	f, err := newDNSFilter(*cfg, dev)
	if err != nil {
		return nil, err
	}
	activeMu.Lock()
	active = f
	activeMu.Unlock()
	return &filterTUN{Device: dev, f: f}, nil
}

func clearActiveDNS() {
	activeMu.Lock()
	active = nil
	activeMu.Unlock()
}
