import Foundation

@main struct ManualProtocolTests {
    static func main() throws {
        var checks = 0
        func reject(_ value: ManualVPNDraft) {
            do { try value.validate(); fatalError("Invalid manual draft accepted") } catch { checks += 1 }
        }
        var open = ManualVPNDraft(protocolKind: .openVPN)
        reject(open)
        open.name = "Local fixture"; open.server = "vpn.example.com"
        reject(open) // CA identity cannot be silently omitted.
        open.caCertificate = "-----BEGIN CERTIFICATE-----\nQQ==\n-----END CERTIFICATE-----"
        try open.validate(); checks += 1 // Framing only, not certificate trust.
        var bad = open; bad.server = "https://vpn.example.com/path"; reject(bad)
        bad = open; bad.port = "0"; reject(bad)
        bad = open; bad.port = "65536"; reject(bad)
        bad = open; bad.transport = "automatic"; reject(bad)
        bad = open; bad.username = "fixture-user"; reject(bad)
        bad = open; bad.privateKey = "partial-key"; reject(bad)
        bad = open; bad.password = String(repeating: "x", count: 128_001); reject(bad)
        var ike = ManualVPNDraft(protocolKind: .ikev2)
        ike.name = "IKE fixture"; ike.server = "2001:db8::1"
        reject(ike)
        ike.remoteIdentifier = "vpn.example.com"; ike.username = "fixture-user"; ike.password = "fixture-secret"
        try ike.validate(); checks += 1
        bad = ike; bad.password = ""; reject(bad)
        bad = ike; bad.authentication = "Certificate"; bad.identityBase64 = "!!!!"; reject(bad)
        let summary = ManualVPNDraftSummary(id: ike.id, name: ike.name, protocolKind: ike.protocolKind)
        let metadata = try JSONEncoder().encode(ManualVPNDraftArchive(version: 1, drafts: [summary]))
        let text = String(decoding: metadata, as: UTF8.self)
        precondition(!text.contains(ike.password) && !text.contains(ike.username) && !text.contains(ike.server)); checks += 1
        let decoded = try JSONDecoder().decode(ManualVPNDraft.self, from: JSONEncoder().encode(ike))
        precondition(decoded == ike); checks += 1
        print("Passed \(checks) manual-protocol validation and metadata checks.")
    }
}
