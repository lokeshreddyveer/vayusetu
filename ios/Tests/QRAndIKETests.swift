import Foundation
import NetworkExtension

@main struct QRAndIKETests {
    static func main() throws {
        var checks = 0
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let peer = Data(repeating: 2, count: 32).base64EncodedString()
        let valid = "[Interface]\nPrivateKey = \(key)\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = \(peer)\nEndpoint = vpn.example.com:51820\nAllowedIPs = 0.0.0.0/0, ::/0\n"
        let qr = try QRConfigurationImport.validate(valid)
        precondition(qr.peerCount == 1 && qr.fullTunnel); checks += 1
        for payload in ["https://example.com", "", valid + "PostUp = execute\n", valid + "\0", String(repeating: "x", count: 128_001)] {
            do { _ = try QRConfigurationImport.validate(payload); fatalError("Unsafe QR accepted") } catch { checks += 1 }
        }
        var draft = ManualVPNDraft(protocolKind: .ikev2)
        draft.name = "Fixture"; draft.server = "vpn.example.com"; draft.remoteIdentifier = "vpn.example.com"; draft.username = "fixture"; draft.password = "not-real"
        let reference = Data([1,2,3])
        let proto = try NativeIKEProtocolBuilder.build(draft, passwordReference: reference, strict: true, allowLAN: false)
        precondition(proto.serverAddress == draft.server && proto.remoteIdentifier == draft.remoteIdentifier); checks += 1
        precondition(proto.authenticationMethod == .none && proto.useExtendedAuthentication); checks += 1
        precondition(proto.passwordReference == reference && proto.username == draft.username); checks += 1
        precondition(proto.includeAllNetworks && RoutingSecurityPolicy.matches(proto, strict: true, allowLAN: false)); checks += 1
        precondition(!proto.disconnectOnSleep); checks += 1
        do { _ = try NativeIKEProtocolBuilder.build(draft, passwordReference: nil, strict: true, allowLAN: false); fatalError("Missing reference accepted") } catch { checks += 1 }
        draft.protocolKind = .openVPN
        do { _ = try NativeIKEProtocolBuilder.build(draft, passwordReference: reference, strict: true, allowLAN: false); fatalError("Wrong engine accepted") } catch { checks += 1 }
        print("Passed \(checks) QR input and native IKEv2 policy checks. No VPN preferences or Keychain records were changed.")
    }
}
