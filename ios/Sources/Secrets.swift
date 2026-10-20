import Foundation
import Security
import CryptoKit
import os

enum Vault {
    #if os(macOS)
    static let service = Bundle.main.bundleIdentifier ?? "app.vayusetu.macos"
    #else
    static let service = "app.vayusetu.ios"
    #endif
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "VayuKeychainGroup") as? String }
    static func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let group, !group.isEmpty {
            q[kSecAttrAccessGroup as String] = group
            #if os(macOS)
            q[kSecUseDataProtectionKeychain as String] = true
            #endif
        }
        return q
    }
    static func put(_ data: Data, account: String) throws {
        let q = query(account)
        let fields: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound { var add = q; fields.forEach { add[$0] = $1 }; try check(SecItemAdd(add as CFDictionary, nil)) }
        else { try check(status) }
    }
    static func get(_ account: String) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound, group != nil {
            // Items saved before the Keychain group existed live in the ordinary (login) Keychain, so search it without the group
            // and without the data-protection restriction, then move the item into the group.
            q.removeValue(forKey: kSecAttrAccessGroup as String)
            #if os(macOS)
            q.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            #endif
            let legacy = SecItemCopyMatching(q as CFDictionary, &result)
            if legacy == errSecItemNotFound { return nil }; try check(legacy)
            if let data = result as? Data { try put(data, account: account); return data }
            return nil
        }
        if status == errSecItemNotFound { return nil }; try check(status); return result as? Data
    }
    static func reference(_ account: String) throws -> Data {
        var q = query(account); q[kSecReturnPersistentRef as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; try check(SecItemCopyMatching(q as CFDictionary, &result))
        guard let data = result as? Data else { throw AppIssue(message: "Keychain reference unavailable.") }; return data
    }
    static func readReference(_ reference: Data) throws -> Data {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecValuePersistentRef as String: reference, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        #if os(macOS)
        if group != nil { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        var result: CFTypeRef?; try check(SecItemCopyMatching(q as CFDictionary, &result))
        guard let data = result as? Data else { throw AppIssue(message: "Tunnel configuration is missing from Keychain.") }; return data
    }
    static func recoverableConfigurations() throws -> [(String, Data)] {
        var request = query("unused")
        request.removeValue(forKey: kSecAttrAccount as String)
        // The OS restricts this to groups in the app's signed entitlement. Service
        // scope excludes credentials belonging to unrelated apps.
        request.removeValue(forKey: kSecAttrAccessGroup as String)
        request[kSecReturnAttributes as String] = true
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let items = result as? [[String:Any]], items.count <= 100 else { throw AppIssue(message: "Saved credential recovery exceeds its safety limit.") }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data, data.count <= 128_000,
                  UUID(uuidString: account.hasPrefix("dns-") ? String(account.dropFirst(4)) : account) != nil else { return nil }
            return (account,data)
        }
    }
    static func delete(_ account: String) throws {
        var allGroups = query(account); allGroups.removeValue(forKey: kSecAttrAccessGroup as String)
        let status = SecItemDelete(allGroups as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw AppIssue(message: "Keychain operation failed (\(status)). Unlock this device and check the app's signing configuration.") }
    }
}

struct TunnelSecret: Codable {
    let wireguard: String
    let resolver: String
    let mode: RoutingMode
    var requireNativeIPv6: Bool? = nil
    var configurationVersion: Int? = 1
    var resolverBootstrapAddresses: [String]? = nil
    var requireStrictRouting: Bool? = nil
    /// nil = WireGuard. "dnsOnly" = the local DNS tunnel (ADR-011); `wireguard` is then empty.
    var runtime: String? = nil
    /// Local DNS tunnel only: apply the compiled VayuSetu filter snapshot before forwarding upstream.
    var filtering: Bool? = nil
    /// WireGuard + VayuSetu DNS: send the filter's upstream queries outside the VPN instead of through it.
    /// Default (nil/false) keeps them inside the tunnel. Use only if DNS fails to resolve inside the VPN.
    var dnsUpstreamDirect: Bool? = nil
    /// false = VPN Only: no resolver is applied and the imported profile's own DNS settings stay in force. nil/true = apply `resolver`.
    var applyResolver: Bool? = nil
    /// A second encrypted resolver, used only when the first one does not answer.
    var fallbackResolver: String? = nil
    var fallbackBootstrapAddresses: [String]? = nil
}

enum RoutingMode: String, Codable, CaseIterable, Identifiable {
    case dnsFirst, vpnFirst
    var id: String { rawValue }
    var title: String { self == .dnsFirst ? "Independent DNS alongside VPN" : "DNS through VPN" }
    var supported: Bool { self == .vpnFirst }
    static let directDNSUnavailable = "Independent DNS alongside VPN is unavailable: selective DNS bypass is not supported by this adapter. Use DNS through VPN."
    var explanation: String { self == .dnsFirst ? "Advanced mode requires verified DNS-only bypass and is currently unavailable." : "System DNS and website connections use your WireGuard VPN. Runtime paths still require verification." }
}
/// DNS transport selection is separate from filtering and from independent verification.
enum DNSManagementMode: String, CaseIterable, Identifiable {
    case system = "System DNS", encrypted = "Encrypted DNS", vpn = "VPN-Managed DNS"
    var id: String { rawValue }
    /// `localDNS`: VayuSetu's own DNS-only tunnel (ADR-011) is connected; it is the encrypted-DNS mode.
    static func observed(vpnConnected: Bool, localDNS: Bool = false, dnsEnabled: Bool?, foreign: Bool) -> Self? {
        if localDNS { return .encrypted }
        if vpnConnected { return .vpn }
        guard !foreign, let dnsEnabled else { return nil }
        return dnsEnabled ? .encrypted : .system
    }
    func needsChange(current: Self?, hasSavedDNS: Bool, resolverMatches: Bool) -> Bool {
        switch self {
        case .system: return current != .system
        case .encrypted:
            // Encrypted DNS is the local tunnel: a leftover iOS DNS profile never means "awaiting activation".
            return current != .encrypted || !resolverMatches
        case .vpn: return current != .vpn
        }
    }
}

/// Matches configuration identity without logging or exposing personalized resolver URLs.
/// A match is configuration evidence only, never proof of active query transport.
enum DNSConfigurationIdentity {
    // Internal comparison only. Never display or export a personalized URL or its digest.
    static func fingerprint(_ endpoint: String) -> String? {
        guard let url = try? DNSService.endpoint(endpoint) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased(); components.host = components.host?.lowercased()
        guard let canonical = components.url else { return nil }
        return SHA256.hash(data: Data(canonical.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func matchesAccepted(_ policy: AppliedTunnelPolicy?, endpoint: String) -> Bool {
        guard let policy, policy.version == 1, policy.encryptedDNS, policy.allDNSDomains,
              let accepted = policy.resolverFingerprint, let preferred = fingerprint(endpoint) else { return false }
        return accepted == preferred
    }

    static func matches(endpoint: String, httpsURL: URL?, tlsServerName: String?) -> Bool {
        guard let url = try? DNSService.endpoint(endpoint) else { return false }
        if let httpsURL { return url.scheme == "https" && httpsURL == url }
        guard let tlsServerName else { return false }
        return url.scheme == "tls" && tlsServerName.lowercased() == url.host?.lowercased()
    }
}
/// Real events observed by the local DNS tunnel; nothing here is estimated.
/// `rules` is the number of rules loaded into the matcher; `blocked` counts queries it answered locally.
struct DNSOnlyCounters: Codable, Equatable { var queries: UInt64 = 0, answered: UInt64 = 0, failed: UInt64 = 0, dropped: UInt64 = 0, blocked: UInt64 = 0, threats: UInt64 = 0, rules: UInt64 = 0
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        queries = try c.decodeIfPresent(UInt64.self, forKey: .queries) ?? 0; answered = try c.decodeIfPresent(UInt64.self, forKey: .answered) ?? 0
        failed = try c.decodeIfPresent(UInt64.self, forKey: .failed) ?? 0; dropped = try c.decodeIfPresent(UInt64.self, forKey: .dropped) ?? 0
        blocked = try c.decodeIfPresent(UInt64.self, forKey: .blocked) ?? 0; threats = try c.decodeIfPresent(UInt64.self, forKey: .threats) ?? 0
        rules = try c.decodeIfPresent(UInt64.self, forKey: .rules) ?? 0
    }
    private enum Keys: String, CodingKey { case queries, answered, failed, dropped, blocked, threats, rules }
}

/// One lookup the local DNS tunnel handled. Kept in the tunnel's memory only, and only while the user has switched the lookup list on.
struct DNSQueryEntry: Codable, Identifiable, Hashable {
    var id: UInt64
    var time: Date
    var name: String
    var type: String
    /// "blocked", "answered" or "failed".
    var result: String
}

/// Compiled DNS filter rules shared by the app (writer) and the tunnel (reader). Domains are stored as
/// 64-bit FNV-1a hashes so ~150k rules need about 2 MB, well inside the extension's memory budget.
/// Precedence in the DNS path: any allow match beats any block match.
struct DNSRuleSnapshot: Equatable {
    var blockSuffix = Set<UInt64>(), blockExact = Set<UInt64>(), allowSuffix = Set<UInt64>(), allowExact = Set<UInt64>()
    /// Blocked names that belong to security lists; only used to tell a blocked threat from a blocked ad.
    var threatSuffix = Set<UInt64>(), threatExact = Set<UInt64>()
    enum Decision: Equatable { case allow, block, noMatch }
    static let magic = Data("VSDR1\0\0\0".utf8)
    static let magicV2 = Data("VSDR2\0\0\0".utf8)
    static let maximumRules = 700_000
    var count: Int { blockSuffix.count + blockExact.count + allowSuffix.count + allowExact.count }

    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { value ^= UInt64(byte); value = value &* 0x100000001b3 }
        return value
    }
    /// `name` must already be lowercase without a trailing dot.
    func decide(_ name: String) -> Decision {
        guard count > 0, !name.isEmpty else { return .noMatch }
        let exact = Self.hash(name)
        if allowExact.contains(exact) { return .allow }
        let labels = name.split(separator: ".")
        var blocked = blockExact.contains(exact)
        var index = 0
        while index < labels.count {
            let suffix = Self.hash(labels[index...].joined(separator: "."))
            if allowSuffix.contains(suffix) { return .allow }
            if blockSuffix.contains(suffix) { blocked = true }
            index += 1
        }
        return blocked ? .block : .noMatch
    }
    /// `name` must already be lowercase without a trailing dot.
    func isThreat(_ name: String) -> Bool {
        guard !threatSuffix.isEmpty || !threatExact.isEmpty, !name.isEmpty else { return false }
        if threatExact.contains(Self.hash(name)) { return true }
        let labels = name.split(separator: ".")
        for index in labels.indices where threatSuffix.contains(Self.hash(labels[index...].joined(separator: "."))) { return true }
        return false
    }
    func encoded() -> Data {
        let v2 = !threatSuffix.isEmpty || !threatExact.isEmpty
        let all = v2 ? [blockSuffix, blockExact, allowSuffix, allowExact, threatSuffix, threatExact] : [blockSuffix, blockExact, allowSuffix, allowExact]
        var data = v2 ? Self.magicV2 : Self.magic
        func append32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        for set in all { append32(set.count) }
        for set in all {
            for value in set.sorted() { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        }
        return data
    }
    static func decode(_ data: Data) throws -> DNSRuleSnapshot {
        let v2 = data.prefix(magicV2.count) == magicV2
        guard v2 || data.prefix(magic.count) == magic else { throw AppIssue(message: "DNS rule snapshot has an unknown format.") }
        let setCount = v2 ? 6 : 4
        let headerSize = magic.count + setCount * 4
        guard data.count >= headerSize else { throw AppIssue(message: "DNS rule snapshot has an unknown format.") }
        let bytes = [UInt8](data)
        func word32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        let counts = (0..<setCount).map { word32(magic.count + $0 * 4) }
        let total = counts.reduce(0, +)
        guard total <= maximumRules, data.count == headerSize + total * 8 else { throw AppIssue(message: "DNS rule snapshot is truncated or too large.") }
        var offset = headerSize
        var sets: [Set<UInt64>] = []
        for count in counts {
            var set = Set<UInt64>(minimumCapacity: count)
            for _ in 0..<count {
                var value: UInt64 = 0
                for shift in 0..<8 { value |= UInt64(bytes[offset + shift]) << UInt64(shift * 8) }
                set.insert(value); offset += 8
            }
            sets.append(set)
        }
        while sets.count < 6 { sets.append([]) }
        return DNSRuleSnapshot(blockSuffix: sets[0], blockExact: sets[1], allowSuffix: sets[2], allowExact: sets[3], threatSuffix: sets[4], threatExact: sets[5])
    }
}
/// The app writes the compiled snapshot into the App Group container; the tunnel reads it. An absent or invalid
/// file is reported as zero rules, never as protection.
enum DNSRuleStore {
    static let fileName = "dns-rules.v1.bin"
    static var url: URL? {
        if let group = Bundle.main.object(forInfoDictionaryKey: "VayuAppGroup") as? String,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) { return container.appendingPathComponent(fileName) }
        #if os(macOS)
        // The Mac tunnel is a system extension running as root, and macOS gives it no App Group container. It keeps its own copy of the
        // snapshot in its private temporary folder; the app sends the rules in a message each time it connects or the lists change.
        // (Only the tunnel uses this: the app itself always has the group container.)
        if Bundle.main.bundlePath.contains(".systemextension") { return FileManager.default.temporaryDirectory.appendingPathComponent(fileName) }
        #endif
        return nil
    }
    static func write(_ snapshot: DNSRuleSnapshot) throws {
        guard let url else { throw AppIssue(message: "App Group access is unavailable. Rebuild with the tunnel's provisioning.") }
        try snapshot.encoded().write(to: url, options: .atomic)
    }
    static func load() -> DNSRuleSnapshot {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 + 8 + DNSRuleSnapshot.maximumRules * 8,
              let data = try? Data(contentsOf: url), let snapshot = try? DNSRuleSnapshot.decode(data) else { return DNSRuleSnapshot() }
        return snapshot
    }
}
struct TunnelStats: Codable {
    var dnsCounters: DNSOnlyCounters? = nil
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var latestHandshake: Date?
    var resolverAddresses: [String] = []
    var mode: RoutingMode = .vpnFirst
    var ipv6Blocked = false
    var diagnosticVersion: Int? = nil
    var appliedPolicy: AppliedTunnelPolicy? = nil
}

/// A plain verdict on the tunnel, built only from what the system and the tunnel extension report.
/// "Healthy" means the evidence we can see is good; it never claims that no other app leaks.
struct TunnelHealth: Equatable {
    enum Verdict: String { case off, starting, healthy, degraded, down, limited }
    var verdict: Verdict
    var summary: String
    var lines: [String]
    /// - Parameters: `kind` is "WireGuard", "IKEv2" or "Local DNS"; `statsAge` is how old `stats` is, nil when none was read.
    static func assess(running: Bool, connected: Bool, kind: String, stats: TunnelStats?, statsAge: TimeInterval?, uptime: TimeInterval?, now: Date = Date()) -> TunnelHealth {
        guard running else { return .init(verdict: .off, summary: "Off", lines: ["No tunnel is running, so there is nothing to check."]) }
        guard connected else { return .init(verdict: .starting, summary: "Starting…", lines: ["iOS is still bringing the tunnel up."]) }
        let up = uptime ?? 0
        var lines = ["iOS reports the tunnel as connected" + (uptime.map { " for \(Int($0))s." } ?? ".")]
        guard kind != "IKEv2" else {
            return .init(verdict: .limited, summary: "Connected · iOS reports only", lines: lines + ["IKEv2 is run by iOS itself, so the app cannot read handshakes or counters for it."])
        }
        guard let stats, let statsAge, statsAge < 15 else {
            return .init(verdict: .starting, summary: "Connected · measuring…", lines: lines + ["Waiting for fresh numbers from the tunnel."])
        }
        var bad: [String] = [], warn: [String] = []
        if kind == "Local DNS" {
            let c = stats.dnsCounters ?? DNSOnlyCounters()
            lines.append("DNS lookups: \(c.queries) · answered \(c.answered) · failed \(c.failed) · blocked \(c.blocked)")
            if c.queries == 0 { return .init(verdict: .limited, summary: "Connected · no lookups yet", lines: lines + ["Healthy so far, but nothing has used it yet. Open a page and check again."]) }
            if c.answered == 0 && c.failed > 0 { bad.append("Every lookup failed. The resolver may be unreachable.") }
            else if c.failed * 2 > c.queries { warn.append("More than half of the lookups failed.") }
            else if c.failed > 0 { lines.append("Some lookups failed, which is normal on weak networks.") }
        } else {
            lines.append("Data: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: stats.received), countStyle: .binary)) received · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: stats.sent), countStyle: .binary)) sent")
            if let handshake = stats.latestHandshake {
                let age = max(0, now.timeIntervalSince(handshake))
                lines.append("Last handshake \(Int(age))s ago.")
                if age >= 180 { warn.append("The last handshake is old. An idle tunnel can look like this; send some traffic and check again.") }
            } else if up > 20 { bad.append("No handshake with the server yet. The server may be unreachable or the keys may not match.") }
            else { lines.append("No handshake yet.") }
            if stats.sent > 0 && stats.received == 0 && up > 20 { bad.append("Data is being sent but nothing comes back.") }
        }
        if !bad.isEmpty { return .init(verdict: .down, summary: "Not working", lines: lines + bad) }
        if !warn.isEmpty { return .init(verdict: .degraded, summary: "Connected · needs attention", lines: lines + warn) }
        return .init(verdict: .healthy, summary: "Healthy", lines: lines + ["This is what the tunnel itself reports. It does not prove that no other app leaks."])
    }
}

/// Versioned, secret-free app/extension diagnostics. Legacy statistics remain readable.
struct TunnelDiagnosticRequest: Codable {
    let version: Int
    let operation: String
    static var statistics: Data { try! JSONEncoder().encode(TunnelDiagnosticRequest(version: 1, operation: "statistics")) }
    /// Asks the local DNS tunnel to reload the compiled filter snapshot; the reply is the usual statistics.
    static var reloadRules: Data { try! JSONEncoder().encode(TunnelDiagnosticRequest(version: 1, operation: "reload-rules")) }
    /// Switches the tunnel's in-memory lookup list on or off, and asks for the entries after a given number.
    static func lookups(on: Bool) -> Data { try! JSONEncoder().encode(TunnelDiagnosticRequest(version: 1, operation: on ? "lookups-on" : "lookups-off")) }
    static func lookupsAfter(_ id: UInt64) -> Data { try! JSONEncoder().encode(TunnelDiagnosticRequest(version: 1, operation: "lookups:\(id)")) }
    static func lookupsRequest(_ data: Data) -> (on: Bool?, after: UInt64?)? {
        guard data.count <= 256, let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1 else { return nil }
        if value.operation == "lookups-on" { return (true, nil) }
        if value.operation == "lookups-off" { return (false, nil) }
        if value.operation.hasPrefix("lookups:"), let id = UInt64(value.operation.dropFirst(8)) { return (nil, id) }
        return nil
    }
    /// Mac only: the compiled snapshot itself, prefixed so the tunnel can tell it from a plain request.
    private static let rulesMagic = Data("VSRULES1".utf8)
    static func rulesMessage(_ snapshot: DNSRuleSnapshot) -> Data { rulesMagic + snapshot.encoded() }
    static func rules(in data: Data) -> DNSRuleSnapshot? {
        guard data.count > rulesMagic.count, data.prefix(rulesMagic.count) == rulesMagic else { return nil }
        return try? DNSRuleSnapshot.decode(Data(data.dropFirst(rulesMagic.count)))
    }
    static func supported(_ data: Data) -> Bool {
        if data == Data([1]) { return true }
        guard data.count <= 256, let value = try? JSONDecoder().decode(Self.self, from: data) else { return false }
        return value.version == 1 && ["statistics", "reload-rules"].contains(value.operation)
    }
    static func isReload(_ data: Data) -> Bool {
        data.count <= 256 && (try? JSONDecoder().decode(Self.self, from: data))?.operation == "reload-rules"
    }
}
struct AppliedTunnelPolicy: Codable {
    let version: Int
    let acceptedAt: Date
    let ipv4Default: Bool
    let ipv6Default: Bool
    let excludedRouteCount: Int
    let encryptedDNS: Bool
    let allDNSDomains: Bool
    let ipv6Restricted: Bool
    var resolverFingerprint: String? = nil
    var capturesBothFamilies: Bool { version == 1 && ipv4Default && ipv6Default && excludedRouteCount == 0 }
    var summary: String {
        "iOS accepted settings: \(acceptedAt.formatted(.iso8601))\nIPv4 default: \(ipv4Default) · IPv6 default: \(ipv6Default) · excluded routes: \(excludedRouteCount)\nEncrypted DNS: \(encryptedDNS) · all DNS domains: \(allDNSDomains)\nIPv6: \(ipv6Restricted ? "capture/drop requested" : "native tunnel requested")\nConfiguration evidence only. Actual packet paths and failure isolation remain unverified."
    }
}

/// Settings callbacks can arrive after stop/reassertion. Old callbacks must not
/// resurrect evidence for routes that have already been withdrawn.
final class AppliedPolicyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var value: AppliedTunnelPolicy?
    @discardableResult func invalidate() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1; value = nil; return revision
    }
    func record(_ policy: AppliedTunnelPolicy, revision expected: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if revision == expected && policy.version == 1 { value = policy }
    }
    var snapshot: AppliedTunnelPolicy? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Bounded startup breadcrumbs contain stages and numeric errors, never configuration or NSError text.
struct TunnelStartupEvent: Codable {
    enum Stage: String, Codable { case loadingSecret, validatingProfile, validatingResolver, resolverBootstrap, startingAdapter, applyingSettings, settingsAccepted, established, stopped, systemDisconnect }
    let date: Date
    let stage: Stage
    let errorDomain: String?
    let errorCode: Int?
    static let account = "diagnostics-startup-v1"
    static func sanitizedDomain(_ domain: String) -> String {
        [NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "NEVPNErrorDomain", "NEConfigurationErrorDomain", "NEAgentErrorDomain", "WireGuardAdapterError"].contains(domain) ? domain : "OtherErrorDomain"
    }
    static func record(_ stage: Stage, error: Error? = nil) {
        let ns = error.map { $0 as NSError }
        #if os(macOS)
        // A macOS system extension does not have the host app's user Keychain
        // session. Keep the extension's startup trail in unified logging rather
        // than repeatedly opening Keychain IPC and turning a diagnostic write
        // into a tunnel-start side effect.
        // The system hides NSLog values, so this uses the logger with public values. Only the stage, the error domain and code,
        // and VayuSetu's own plain-language message are written: no keys, addresses or resolver names.
        let log = Logger(subsystem: "app.vayusetu.tunnel", category: "startup")
        if let ns {
            let message = (error as? AppIssue)?.message ?? ""
            log.error("startup \(stage.rawValue, privacy: .public) failed \(sanitizedDomain(ns.domain), privacy: .public):\(ns.code, privacy: .public) \(message, privacy: .public)")
        } else {
            log.notice("startup \(stage.rawValue, privacy: .public)")
        }
        #endif
        var events: [Self] = []
        #if os(macOS)
        return
        #else
        if let data = try? Vault.get(account), data.count <= 4096 { events = (try? JSONDecoder().decode([Self].self, from: data)) ?? [] }
        events.append(Self(date: Date(), stage: stage, errorDomain: ns.map { sanitizedDomain($0.domain) }, errorCode: ns?.code))
        if let data = try? JSONEncoder().encode(Array(events.suffix(10))) { try? Vault.put(data, account: account) }
        #endif
    }
    static var report: String {
        guard let data = try? Vault.get(account), data.count <= 4096, let events = try? JSONDecoder().decode([Self].self, from: data) else { return "No startup breadcrumbs available." }
        return events.map { event in "\(event.date.formatted(.iso8601)) · \(event.stage.rawValue)" + (event.errorDomain.map { " · \($0):\(event.errorCode ?? 0)" } ?? "") }.joined(separator: "\n")
    }
}

/// Serializes start/stop enqueueing and completes startup exactly once, outside the lock.
final class TunnelLifecycleGate {
    private let lock = NSLock()
    private var token: UUID?
    private var completion: ((Error?) -> Void)?
    var currentToken: UUID? { lock.lock(); defer { lock.unlock() }; return token }
    var active: Bool { lock.lock(); defer { lock.unlock() }; return token != nil }
    func begin(_ callback: @escaping (Error?) -> Void) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard token == nil else { return nil }
        let id = UUID(); token = id; completion = callback; return id
    }
    @discardableResult func withCurrent(_ id: UUID, _ action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard token == id else { return false }; action(); return true
    }
    func finish(_ id: UUID, error: Error?) {
        lock.lock()
        guard token == id else { lock.unlock(); return }
        let callback = completion; completion = nil
        // A failed start cannot accept settings or block a subsequent retry.
        if error != nil { token = nil }
        lock.unlock(); callback?(error)
    }
    func stop(enqueue: () -> Void) {
        lock.lock(); token = nil
        let callback = completion; completion = nil
        // Adapter work is queued while holding the same lock as start enqueueing.
        enqueue(); lock.unlock(); callback?(CancellationError())
    }
}

/// Stored only in Keychain because a personalized resolver URL may contain secrets.
struct SuspendedDNSConfiguration: Codable {
    let version: Int
    let endpoint: String
    let bootstrap: [String]
}
enum IndependentDNSResumePolicy {
    static func shouldRestore(desired: Bool?, suspended: Bool, saved: Bool, foreign: Bool,
                              observationKnown: Bool, vpnSettledOff: Bool, operationPending: Bool) -> Bool {
        desired == true && suspended && !saved && !foreign && observationKnown && vpnSettledOff && !operationPending
    }
}


/// Device-wide network throughput from the physical interfaces' own byte counters (Wi-Fi and cellular; the VPN's virtual interface is
/// left out so traffic is not counted twice). Needs no permission and works with or without a tunnel.
struct InterfaceSpeedMeter {
    private var last: (date: Date, received: UInt64, sent: UInt64)?
    private static func counters() -> (received: UInt64, sent: UInt64)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let name = String(cString: entry.pointee.ifa_name)
            if entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en") || name.hasPrefix("pdp_ip"), let raw = entry.pointee.ifa_data {
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(data.ifi_ibytes); sent += UInt64(data.ifi_obytes)
            }
            cursor = entry.pointee.ifa_next
        }
        return (received, sent)
    }
    /// Bytes per second since the previous call, or nil for the first sample. The counters are 32-bit and wrap, which is handled.
    mutating func sample(now: Date = Date()) -> (down: Double, up: Double)? {
        guard let now32 = Self.counters() else { return nil }
        defer { last = (now, now32.received, now32.sent) }
        guard let last, now.timeIntervalSince(last.date) >= 0.5 else { return nil }
        func delta(_ new: UInt64, _ old: UInt64) -> UInt64 { new >= old ? new - old : (new + (1 << 32)) - old }
        let seconds = now.timeIntervalSince(last.date)
        return (Double(delta(now32.received, last.received)) / seconds, Double(delta(now32.sent, last.sent)) / seconds)
    }
}
