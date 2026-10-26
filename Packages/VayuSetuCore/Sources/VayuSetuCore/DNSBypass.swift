import Foundation

/// An app that appears to ask for names through its own encrypted DNS instead of the system's, so VayuSetu's lists never see its lookups.
/// This is judged from connections the Mac network filter has seen. It is a likely sign, not proof: a connection to a public resolver on the
/// encrypted-DNS port is what apps use for DNS-over-TLS, and a connection to a resolver's DNS-over-HTTPS name is what browsers use for DoH.
public struct BypassFlow: Equatable, Sendable {
    public var app: String, appName: String, host: String, port: String, proto: String
    public var remoteAddress: String?
    public var outbound: Bool
    public init(app: String, appName: String, host: String, port: String, proto: String, remoteAddress: String? = nil, outbound: Bool = true) {
        self.app = app; self.appName = appName; self.host = host; self.port = port; self.proto = proto; self.remoteAddress = remoteAddress; self.outbound = outbound
    }
}

public struct DNSBypassFinding: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case dnsOverTLS = "DNS-over-TLS", dnsOverHTTPS = "DNS-over-HTTPS" }
    public let app: String, appName: String, kind: Kind
    /// The resolver's name when it is a known one (never an address the person did not already see).
    public let resolver: String
    public let connections: Int
    public var id: String { app + "|" + kind.rawValue }
    public var message: String {
        "\(appName) appears to use its own encrypted DNS (\(kind.rawValue) to \(resolver)), so VayuSetu's lists do not see its lookups. Turn that setting off in the app, or use the system's DNS."
    }
}

public enum DNSBypassDetector {
    /// Resolver hostnames used for DNS-over-HTTPS. Web pages are not served from these, so a connection to one on 443 is a DNS query.
    static let dohHosts: [String: String] = [
        "cloudflare-dns.com": "Cloudflare", "mozilla.cloudflare-dns.com": "Cloudflare", "security.cloudflare-dns.com": "Cloudflare", "family.cloudflare-dns.com": "Cloudflare",
        "dns.google": "Google", "dns.quad9.net": "Quad9", "dns11.quad9.net": "Quad9", "doh.opendns.com": "OpenDNS", "dns.nextdns.io": "NextDNS",
        "dns.adguard-dns.com": "AdGuard", "dns.adguard.com": "AdGuard", "doh.cleanbrowsing.org": "CleanBrowsing", "doh.dns.sb": "DNS.SB", "doh.mullvad.net": "Mullvad",
        "dns.controld.com": "Control D", "freedns.controld.com": "Control D", "dns.alidns.com": "AliDNS", "doh.pub": "DNSPod",
    ]
    /// Public resolver addresses; a connection to one on 443 is DoH (these addresses serve no ordinary web pages).
    static let resolverAddresses: [String: String] = [
        "1.1.1.1": "Cloudflare", "1.0.0.1": "Cloudflare", "8.8.8.8": "Google", "8.8.4.4": "Google", "9.9.9.9": "Quad9", "149.112.112.112": "Quad9",
        "208.67.222.222": "OpenDNS", "208.67.220.220": "OpenDNS", "94.140.14.14": "AdGuard", "94.140.15.15": "AdGuard",
        "2606:4700:4700::1111": "Cloudflare", "2001:4860:4860::8888": "Google", "2620:fe::fe": "Quad9",
    ]
    /// Apps that are VayuSetu itself (its tunnel talks to the resolver you chose, on purpose).
    static func isOurs(_ app: String) -> Bool { app.hasPrefix("app.vayusetu.") }

    public static func classify(_ flow: BypassFlow) -> (DNSBypassFinding.Kind, String)? {
        guard flow.outbound, !isOurs(flow.app) else { return nil }
        let host = flow.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let address = flow.remoteAddress.map(normalize) ?? normalize(host)
        let resolver = dohHosts[host] ?? resolverAddresses[address]
        if flow.port == "853" {
            return (.dnsOverTLS, resolver ?? (host.isEmpty ? "a DNS server" : host))
        }
        if flow.port == "443", let resolver { return (.dnsOverHTTPS, resolver) }
        return nil
    }
    private static func normalize(_ a: String) -> String { a.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }

    public static func findings(_ flows: [BypassFlow]) -> [DNSBypassFinding] {
        var counts: [String: (BypassFlow, DNSBypassFinding.Kind, String, Int)] = [:]
        for flow in flows {
            guard let (kind, resolver) = classify(flow) else { continue }
            let key = flow.app + "|" + kind.rawValue
            if let existing = counts[key] { counts[key] = (existing.0, kind, existing.2, existing.3 + 1) } else { counts[key] = (flow, kind, resolver, 1) }
        }
        return counts.values.map { DNSBypassFinding(app: $0.0.app, appName: $0.0.appName.isEmpty ? $0.0.app : $0.0.appName, kind: $0.1, resolver: $0.2, connections: $0.3) }
            .sorted { ($0.connections, $1.appName) > ($1.connections, $0.appName) }
    }
}
