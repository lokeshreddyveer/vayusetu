import Foundation
import Network

enum WireGuardConfigPolicy {
    static func prepare(_ text: String) throws -> (configuration: TunnelConfiguration, blockIPv6: Bool) {
        _ = try ProfileParser.parse(text)
        var config = try TunnelConfiguration(fromWgQuickConfig: text)
        guard config.interface.addresses.contains(where: { $0.address is IPv4Address }), config.peers.contains(where: { $0.allowedIPs.contains(where: { ProfileParser.canonicalCIDR($0.stringRepresentation) == ProfileParser.canonicalCIDR("0.0.0.0/0") }) }) else {
            throw AppIssue(message: "The profile needs an IPv4 interface address and default route.")
        }
        let nativeIPv6 = config.interface.addresses.contains(where: { $0.address is IPv6Address }) && config.peers.contains(where: { $0.allowedIPs.contains(where: { ProfileParser.canonicalCIDR($0.stringRepresentation) == ProfileParser.canonicalCIDR("::/0") }) })
        if !nativeIPv6 {
            // An IPv6 /0 with no provider IPv6 address must not send synthetic-source traffic to the server.
            // Remove all IPv6 backend routes; the OS capture route then sends IPv6 to a backend that drops it.
            let peers = config.peers.map { peer -> PeerConfiguration in
                var copy = peer; copy.allowedIPs.removeAll { $0.address is IPv6Address }; return copy
            }
            config = TunnelConfiguration(name: config.name, interface: config.interface, peers: peers)
        }
        return (config, !nativeIPv6)
    }
}
