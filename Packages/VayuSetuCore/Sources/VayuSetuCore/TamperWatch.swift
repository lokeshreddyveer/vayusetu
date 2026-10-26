import Foundation

/// One entry of the system's resolver list (`scutil --dns`).
public struct SystemResolver: Equatable, Sendable {
    public var nameservers: [String]
    public var interface: String?
    public var order: Int?
    public var supplemental: Bool
    /// Empty means it answers for every name.
    public var domain: String?
    public init(nameservers: [String] = [], interface: String? = nil, order: Int? = nil, supplemental: Bool = false, domain: String? = nil) {
        self.nameservers = nameservers; self.interface = interface; self.order = order; self.supplemental = supplemental; self.domain = domain
    }
}

public enum SystemResolverParser {
    /// Reads the "resolver #N" blocks above the "scoped queries" part of `scutil --dns`.
    public static func parse(_ text: String) -> [SystemResolver] {
        var out: [SystemResolver] = []; var current: SystemResolver?
        func close() { if let c = current { out.append(c) }; current = nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration (for scoped") { break }
            if line.hasPrefix("resolver #") { close(); current = SystemResolver(); continue }
            guard current != nil else { continue }
            if line.hasPrefix("nameserver["), let value = line.split(separator: ":", maxSplits: 1).last { current?.nameservers.append(value.trimmingCharacters(in: .whitespaces)) }
            else if line.hasPrefix("if_index"), let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close { current?.interface = String(line[line.index(after: open)..<close]) }
            else if line.hasPrefix("order"), let value = line.split(separator: ":", maxSplits: 1).last { current?.order = Int(value.trimmingCharacters(in: .whitespaces)) }
            else if line.hasPrefix("flags"), line.contains("Supplemental") { current?.supplemental = true }
            else if line.hasPrefix("domain"), let value = line.split(separator: ":", maxSplits: 1).last { current?.domain = value.trimmingCharacters(in: .whitespaces) }
        }
        close()
        return out
    }
}

/// Whether something other than VayuSetu has taken over the connection's DNS or routing. Judged only while VayuSetu says it is protecting.
public enum TamperVerdict: Equatable, Sendable {
    case intact
    /// VayuSetu's resolver is no longer in the system's list.
    case resolverMissing
    /// Another resolver now answers for all names ahead of VayuSetu's. `by` is the interface it is attached to, never an address.
    case resolverOutranked(by: String)
    /// A VPN is on but the default route no longer goes through its interface.
    case routeLeftTunnel(to: String)
    /// Nothing could be read: no verdict either way.
    case unknown

    public var message: String? {
        switch self {
        case .intact, .unknown: return nil
        case .resolverMissing: return "VayuSetu's DNS was removed from this Mac's settings while protection is on. Something else changed your DNS."
        case .resolverOutranked(let by): return "Another resolver (on \(by)) now takes precedence over VayuSetu's DNS. Another app, VPN or profile changed your DNS."
        case .routeLeftTunnel(let to): return "The VPN is on, but traffic is leaving through \(to) instead of the tunnel."
        }
    }
}

public enum TamperWatch {
    /// - Parameters:
    ///   - ourServer: the address VayuSetu's resolver listens on.
    ///   - dnsExpected: VayuSetu DNS is supposed to be answering.
    ///   - vpnExpected: a VPN is supposed to carry the default route.
    ///   - defaultInterface: the interface of the default route, if known.
    public static func assess(resolvers: [SystemResolver], ourServer: String, dnsExpected: Bool, vpnExpected: Bool, defaultInterface: String?) -> TamperVerdict {
        if vpnExpected, let iface = defaultInterface, !iface.hasPrefix("utun") { return .routeLeftTunnel(to: iface) }
        guard dnsExpected else { return .intact }
        guard !resolvers.isEmpty else { return .unknown }
        guard let ours = resolvers.first(where: { $0.nameservers.contains(ourServer) }) else { return .resolverMissing }
        // A resolver that answers for every name and sorts before ours takes our place. Scoped or domain-specific ones (.local, reverse zones) do not.
        let ourOrder = ours.order ?? Int.max
        for other in resolvers where other != ours {
            let coversAll = (other.domain ?? "").isEmpty && !other.nameservers.contains(ourServer)
            guard coversAll, let order = other.order, order < ourOrder else { continue }
            return .resolverOutranked(by: other.interface ?? "another interface")
        }
        return .intact
    }

    /// An alert needs the same bad verdict twice in a row, so a network change that takes a second to settle is not reported.
    public static func shouldAlert(previous: TamperVerdict?, current: TamperVerdict, alreadyAlerted: TamperVerdict?) -> Bool {
        guard current.message != nil, previous == current else { return false }
        return alreadyAlerted != current
    }
}
