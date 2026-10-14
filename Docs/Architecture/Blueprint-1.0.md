# VayuSetu — Complete Enterprise Architecture & Capability Specification
**Native macOS VPN + Encrypted DNS + Network Security Platform**

**Version:** Architecture Blueprint 1.0  
**Platform:** macOS 26+ initially; iOS planned  
**Brand:** R3dby  
**Project location:** `~/Documents/VayuSetu`  
**VPN support:** Provider-independent, WireGuard initially  
**DNS support:** Provider-independent, encrypted DNS  
**Architecture:** Modular monolith with a privileged packet tunnel extension  
**Design priorities:** Security, correctness, performance, reliability, extensibility

This is the proposed **complete target architecture**, including capabilities for initial development and future releases. It is not a statement that these features have been implemented.

The central design principle is that **VayuSetu must verify actual network behavior rather than merely display configured settings**.

---

## 1. Product vision

VayuSetu is a native VPN and DNS management application that lets users independently configure:

- Their VPN provider and connection profile.
- Their encrypted DNS provider.
- How DNS requests travel relative to the VPN.
- IPv4 and IPv6 routing.
- Network privacy and leak protection.
- Connection recovery and automation.
- Network diagnostics and monitoring.
- Advanced routing and security policies.

The application should work with compatible VPN providers without embedding provider-specific assumptions into the core architecture.

### Primary objectives

| Objective | Requirement |
|---|---|
| Privacy | Protect intended network traffic and prevent unauthorized fallback |
| Security | Enforce validated network policies |
| Compatibility | Support multiple VPN and DNS providers |
| Reliability | Recover safely from network interruptions |
| Performance | Minimize latency, CPU usage, and battery consumption |
| Transparency | Show verified connection, DNS, and routing status |
| Extensibility | Add protocols and providers through defined interfaces |
| Maintainability | Modular Swift packages, typed contracts, automated tests |
| Portability | Reuse domain logic across macOS and iOS |
| Distribution | Signed, notarized macOS application |

---

# 2. System architecture

```text
┌────────────────────────────────────────────────────────────────────┐
│                           VayuSetu.app                             │
│                          Native SwiftUI                            │
│                                                                    │
│ Dashboard       VPN Profiles       DNS Profiles       Routing      │
│ Traffic Monitor Diagnostics        Logs               Settings     │
├────────────────────────────────────────────────────────────────────┤
│                       PRESENTATION LAYER                           │
│                                                                    │
│ Feature Views / ViewModels                                         │
│ Application State Store                                            │
│ Navigation Coordinator                                             │
│ Connection Status Presenter                                        │
│ Diagnostics Presenter                                              │
├────────────────────────────────────────────────────────────────────┤
│                       APPLICATION LAYER                            │
│                                                                    │
│ Connection Orchestrator                                            │
│ VPN Profile Manager                                                │
│ DNS Profile Manager                                                │
│ Routing Policy Manager                                             │
│ Network Health Coordinator                                         │
│ Diagnostics Coordinator                                            │
│ Configuration Manager                                              │
│ Automation Manager                                                 │
├────────────────────────────────────────────────────────────────────┤
│                          DOMAIN LAYER                              │
│                                                                    │
│ Connection State Machine                                           │
│ VPN / DNS Domain Models                                            │
│ Routing Policy Models                                              │
│ IPv4 / IPv6 Capability Models                                      │
│ Security Invariants                                                │
│ Policy Compiler and Validator                                      │
│ Error Taxonomy                                                     │
├────────────────────────────────────────────────────────────────────┤
│                      INFRASTRUCTURE LAYER                          │
│                                                                    │
│ Network Extension Client                                           │
│ Keychain Repository                                                │
│ Configuration Repository                                           │
│ Network Path Monitor                                               │
│ Structured Logging                                                 │
│ Diagnostic Report Generator                                        │
│ Secure App–Extension Communication                                 │
└───────────────────────────────┬────────────────────────────────────┘
                                │
                       Network Extension
                                │
┌───────────────────────────────▼────────────────────────────────────┐
│                     PACKET TUNNEL EXTENSION                        │
│                                                                    │
│ Tunnel Lifecycle Controller                                        │
│ WireGuard Adapter                                                  │
│ VPN Transport                                                      │
│ IPv4 / IPv6 Route Configuration                                    │
│ DNS Transport Policy                                               │
│ Network Settings Coordinator                                       │
│ Tunnel Health Monitoring                                           │
│ Traffic Statistics                                                 │
│ Failure Recovery                                                   │
└───────────────────────────────┬────────────────────────────────────┘
                                │
                           VPN Provider
                                │
                             Internet
```

### Separation of responsibilities

The **SwiftUI application** handles user interaction, configuration, and diagnostics presentation.

The **application layer** coordinates workflows such as connecting, changing profiles, and applying policies.

The **domain layer** defines valid states, routing rules, and security guarantees.

The **infrastructure layer** integrates with Apple frameworks and local storage.

The **packet tunnel extension** implements the actual VPN transport and applicable network settings.

The extension should not contain UI logic, and SwiftUI should never manipulate packets directly.

---

# 3. VPN provider architecture

VayuSetu must be independent of individual VPN vendors.

### Provider management capabilities

| Capability | Description | Priority |
|---|---|---|
| Multiple VPN profiles | Store several configurations | V1 |
| Multiple VPN providers | Manage profiles from different providers | V1 |
| WireGuard import | Import standard `.conf` files | V1 |
| Manual configuration | Enter compatible tunnel settings | V1 |
| Profile validation | Validate required fields and addressing | V1 |
| Profile selection | Choose the active connection | V1 |
| Profile editing | Update supported settings | V1 |
| Profile duplication | Create variations safely | V1 |
| Profile deletion | Remove profiles and associated secrets | V1 |
| Secure import/export | Redacted exports by default | V1 |
| Server endpoint selection | Choose configured endpoints | V1 |
| Server health monitoring | Measure reachability | V2 |
| Automatic server selection | Select from explicitly configured candidates | V2 |
| Provider-specific adapters | Support additional provider formats | V2 |
| Provider account integration | Optional authenticated integrations | Future |

### Provider abstraction

```text
VPN Profile Manager
        │
        ▼
VPN Configuration Validator
        │
        ▼
VPN Protocol Adapter
        │
        ├── WireGuard
        ├── IKEv2 (future)
        └── Other supported protocols (future)
        │
        ▼
Apple Network Extension
        │
        ▼
VPN Provider
```

A provider and a VPN protocol are different concepts.

A provider may support multiple protocols, while one protocol can be supported by multiple providers.

The initial architecture should support standard WireGuard profiles without requiring vendor-specific APIs.

---

# 4. VPN protocol capabilities

## Initial protocol: WireGuard

| Feature | Requirement |
|---|---|
| Private key | Secure storage and controlled access |
| Public key | Peer identity |
| Preshared key | Optional support |
| Endpoint | IPv4, IPv6, or hostname |
| AllowedIPs | IPv4/IPv6 prefix routing |
| Interface address | IPv4 and IPv6 |
| DNS configuration | Parsed but governed by selected DNS policy |
| MTU | Validated and configurable |
| PersistentKeepalive | Optional |
| Handshake monitoring | Connection health |
| Transfer statistics | Upload/download counters |
| Endpoint roaming | Network changes |
| Multiple peers | Supported where configuration semantics permit |
| Connection timeout | Explicit timeout and error |
| Controlled reconnect | Bounded retry policy |

### Future protocols

The architecture may later accommodate IKEv2/IPsec or other supported VPN technologies, but each requires its own platform integration and capability assessment.

We should not design a generic protocol interface that assumes every VPN protocol exposes identical features.

---

# 5. DNS architecture

DNS is a first-class subsystem, independent of VPN provider selection.

## Supported DNS transports

| Transport | Purpose | Priority |
|---|---|---|
| DNS-over-HTTPS (DoH) | Encrypted DNS over HTTPS | V1 |
| DNS-over-TLS (DoT) | Encrypted DNS over TLS | V2 |
| DNS-over-QUIC (DoQ) | Encrypted DNS over QUIC | Future |
| UDP/TCP DNS | Compatibility and controlled use | Limited |
| DNSSEC | Authenticated DNS data | Provider-dependent |
| DNS64 | IPv6-only network compatibility | V2 |
| mDNS | Local service discovery | Explicit policy |

### DNS provider capabilities

- Multiple DNS profiles.
- Custom DoH endpoints.
- Provider-specific authentication.
- Secure credential storage.
- Endpoint validation.
- TLS certificate verification.
- DNS provider health checks.
- DNS response-time measurement.
- Resolver verification.
- DNS filtering verification.
- Approved fallback resolvers.
- Configurable timeout policies.
- DNS cache behavior.
- DNS cache invalidation.
- A and AAAA record support.
- CNAME handling.
- HTTPS/SVCB record compatibility.
- DNSSEC status awareness.
- Split DNS policies.
- Local DNS exceptions.
- IPv4 and IPv6 DNS transport.
- DNS leak detection.

### DNS architecture

```text
DNS Profile
     │
     ▼
DNS Profile Validator
     │
     ▼
DNS Policy Compiler
     │
     ▼
DNS Transport Strategy
     │
     ├── Direct Encrypted DNS
     │
     └── VPN-Carried Encrypted DNS
     │
     ▼
DNS Verification
     │
     ▼
DNS Health Status
```

**Implementation constraint:** We must evaluate Apple's DNS configuration APIs and their interaction with packet tunnels before selecting the final DNS transport mechanism.

A custom DNS proxy should be introduced only when required by verified platform limitations.

---

# 6. Required DNS/VPN routing modes

These are the two modes you specified.

## Mode A — DNS → VPN

```text
               VayuSetu
                  │
          DNS lookup required
                  │
                  ▼
            DNS Provider
          Direct encrypted DNS
                  │
                  ▼
            Resolved IP
                  │
                  ▼
             VPN Tunnel
                  │
                  ▼
             VPN Provider
                  │
                  ▼
               Internet
```

**Actual packet paths:**

| Traffic | Path |
|---|---|
| DNS queries | Device → DNS Provider directly |
| DNS responses | DNS Provider → Device |
| Website traffic | Device → VPN Provider → Website |
| Streaming | Device → VPN Provider → Destination |
| Downloads | Device → VPN Provider → Destination |

DNS resolves the destination before the application connects, but DNS does not forward the subsequent website packets.

### Requirements

- Explicit resolver transport routing.
- Restricted DNS exceptions.
- Secure DoH bootstrap.
- TLS validation.
- IPv4/IPv6 consistency.
- No arbitrary HTTPS bypass.
- DNS routing verification.
- Fail-closed behavior when the approved resolver is unavailable.

**Status:** Advanced mode requiring a macOS feasibility prototype.

## Mode B — VPN → DNS

```text
               VayuSetu
                  │
                  ▼
              VPN Tunnel
                  │
                  ▼
             VPN Provider
                  │
          ┌───────┴───────┐
          │               │
          ▼               ▼
     DNS Provider      Internet
          │
          ▼
     DNS response
```

**Actual packet paths:**

| Traffic | Path |
|---|---|
| DNS queries | Device → VPN → DNS Provider |
| DNS responses | DNS Provider → VPN → Device |
| Website traffic | Device → VPN → Website |
| Streaming | Device → VPN → Destination |
| Downloads | Device → VPN → Destination |

### Requirements

- DNS traffic carried through the tunnel.
- Approved resolver verification.
- DNS leak prevention.
- No unauthorized fallback.
- IPv4/IPv6 DNS consistency.
- Network-change revalidation.

**Recommended default:** VPN → DNS.

### Separate future capability: multihop

If we want every packet to pass through two sequential gateways, that is a different architecture:

```text
Device
   │
   ▼
VPN Gateway A
   │
   ▼
VPN / Proxy Gateway B
   │
   ▼
Internet
```

A standard DNS resolver cannot serve as Gateway B.

Multihop should remain a separate future module, not be conflated with DNS routing.

---

# 7. IPv4 architecture

### Required capabilities

- IPv4 interface addressing.
- IPv4 default routing.
- `0.0.0.0/0` full-tunnel support.
- IPv4 route inclusion and exclusion.
- IPv4 tunnel endpoint reachability.
- IPv4 DNS transport.
- IPv4 public exit verification.
- IPv4 leak detection.
- IPv4 routing diagnostics.
- NAT compatibility.
- IPv4 packet statistics.
- Network-change handling.

The system must validate overlapping routes and prevent accidental routing loops.

---

# 8. IPv6 architecture

IPv6 must be treated as a security requirement, not an optional afterthought.

### Required capabilities

- IPv6 availability detection.
- IPv6-only network detection.
- Dual-stack network detection.
- IPv6 tunnel capability validation.
- IPv6 interface configuration.
- IPv6 default route `::/0`.
- IPv6 route inclusion and exclusion.
- IPv6 DNS support.
- IPv6 leak detection.
- IPv6 public exit verification.
- ICMPv6 compatibility.
- Path MTU Discovery.
- NAT64/DNS64 compatibility testing.
- IPv6 network-change handling.

### IPv6 security policy

```text
IPv6 packet
    │
    ▼
Can selected VPN configuration carry IPv6?
    │
    ├── Yes → Route through VPN
    │
    └── No  → Apply verified restriction
                  │
                  ▼
             No unintended
             IPv6 fallback
```

If the platform cannot enforce the requested protection, the app must disclose that limitation and avoid reporting a verified secure state.

---

# 9. Transport and networking protocols

VayuSetu should preserve compatibility with modern network traffic.

| Protocol / technology | Capability |
|---|---|
| TCP | Reliable application connections |
| UDP | Datagram traffic |
| ICMP | IPv4 network diagnostics and errors |
| ICMPv6 | IPv6 control and error signaling |
| QUIC | UDP-based encrypted transport |
| HTTP/2 | Application compatibility |
| HTTP/3 | QUIC-based web traffic |
| TLS 1.2/1.3 | Secure application transport compatibility |
| WebSocket | Persistent connections |
| WebRTC | Real-time communications and leak testing |
| NAT44 | IPv4 network translation compatibility |
| NAT64 | IPv6-only network compatibility |
| DNS64 | IPv6 synthesized DNS responses |
| MTU | Packet size configuration |
| PMTUD | Path MTU discovery |
| Happy Eyeballs | IPv4/IPv6 connection selection |
| Multicast | Local-network policy |
| mDNS | Local device discovery |
| Broadcast | LAN compatibility |
| DHCP | Underlying network configuration awareness |
| SLAAC | IPv6 address configuration awareness |

These are compatibility requirements, not a proposal to reimplement operating-system protocol stacks.

---

# 10. Routing policy engine

The routing engine should be policy-driven.

### Inputs

```text
VPN Profile
DNS Profile
DNS Routing Mode
IPv4 Policy
IPv6 Policy
Full/Split Tunnel Policy
LAN Access Policy
Security Policy
Network Capabilities
```

### Processing pipeline

```text
Configuration
     │
     ▼
Schema Validation
     │
     ▼
Capability Detection
     │
     ▼
Security Invariant Validation
     │
     ▼
Policy Compilation
     │
     ▼
Platform Configuration
     │
     ▼
Apply Network Settings
     │
     ▼
Runtime Verification
```

### Routing capabilities

| Capability | Priority |
|---|---|
| Full tunnel | V1 |
| IPv4 default route | V1 |
| IPv6 default route or secure restriction | V1 |
| DNS transport selection | V1 |
| VPN endpoint routing | V1 |
| DNS destination exceptions | V1 feasibility validation |
| LAN access policy | V1 |
| Route conflict detection | V1 |
| Route verification | V1 |
| Split tunneling by destination | V2 |
| Domain-based split DNS | V2 |
| Per-app routing | Future, subject to platform support |
| Trusted-network routing | V2 |
| Multihop routing | Future |
| Policy simulation | V2 |
| Policy rollback | V1 |

### Policy compiler

The compiler must reject unsupported or contradictory configurations.

For example, a policy that requires direct DNS while simultaneously prohibiting all non-VPN traffic cannot be accepted without a clearly defined exception.

---

# 11. Security and leak prevention

### Required security controls

| Control | Requirement |
|---|---|
| IPv4 leak prevention | No unauthorized IPv4 bypass |
| IPv6 leak prevention | No unauthorized IPv6 bypass |
| DNS leak prevention | Only approved resolver paths |
| Tunnel failure protection | No silent traffic fallback |
| DNS failure protection | No silent resolver fallback |
| Reconnection protection | Preserve policy during transitions |
| Keychain storage | Protect VPN and DNS credentials |
| TLS verification | Authenticate encrypted DNS endpoints |
| Configuration validation | Reject malformed or unsafe profiles |
| Secure IPC | Protect app–extension communication |
| Log redaction | Prevent secret exposure |
| Secure exports | Redacted by default |
| Dependency security | Pin and review dependencies |
| Signed binaries | Protect release integrity |
| Network transition verification | Revalidate effective policy |
| Explicit local exceptions | Document permitted LAN/system traffic |

### Kill-switch policy

```text
Tunnel unexpectedly fails
          │
          ▼
Security policy evaluation
          │
          ▼
Apply enforceable restrictions
          │
          ▼
Attempt controlled reconnection
          │
          ├── Success → Reverify → Connected
          │
          └── Failure → Blocked / Failed
```

**Platform limitation:** Apple networking frameworks may permit certain system traffic outside a VPN. VayuSetu must document these exceptions and avoid claiming an absolute kill switch without verifying the platform's actual enforcement behavior.

---

# 12. Connection lifecycle

Use a deterministic connection state machine.

```text
DISCONNECTED
     │
     ▼
VALIDATING
     │
     ▼
PREPARING
     │
     ▼
CONNECTING
     │
     ▼
TUNNEL_ESTABLISHED
     │
     ▼
VERIFYING_IPV4
     │
     ▼
VERIFYING_IPV6
     │
     ▼
VERIFYING_DNS
     │
     ▼
VERIFYING_ROUTING
     │
     ▼
CONNECTED
```

### Additional states

- Reconnecting.
- Degraded.
- Blocked.
- Suspended.
- Disconnecting.
- Failed.

### Lifecycle requirements

- Idempotent connection requests.
- Cancellation support.
- Explicit timeouts.
- Bounded retries.
- Exponential backoff.
- Network-change recovery.
- Safe configuration changes.
- Consistent status reporting.
- Extension crash handling.
- Connection-state persistence where appropriate.

The UI must distinguish a tunnel handshake from verified internet and DNS connectivity.

---

# 13. Network reliability

### Required scenarios

| Scenario | Expected behavior |
|---|---|
| Wi-Fi disconnect | Preserve security policy |
| Wi-Fi reconnect | Reconnect and verify |
| Wi-Fi switching | Reevaluate network path |
| Ethernet switching | Reconfigure safely |
| Sleep | Maintain consistent state |
| Wake | Revalidate connectivity |
| VPN endpoint unavailable | Controlled retries |
| DNS endpoint unavailable | Apply DNS failure policy |
| IPv4-only network | Use supported transport |
| IPv6-only network | Use supported transport or report limitation |
| Dual-stack network | Enforce both address-family policies |
| Captive portal | Detect and guide recovery |
| DNS endpoint IP changes | Revalidate routing |
| Application restart | Restore intended configuration |
| Extension restart | Recover or fail safely |
| System restart | Honor startup policy |
| Clock changes | Avoid invalid timeout assumptions |

---

# 14. Network diagnostics

Diagnostics must provide independently verified results.

### Connection metrics

- VPN connection state.
- Selected VPN profile.
- VPN server endpoint.
- Last WireGuard handshake.
- Tunnel uptime.
- Public IPv4 address.
- Public IPv6 address.
- IPv4 routing status.
- IPv6 routing status.
- DNS provider.
- DNS transport mode.
- DNS verification status.
- DNS response time.
- Tunnel latency.
- Jitter.
- Packet loss.
- Upload throughput.
- Download throughput.
- Total bytes sent.
- Total bytes received.
- Configured MTU.
- Active network interface.
- Reconnection count.
- Last connection error.

### Diagnostic tests

| Test | Expected result |
|---|---|
| VPN handshake | Verified / Failed |
| IPv4 connectivity | Passed / Failed |
| IPv6 connectivity | Passed / Unsupported / Failed |
| VPN exit IP | Verified / Unverified |
| DNS resolver | Verified / Unexpected |
| DNS routing mode | Verified / Unverified |
| DNS filtering | Passed / Failed / Not tested |
| IPv4 leak | Passed / Failed / Inconclusive |
| IPv6 leak | Passed / Failed / Inconclusive |
| DNS leak | Passed / Failed / Inconclusive |
| MTU | Validated / Potential issue |
| Packet loss | Measured value |
| Network quality | Measured result |
| Reconnection | Successful / Failed |

The diagnostics system should support controlled test destinations, timestamps, test methodology, and evidence.

A public-IP website alone is insufficient to prove complete leak prevention.

---

# 15. Traffic monitoring

### V1 capabilities

- Live upload rate.
- Live download rate.
- Session data usage.
- Total transmitted bytes.
- Total received bytes.
- Connection duration.
- Connection history.
- VPN handshake age.
- DNS query latency.
- Network health indicators.

### Future capabilities

- Historical traffic charts.
- Network quality trends.
- Per-profile usage statistics.
- DNS performance comparisons.
- Connection reliability reports.
- Configurable usage alerts.

Per-application traffic accounting requires separate feasibility analysis and should not be assumed available from a packet tunnel alone.

---

# 16. Storage architecture

| Information | Storage |
|---|---|
| VPN private keys | Keychain |
| VPN preshared keys | Keychain |
| DNS credentials | Keychain |
| VPN profile metadata | Versioned local repository |
| DNS profile metadata | Versioned local repository |
| Routing policies | Versioned local repository |
| UI preferences | UserDefaults / settings repository |
| Diagnostic history | Bounded local storage |
| Application logs | OSLog |
| Exported reports | User-selected location |

### Storage requirements

- Schema versioning.
- Atomic writes.
- Configuration migrations.
- Corruption detection.
- Validation before persistence.
- Safe rollback.
- Secret redaction.
- Secure import/export.
- No hardcoded credentials.

---

# 17. Logging and observability

Use structured logging through Apple's `OSLog`.

### Categories

```text
application
connection
vpn
wireguard
dns
routing
ipv4
ipv6
security
diagnostics
network
configuration
```

### Capabilities

- Severity levels.
- Correlation IDs.
- Connection session IDs.
- Timestamped events.
- Error categorization.
- Diagnostic filtering.
- Bounded retention.
- Sensitive-data redaction.
- Sanitized report generation.

No browsing history or sensitive DNS query logging by default.

---

# 18. Native macOS interface

Retain the established VayuSetu design:

**Deep-black background, frosted glass panels, subtle borders, collapsible sidebar, and one prominent connection button.**

### Main screens

| Screen | Capabilities |
|---|---|
| Dashboard | Connect/disconnect, status, live metrics |
| VPN Profiles | Import, manage, select configurations |
| DNS Profiles | Manage encrypted DNS providers |
| Routing | DNS order, IPv4/IPv6, LAN policies |
| Traffic | Throughput and session statistics |
| Diagnostics | Network, DNS, VPN, leak tests |
| Logs | Filterable diagnostic events |
| Settings | Startup, security, reconnect, updates |

### Additional UI capabilities

- Menu bar controls.
- Connection status notifications.
- Keyboard shortcuts.
- Native accessibility.
- VoiceOver labels.
- Dynamic layout scaling.
- Dark appearance.
- Connection history.
- Clear error recovery actions.
- Explicit verified/unverified indicators.

The production UI must never display simulated metrics as actual measurements.

---

# 19. Automation capabilities

| Capability | Priority |
|---|---|
| Connect on app launch | V1 |
| Connect at login | V1 |
| Automatic reconnect | V1 |
| Reconnect after wake | V1 |
| Reconnect after network change | V1 |
| Restore selected VPN profile | V1 |
| Restore selected DNS profile | V1 |
| Trusted Wi-Fi policies | V2 |
| Network-specific routing profiles | V2 |
| Scheduled connection policies | V2 |
| Automatic provider selection | Future |
| Configurable security profiles | V2 |

Automatic behavior must respect the user's selected security policy.

---

# 20. Security engineering

### Threat model

VayuSetu must account for:

- VPN tunnel interruption.
- DNS bypass.
- IPv6 bypass.
- Malicious profile imports.
- Credential leakage.
- Incorrect routing exceptions.
- Untrusted networks.
- DNS server impersonation.
- Extension crashes.
- Network transition race conditions.
- Unsafe configuration rollback.
- Dependency compromise.
- Sensitive diagnostic exports.

### Engineering controls

- Least-privilege extension design.
- Secure credential storage.
- TLS certificate validation.
- Validated configuration schemas.
- Explicit policy compilation.
- Secure app–extension communication.
- Dependency version pinning.
- Static analysis.
- Secret scanning.
- Security regression testing.
- Signed and notarized releases.
- Documented platform limitations.

---

# 21. Performance engineering

### Requirements

- Efficient packet processing.
- Minimal packet copying.
- Bounded buffers.
- Nonblocking UI.
- Swift Concurrency for application workflows.
- Controlled diagnostic polling.
- Rate-limited UI updates.
- Bounded log retention.
- Low idle CPU usage.
- Low memory overhead.
- Battery-conscious monitoring.
- Reliable long-running sessions.

### Performance tests

- Large downloads.
- Sustained uploads.
- High-concurrency connections.
- TCP throughput.
- UDP throughput.
- HTTP/3 compatibility.
- DNS-heavy workloads.
- High-latency networks.
- Packet loss.
- Long-running tunnels.
- Sleep/wake recovery.
- Memory growth.
- CPU utilization.
- Battery impact.

---

# 22. Testing strategy

| Layer | Tests |
|---|---|
| Unit | Models, validators, state machine |
| Contract | App–extension communication |
| Integration | VPN, DNS, routing, storage |
| Network | Real tunnel and resolver behavior |
| Security | Leaks, fallback, credential handling |
| Reliability | Reconnection and network transitions |
| Performance | CPU, memory, throughput, latency |
| UI | Navigation, controls, state presentation |
| Installation | Signing, entitlements, clean install |
| Regression | Previously identified failures |

### Release-blocking conditions

VayuSetu must not claim production readiness if:

- DNS routing behavior cannot be verified.
- IPv6 bypasses the intended policy.
- Unexpected VPN failure causes prohibited fallback.
- DNS silently changes to an unauthorized resolver.
- Sensitive credentials appear in logs.
- Connection-state reporting is misleading.
- Route changes leave inconsistent network settings.
- A signed release cannot be installed and operated reliably.

---

# 23. CI/CD and distribution

### Pipeline

```text
Source Control
      │
      ▼
Code Review
      │
      ▼
Formatting / Static Analysis
      │
      ▼
Unit Tests
      │
      ▼
Contract Tests
      │
      ▼
Integration Tests
      │
      ▼
Build
      │
      ▼
Security Validation
      │
      ▼
Network Test Matrix
      │
      ▼
Signed Release Candidate
      │
      ▼
Notarization
      │
      ▼
DMG Distribution
```

### Distribution capabilities

- Signed `.app`.
- Signed Network Extension.
- Correct provisioning and entitlements.
- Hardened runtime where applicable.
- Apple notarization.
- Installable `.dmg`.
- Versioned releases.
- Release notes.
- Secure update strategy.
- Crash and error reporting that preserves user privacy.

A paid Apple Developer membership and appropriate capabilities will be needed for relevant signing and distribution workflows.

---

# 24. Project structure

All project files should live under:

`~/Documents/VayuSetu`

```text
VayuSetu/
│
├── VayuSetu.xcworkspace
│
├── Apps/
│   ├── macOS/
│   │   ├── App/
│   │   ├── Features/
│   │   │   ├── Dashboard/
│   │   │   ├── VPNProfiles/
│   │   │   ├── DNSProfiles/
│   │   │   ├── Routing/
│   │   │   ├── Traffic/
│   │   │   ├── Diagnostics/
│   │   │   ├── Logs/
│   │   │   └── Settings/
│   │   └── Resources/
│   │
│   └── iOS/
│       ├── App/
│       ├── Features/
│       └── Resources/
│
├── Extensions/
│   ├── macOSPacketTunnel/
│   └── iOSPacketTunnel/
│
├── Packages/
│   ├── VayuSetuCore/
│   ├── VayuSetuVPN/
│   ├── VayuSetuDNS/
│   ├── VayuSetuRouting/
│   ├── VayuSetuSecurity/
│   ├── VayuSetuDiagnostics/
│   ├── VayuSetuStorage/
│   └── VayuSetuObservability/
│
├── Tests/
│   ├── Unit/
│   ├── Contract/
│   ├── Integration/
│   ├── Network/
│   ├── Security/
│   ├── Reliability/
│   ├── Performance/
│   └── UI/
│
├── Config/
│   ├── Development/
│   ├── Testing/
│   ├── Release/
│   └── Entitlements/
│
├── Docs/
│   ├── Architecture/
│   ├── ADR/
│   ├── API-Contracts/
│   ├── Security/
│   ├── Testing/
│   └── Release/
│
├── Scripts/
│
├── .github/
│   └── workflows/
│
├── .gitignore
├── README.md
└── LICENSE
```

---

# 25. Complete capability roadmap

The architecture supports the following release stages.

| Area | V1 | V2 | Future |
|---|---|---|---|
| Native macOS application | ✓ | | |
| WireGuard | ✓ | | |
| Multiple VPN providers | ✓ | | |
| Multiple VPN profiles | ✓ | | |
| Custom DNS providers | ✓ | | |
| DoH | ✓ | | |
| DoT | | ✓ | |
| DoQ | | | ✓ |
| IPv4 | ✓ | | |
| IPv6 protection | ✓ | | |
| Dual-stack networking | ✓ | | |
| TCP/UDP transport | ✓ | | |
| QUIC compatibility | ✓ | | |
| Full-tunnel routing | ✓ | | |
| DNS → VPN | Feasibility gate | | |
| VPN → DNS | ✓ | | |
| Destination split tunneling | | ✓ | |
| Per-app routing | | | Feasibility |
| Split DNS | | ✓ | |
| Kill-switch policy | ✓ | | |
| DNS leak protection | ✓ | | |
| IPv6 leak protection | ✓ | | |
| Auto reconnect | ✓ | | |
| Sleep/wake recovery | ✓ | | |
| Network-change recovery | ✓ | | |
| Menu bar controls | ✓ | | |
| Live traffic statistics | ✓ | | |
| Network diagnostics | ✓ | | |
| Sanitized diagnostic reports | ✓ | | |
| Trusted Wi-Fi rules | | ✓ | |
| Advanced network monitoring | | ✓ | |
| Network-specific profiles | | ✓ | |
| Multihop VPN/proxy | | | Feasibility |
| iOS application | | ✓ | |
| Additional VPN protocols | | | ✓ |
| Automated server selection | | ✓ | |
| Local configuration backup | ✓ | | |
| Secure configuration export | ✓ | | |
| Signed macOS DMG | ✓ | | |
| Automated release pipeline | ✓ | | |

Here, **V1 means intended release scope**, not guaranteed feasibility. Any security-sensitive feature must pass its acceptance tests before being marked supported.

---

# 26. Implementation milestones

| Milestone | Deliverable | Acceptance criteria |
|---|---|---|
| M0 — Architecture | ADRs, threat model, feasibility plan | Key decisions reviewed |
| M1 — Foundation | Xcode workspace, modules, CI | Clean reproducible build |
| M2 — VPN | Working provider-independent WireGuard tunnel | Connection and exit verified |
| M3 — DNS | Encrypted DNS integration | Resolver and filtering verified |
| M4 — Routing | Both DNS transport policies | Packet-level evidence for each supported mode |
| M5 — IP Security | IPv4/IPv6 protection | Leak and failure tests pass |
| M6 — Reliability | Reconnection and network recovery | Transition tests pass |
| M7 — Diagnostics | Verified health and reports | No misleading statuses |
| M8 — UI Integration | Complete native interface | End-to-end workflows pass |
| M9 — Hardening | Security and performance | Release-blocking tests pass |
| M10 — Distribution | Signed, notarized DMG | Clean-device installation succeeds |

### Architecture decisions to finalize before coding

The initial engineering documents should establish:

1. **ADR-001:** Native SwiftUI and Network Extension architecture.
2. **ADR-002:** Provider-independent VPN abstraction.
3. **ADR-003:** WireGuard implementation and dependency strategy.
4. **ADR-004:** DNS transport selection and routing feasibility.
5. **ADR-005:** IPv4/IPv6 routing and failure policy.
6. **ADR-006:** Kill-switch guarantees and Apple platform exceptions.
7. **ADR-007:** Keychain storage and app–extension communication.
8. **ADR-008:** Connection state machine.
9. **ADR-009:** Diagnostics methodology and evidence requirements.
10. **ADR-010:** macOS/iOS shared-code boundaries.

---

## Final architecture recommendation

**VayuSetu should be built as a provider-independent, native Apple networking platform with one authoritative connection controller, a policy-driven routing engine, a WireGuard packet tunnel extension, independently verified encrypted DNS, and explicit IPv4/IPv6 security guarantees.**

The implementation order should be:

**Architecture and feasibility → Working VPN tunnel → Encrypted DNS → Routing verification → IPv4/IPv6 security → Reliability → Diagnostics → UI integration → Signed release.**

The most important engineering constraint is that **DNS → VPN, VPN → DNS, kill-switch behavior, and IPv6 protection must be proven on real macOS networking configurations**. They cannot be considered complete solely because the configuration or interface appears correct.

This gives VayuSetu a comprehensive technical foundation without tying it to any particular VPN or DNS provider.