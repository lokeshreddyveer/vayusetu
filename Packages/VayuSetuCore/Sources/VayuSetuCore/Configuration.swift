import Foundation

public struct SavedProfile: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public let addresses: [String]
    public let dns: [String]
    public let endpoints: [String]
    public let peerCount: Int
    public let fullTunnel: Bool
    public let created: Date
    public init(id: UUID, name: String, addresses: [String], dns: [String], endpoints: [String], peerCount: Int, fullTunnel: Bool, created: Date) { self.id = id; self.name = name; self.addresses = addresses; self.dns = dns; self.endpoints = endpoints; self.peerCount = peerCount; self.fullTunnel = fullTunnel; self.created = created }
}

public struct ProfileArchive: Codable {
    public let version: Int
    public let profiles: [SavedProfile]
    public init(version: Int, profiles: [SavedProfile]) { self.version = version; self.profiles = profiles }
}
public struct DNSProfile: Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var bootstrapAddresses: [String]?
    public init(id: UUID, name: String, bootstrapAddresses: [String]? = nil) { self.id = id; self.name = name; self.bootstrapAddresses = bootstrapAddresses }
}
/// The built-in "VayuSetu DNS" provider: VayuSetu's own filter lists applied locally, then an
/// encrypted upstream resolver. VayuSetu operates no DNS server; the upstream is Quad9 over DoH.
public enum VayuSetuDNS {
    public static let id = UUID(uuidString: "5A7E5E70-0000-4000-8000-0000000000D5")!
    public static let name = "VayuSetu DNS"
    public static let upstreamEndpoint = "https://dns.quad9.net/dns-query"
    public static let bootstrapAddresses = ["9.9.9.9", "149.112.112.112"]
    /// Lists enabled for this provider when none is enabled yet.
    public static let starterListURL = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/light.txt"
}
public struct DNSArchive: Codable {
    public let version: Int
    public let profiles: [DNSProfile]
    public init(version: Int, profiles: [DNSProfile]) { self.version = version; self.profiles = profiles }
}

