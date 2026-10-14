import Foundation
import Network

@main struct WireGuardPolicyTests {
    static var checks = 0
    static func require(_ value: Bool, _ name: String) { guard value else { fatalError("FAIL: \(name)") }; checks += 1 }
    static func main() throws {
        let key = Data(repeating: 42, count: 32).base64EncodedString()
        let text = """
        [Interface]
        PrivateKey = \(key)
        Address = 10.14.0.2/16
        [Peer]
        PublicKey = \(key)
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = 192.0.2.1:51820
        """
        let v4 = try WireGuardConfigPolicy.prepare(text)
        require(v4.blockIPv6, "IPv4-only provider blocks IPv6")
        require(v4.configuration.peers.allSatisfy { $0.allowedIPs.allSatisfy { $0.address is IPv4Address } }, "no IPv6 routes remain in backend")
        let dual = try WireGuardConfigPolicy.prepare(text.replacingOccurrences(of: "10.14.0.2/16", with: "10.14.0.2/16, fd00::2/64"))
        require(!dual.blockIPv6 && dual.configuration.peers[0].allowedIPs.contains(where: { $0.stringRepresentation == "::/0" }), "native dual-stack routing retained")
        do { _ = try WireGuardConfigPolicy.prepare(text.replacingOccurrences(of: "0.0.0.0/0", with: "10.0.0.0/8")); fatalError("Split-only profile accepted") } catch { checks += 1 }
        do { _ = try WireGuardConfigPolicy.prepare(text.replacingOccurrences(of: "10.14.0.2/16", with: "fd00::2/64")); fatalError("Missing IPv4 interface accepted") } catch { checks += 1 }
        require(v4.configuration.interface.privateKey.rawValue == Data(repeating: 42, count: 32), "WireGuard parser preserves key bytes")
        let alternateDefaults = text.replacingOccurrences(of: "::/0", with: "0:0:0:0:0:0:0:0/0").replacingOccurrences(of: "10.14.0.2/16", with: "10.14.0.2/16, fd00::2/64")
        let alternatePrepared = try WireGuardConfigPolicy.prepare(alternateDefaults)
        require(!alternatePrepared.blockIPv6, "canonical IPv6 default remains native")
        do { _ = try WireGuardConfigPolicy.prepare(text.replacingOccurrences(of: "Address = 10.14.0.2/16", with: "Address = 10.14.0.2/16, fd00::2/64\nMTU = 1200")); fatalError("IPv6 MTU below 1280 accepted") } catch { checks += 1 }
        print("Passed \(checks) WireGuard policy checks.")
    }
}
