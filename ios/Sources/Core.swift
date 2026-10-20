import Foundation
import Darwin

struct AppIssue: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct WireGuardSummary {
    let addresses: [String]
    let dns: [String]
    let endpoints: [String]
    let peerCount: Int
    let fullTunnel: Bool
    let hasIPv4DefaultRoute: Bool
}

enum ProfileParser {
    static func parse(_ input: String) throws -> WireGuardSummary {
        guard input.utf8.count <= 128_000 else { throw AppIssue(message: "Profile exceeds the 128 KB limit.") }
        var section = ""
        var interface: [String: String] = [:]
        var peers: [[String: String]] = []
        for (index, original) in input.components(separatedBy: .newlines).enumerated() {
            let line = original.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line == "[Interface]" {
                guard section.isEmpty else { throw AppIssue(message: "Only one Interface section is supported.") }
                section = "interface"; continue
            }
            if line == "[Peer]" {
                guard !section.isEmpty else { throw AppIssue(message: "Interface must precede Peer sections.") }
                section = "peer"; peers.append([:]); continue
            }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !section.isEmpty else { throw AppIssue(message: "Invalid WireGuard syntax at line \(index + 1).") }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            // These are ordinary WireGuard configuration settings. VayuSetu does not
            // execute hooks or silently apply routing directives, but it must still be
            // able to import files exported by the official clients and providers.
            let permitted = section == "interface" ? ["PrivateKey", "Address", "DNS", "MTU", "ListenPort", "FwMark", "Table", "SaveConfig"] : ["PublicKey", "PresharedKey", "AllowedIPs", "Endpoint", "PersistentKeepalive"]
            guard permitted.contains(key), !value.isEmpty else { throw AppIssue(message: "Unsupported or empty setting at line \(index + 1). Shell hooks are not supported.") }
            if section == "interface" {
                if key == "FwMark", UInt32(value) == nil { throw AppIssue(message: "FwMark must be a valid unsigned integer at line \(index + 1).") }
                if key == "Table", !["auto", "off"].contains(value.lowercased()) && UInt32(value) == nil { throw AppIssue(message: "Table must be auto, off, or a numeric table at line \(index + 1).") }
                if key == "SaveConfig", !["true", "false"].contains(value.lowercased()) { throw AppIssue(message: "SaveConfig must be true or false at line \(index + 1).") }
            }
            if section == "interface" {
                guard interface[key] == nil else { throw AppIssue(message: "Duplicate interface setting at line \(index + 1).") }
                interface[key] = value
            } else {
                guard peers[peers.count - 1][key] == nil else { throw AppIssue(message: "Duplicate peer setting at line \(index + 1).") }
                peers[peers.count - 1][key] = value
            }
        }
        if section.isEmpty { throw AppIssue(message: "This profile has no WireGuard configuration in it. Its saved keys are missing or empty: edit the profile and import the original file again.") }
        guard validKey(interface["PrivateKey"]) else { throw AppIssue(message: interface["PrivateKey"] == nil ? "The profile has no PrivateKey line. Edit it and import the original file again." : "The profile's PrivateKey is not a valid WireGuard key (it must be 44 characters of base64).") }
        guard !peers.isEmpty else { throw AppIssue(message: "The profile has no [Peer] section. Edit it and import the original file again.") }
        let addresses = list(interface["Address"])
        guard !addresses.isEmpty, addresses.allSatisfy(validCIDR) else { throw AppIssue(message: "Address must contain IPv4 or IPv6 CIDR addresses.") }
        let dns = list(interface["DNS"])
        guard dns.allSatisfy({ ipFamily($0) != nil }) else { throw AppIssue(message: "DNS must contain IP addresses; search-domain entries are not supported yet.") }
        if let mtu = interface["MTU"], !(Int(mtu).map { (576...9000).contains($0) } ?? false) { throw AppIssue(message: "MTU must be between 576 and 9000.") }
        if let port = interface["ListenPort"], !(Int(port).map { (0...65535).contains($0) } ?? false) { throw AppIssue(message: "Invalid listen port.") }
        if addresses.contains(where: { ipFamily(String($0.split(separator: "/")[0])) == 6 }), let mtu = interface["MTU"], let value = Int(mtu), value < 1280 {
            throw AppIssue(message: "IPv6 interface MTU must be at least 1280.")
        }
        var endpoints: [String] = []
        var routes: [String] = []
        var publicKeys = Set<String>()
        var routeOwners: [String: String] = [:]
        for peer in peers {
            guard validKey(peer["PublicKey"]) else { throw AppIssue(message: "Each peer requires a valid public key.") }
            guard publicKeys.insert(peer["PublicKey"]!).inserted else { throw AppIssue(message: "Peer public keys must be unique.") }
            if let key = peer["PresharedKey"], !validKey(key) { throw AppIssue(message: "Invalid preshared key.") }
            let allowed = list(peer["AllowedIPs"])
            guard !allowed.isEmpty, allowed.allSatisfy(validCIDR) else { throw AppIssue(message: "Each peer requires valid AllowedIPs CIDR routes.") }
            guard let endpoint = peer["Endpoint"], validEndpoint(endpoint) else { throw AppIssue(message: "Each peer requires a host:port endpoint (IPv6 hosts must be bracketed).") }
            if let keepalive = peer["PersistentKeepalive"], !(Int(keepalive).map { (0...65535).contains($0) } ?? false) { throw AppIssue(message: "Invalid keepalive interval.") }
            for route in allowed {
                let canonical = canonicalCIDR(route)
                let owner = peer["PublicKey"]!
                if let existing = routeOwners[canonical], existing != owner {
                    throw AppIssue(message: "Two peers claim the same network route. Assign each network to one peer.")
                }
                routeOwners[canonical] = owner
            }
            endpoints.append(endpoint); routes += allowed
        }
        return WireGuardSummary(addresses: addresses, dns: dns, endpoints: endpoints, peerCount: peers.count, fullTunnel: routes.contains { canonicalCIDR($0) == canonicalCIDR("0.0.0.0/0") } && routes.contains { canonicalCIDR($0) == canonicalCIDR("::/0") }, hasIPv4DefaultRoute: routes.contains { canonicalCIDR($0) == canonicalCIDR("0.0.0.0/0") })
    }
    static func validateTunnel(_ summary: WireGuardSummary) throws {
        guard summary.addresses.contains(where: { ipFamily(String($0.split(separator: "/")[0])) == 4 }), summary.hasIPv4DefaultRoute else {
            throw AppIssue(message: "This build requires an IPv4 tunnel address and IPv4 default route. IPv6-only and split-tunnel profiles can be stored but cannot connect yet.")
        }
    }
    static func canonicalCIDR(_ value: String) -> String {
        let parts = value.split(separator: "/")
        guard parts.count == 2, let family = ipFamily(String(parts[0])), let bits = Int(parts[1]) else { return value }
        var address = [UInt8](repeating: 0, count: family == 4 ? 4 : 16)
        _ = address.withUnsafeMutableBytes { inet_pton(family == 4 ? AF_INET : AF_INET6, String(parts[0]), $0.baseAddress) }
        for index in address.indices {
            let remaining = bits - index * 8
            if remaining <= 0 { address[index] = 0 }
            else if remaining < 8 { address[index] &= UInt8(0xff << (8 - remaining) & 0xff) }
        }
        return "\(family):" + address.map { String(format: "%02x", $0) }.joined() + "/\(bits)"
    }
    static func validKey(_ value: String?) -> Bool { value.flatMap { Data(base64Encoded: $0) }?.count == 32 }
    static func list(_ value: String?) -> [String] { value.map { $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } } ?? [] }
    static func ipFamily(_ value: String) -> Int? {
        var ipv4 = in_addr(); var ipv6 = in6_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 { return 4 }
        if inet_pton(AF_INET6, value, &ipv6) == 1 { return 6 }
        return nil
    }
    static func validCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let family = ipFamily(String(parts[0])), let bits = Int(parts[1]) else { return false }
        return (0...(family == 4 ? 32 : 128)).contains(bits)
    }
    static func validEndpoint(_ value: String) -> Bool {
        guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else { return false }
        let host = String(value[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { return ipFamily(String(host.dropFirst().dropLast())) == 6 }
        return !host.isEmpty && host.count <= 253 && host.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$", options: .regularExpression) != nil
    }
}

enum DNSRecordType: UInt16, CaseIterable, Identifiable {
    case a = 1, aaaa = 28
    var id: UInt16 { rawValue }
    var title: String { self == .a ? "A · IPv4" : "AAAA · IPv6" }
}
enum DNSService {
    static func endpoint(_ value: String) throws -> URL {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2048, let url = URL(string: text),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "tls"].contains(c.scheme?.lowercased() ?? ""), let host = c.host, !host.isEmpty,
              c.port == nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              ((c.scheme?.lowercased() == "https" && !c.path.isEmpty && c.path != "/") || (c.scheme?.lowercased() == "tls" && c.path.isEmpty)), !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw AppIssue(message: "Enter https://hostname/path for DoH or tls://hostname for DoT. URL credentials, queries, fragments and custom ports are not supported.")
        }
        let bareHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let labels = bareHost.split(separator: ".", omittingEmptySubsequences: false)
        let validHost = ProfileParser.ipFamily(bareHost) != nil || (bareHost.utf8.count <= 253 && labels.count >= 2 && labels.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
        })
        guard validHost else { throw AppIssue(message: "Enter a valid DNS endpoint hostname or IP address.") }
        guard c.scheme?.lowercased() != "tls" || ProfileParser.ipFamily(bareHost) == nil else { throw AppIssue(message: "Use a TLS resolver hostname for certificate validation.") }
        return url
    }
    static func transport(_ value: String) -> String { (try? endpoint(value))?.scheme?.lowercased() == "tls" ? "DNS-over-TLS" : "DNS-over-HTTPS" }
    static func query(id: UInt16, recordType: DNSRecordType = .a) -> Data {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in ["example", "com"] { bytes.append(UInt8(label.utf8.count)); bytes += label.utf8 }
        bytes += [0, UInt8(recordType.rawValue >> 8), UInt8(recordType.rawValue & 255), 0, 1]
        return Data(bytes)
    }
    static func domain(_ value: String) throws -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.utf8.count <= 253, labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil }) else { throw AppIssue(message: "Enter a valid domain name, such as example.com. Use punycode for international names.") }
        return name
    }
    static func queryForDomain(id: UInt16, recordType: DNSRecordType = .a, domain value: String) throws -> Data {
        let name = try domain(value)
        var bytes = Array(query(id: id, recordType: recordType).prefix(12))
        for label in name.split(separator: ".") { bytes.append(UInt8(label.utf8.count)); bytes += label.utf8 }
        bytes += [0, UInt8(recordType.rawValue >> 8), UInt8(recordType.rawValue & 255), 0, 1]
        return Data(bytes)
    }
    static func readName(_ b: [UInt8], offset: inout Int) throws -> String {
        var cursor = offset
        var next: Int?
        var labels: [String] = []
        var seen = Set<Int>()
        while true {
            guard cursor < b.count, seen.insert(cursor).inserted, seen.count <= 128 else { throw AppIssue(message: "Malformed DNS name.") }
            let length = Int(b[cursor])
            if length == 0 { offset = next ?? (cursor + 1); return labels.joined(separator: ".").lowercased() }
            if length & 0xc0 == 0xc0 {
                guard cursor + 1 < b.count else { throw AppIssue(message: "Truncated DNS pointer.") }
                if next == nil { next = cursor + 2 }
                cursor = (length & 0x3f) * 256 + Int(b[cursor + 1]); continue
            }
            guard length <= 63, cursor + 1 + length <= b.count else { throw AppIssue(message: "Malformed DNS label.") }
            labels.append(String(decoding: b[(cursor + 1)..<(cursor + 1 + length)], as: UTF8.self))
            guard labels.joined(separator: ".").utf8.count <= 253 else { throw AppIssue(message: "DNS name is too long.") }
            cursor += length + 1
        }
    }
    static func validateReply(_ data: Data, id: UInt16, recordType: DNSRecordType = .a, domain value: String = "example.com", expectNXDOMAIN: Bool = false) throws -> Int {
        let expected = try domain(value)
        let b = [UInt8](data)
        guard (12...65535).contains(b.count), (UInt16(b[0]) << 8 | UInt16(b[1])) == id, b[2] & 0x80 != 0, b[2] & 0x7a == 0, b[4] == 0, b[5] == 1 else { throw AppIssue(message: "Resolver returned an invalid or truncated DNS response.") }
        var offset = 12
        let question = try readName(b, offset: &offset)
        guard question == expected, offset + 4 <= b.count, Array(b[offset..<(offset + 4)]) == [UInt8(recordType.rawValue >> 8), UInt8(recordType.rawValue & 255), 0, 1] else { throw AppIssue(message: "DNS response question does not match.") }
        offset += 4
        if expectNXDOMAIN {
            guard b[3] & 0x0f == 3, b[6] == 0, b[7] == 0 else { throw AppIssue(message: "Resolver did not return the expected NXDOMAIN response.") }
            return 0
        }
        guard b[3] & 0x0f == 0 else { throw AppIssue(message: "Resolver returned a DNS error.") }
        let answers = Int(b[6]) * 256 + Int(b[7])
        var addressCount = 0
        var acceptedNames: Set<String> = [expected]
        for _ in 0..<answers {
            let owner = try readName(b, offset: &offset)
            guard offset + 10 <= b.count else { throw AppIssue(message: "Truncated DNS record.") }
            let type = Int(b[offset]) * 256 + Int(b[offset + 1])
            let recordClass = Int(b[offset + 2]) * 256 + Int(b[offset + 3])
            let length = Int(b[offset + 8]) * 256 + Int(b[offset + 9])
            offset += 10
            guard offset + length <= b.count else { throw AppIssue(message: "Truncated DNS answer.") }
            if acceptedNames.contains(owner), recordClass == 1 {
                if type == Int(recordType.rawValue), length == (recordType == .a ? 4 : 16) { addressCount += 1 }
                if type == 5 {
                    var cnameOffset = offset
                    let canonical = try readName(b, offset: &cnameOffset)
                    guard cnameOffset == offset + length else { throw AppIssue(message: "Malformed canonical name.") }
                    acceptedNames.insert(canonical)
                }
            }
            offset += length
        }
        guard addressCount > 0 else { throw AppIssue(message: "Resolver returned no matching address record for the requested domain.") }
        return addressCount
    }
    static func exchange(_ url: URL, recordType: DNSRecordType = .a, domain value: String = "example.com") async throws -> (UInt16, Data) {
        let name = try domain(value); let url = try endpoint(url.absoluteString)
        let id = UInt16.random(in: 0...65535)
        let question = try queryForDomain(id: id, recordType: recordType, domain: name)
        if url.scheme?.lowercased() == "tls" { return (id, try await DNSOverTLSRequest(host: url.host!, query: question).run()) }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = question
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept"); request.timeoutInterval = 12
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.mimeType == "application/dns-message" else { throw AppIssue(message: "Resolver did not return a successful DNS-over-HTTPS response.") }
        var data = Data()
        for try await byte in bytes { guard data.count < 65_535 else { throw AppIssue(message: "Resolver response exceeds the DNS message size limit.") }; data.append(byte) }
        return (id, data)
    }
    static func probe(_ url: URL, recordType: DNSRecordType = .a, domain value: String = "example.com", expectNXDOMAIN: Bool = false) async throws -> String {
        let name = try domain(value); let start = ContinuousClock.now
        let (id, data) = try await exchange(url, recordType: recordType, domain: name)
        let count = try validateReply(data, id: id, recordType: recordType, domain: name, expectNXDOMAIN: expectNXDOMAIN)
        let transport = url.scheme?.lowercased() == "tls" ? "TLS" : "HTTPS"
        if expectNXDOMAIN { return "Observed NXDOMAIN for \(name) over \(transport). This is consistent with blocking or a nonexistent domain; it does not independently prove provider filtering or DNS routing." }
        let duration = start.duration(to: .now).components
        let milliseconds = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
        return "Resolver responded in \(milliseconds) ms with \(count) \(recordType == .a ? "A" : "AAAA") answer(s) over \(transport). This test uses the current network route; it does not configure system DNS or prove a VPN connection."
    }

}
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Default exports deliberately cannot establish a tunnel; comments may hide secrets too.
enum ProfileExport {
    static func redacted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let content = String(line).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let field = content.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if field == "privatekey" { return "PrivateKey = [REDACTED]" }
            if field == "presharedkey" { return "PresharedKey = [REDACTED]" }
            return content
        }.joined(separator: "\n")
    }
}

// Protocol drafts are deliberately separate from runnable WireGuard profiles.
enum ManualVPNProtocol: String, Codable, CaseIterable, Sendable { case openVPN = "OpenVPN", ikev2 = "IKEv2" }
struct ManualVPNDraft: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var protocolKind: ManualVPNProtocol
    var name = ""
    var server = ""
    var port = "1194"
    var transport = "UDP"
    var username = ""
    var password = ""
    var caCertificate = ""
    var clientCertificate = ""
    var privateKey = ""
    var remoteIdentifier = ""
    var localIdentifier = ""
    var authentication = "Username & Password"
    var identityBase64 = ""
    var identityPassword = ""
    var onDemand = false
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128 else { throw AppIssue(message: "Enter a profile name of 1–128 bytes.") }
        let host = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let hostname = host.utf8.count <= 253 && labels.allSatisfy { !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } }
        guard !host.isEmpty, host == server, ProfileParser.ipFamily(host) != nil || hostname else { throw AppIssue(message: "Enter a hostname or IP address without a scheme, path or port.") }
        guard let data = try? JSONEncoder().encode(self), data.count <= 128_000 else { throw AppIssue(message: "Configuration exceeds the 128 KB limit.") }
        switch protocolKind {
        case .openVPN:
            guard let number = Int(port), (1...65535).contains(number), ["UDP", "TCP"].contains(transport) else { throw AppIssue(message: "Enter a port from 1–65535 and select UDP or TCP.") }
            guard !caCertificate.isEmpty else { throw AppIssue(message: "Provide your server’s CA certificate. Certificate verification cannot be disabled.") }
            guard caCertificate.contains("-----BEGIN CERTIFICATE-----"), caCertificate.contains("-----END CERTIFICATE-----") else { throw AppIssue(message: "Enter the CA certificate in PEM format.") }
            guard clientCertificate.isEmpty == privateKey.isEmpty else { throw AppIssue(message: "Supply both the client certificate and private key, or leave both empty.") }
            if !clientCertificate.isEmpty {
                guard clientCertificate.contains("-----BEGIN CERTIFICATE-----"), privateKey.contains("PRIVATE KEY-----") else { throw AppIssue(message: "Enter a PEM client certificate and PEM private key.") }
            }
            guard username.isEmpty == password.isEmpty else { throw AppIssue(message: "Supply both username and password, or leave both empty.") }
        case .ikev2:
            guard !remoteIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppIssue(message: "Enter the server’s remote identifier for identity validation.") }
            if authentication == "Username & Password" {
                guard !username.isEmpty, !password.isEmpty else { throw AppIssue(message: "Enter the username and password provided by your VPN administrator.") }
            } else {
                guard authentication == "Certificate", let identity = Data(base64Encoded: identityBase64.filter { !$0.isWhitespace }), !identity.isEmpty else { throw AppIssue(message: "Enter a base64-encoded PKCS#12 identity. Its validity must be checked by the future adapter.") }
            }
        }
    }
}
struct ManualVPNDraftSummary: Codable, Identifiable {
    let id: UUID
    var name: String
    let protocolKind: ManualVPNProtocol
}
struct ManualVPNDraftArchive: Codable { let version: Int; let drafts: [ManualVPNDraftSummary] }

/// QR content is configuration data only, never a URL to open or a script to run.
enum QRConfigurationImport {
    static func validate(_ payload: String) throws -> WireGuardSummary {
        guard !payload.isEmpty, payload.utf8.count <= 128_000, !payload.contains("\0") else { throw AppIssue(message: "Invalid QR payload size or content.") }
        return try ProfileParser.parse(payload)
    }
}

/// Reading a file is separate from saving; every import reaches a review editor first.
enum WireGuardImportReview {
    static func read(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 128_000 else { throw AppIssue(message: "Choose a configuration file of 1–128 KB.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 128_000, let text = String(data: data, encoding: .utf8) else { throw AppIssue(message: "The configuration must be UTF-8 text within the import limit.") }
        _ = try QRConfigurationImport.validate(text)
        return text
    }
}
