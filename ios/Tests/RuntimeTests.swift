import Foundation
@main struct RuntimeTests {
    static var checks = 0
    static func require(_ condition: Bool) { precondition(condition); checks += 1 }
    static func main() throws {
        let retry = RetryPolicy(maximumAttempts: 3)
        require(retry.delay(after: -1) == nil)
        require(retry.delay(after: 0) == 1 && retry.delay(after: 1) == 2 && retry.delay(after: 2) == 4)
        require(retry.delay(after: 3) == nil)
        let names = ["Handshake", "IPv4 exit", "IPv6 policy", "DNS transport", "Routing isolation"]
        let full = names.map { Evidence($0, .passed, "test") }
        require(HealthPolicy.complete(full))
        require(!HealthPolicy.complete(Array(full.dropLast())))
        require(!HealthPolicy.complete(full.map { Evidence($0.name, $0.name == "DNS transport" ? .unverified : .passed, "test") }))
        require(!HealthPolicy.complete([Evidence("Resolver response", .passed, "probe")]))
        let record = SessionRecord(id: UUID(), started: Date(), ended: Date(), received: 12, sent: 34, outcome: .degraded)
        let restored = try JSONDecoder().decode(HistoryArchive.self, from: JSONEncoder().encode(HistoryArchive(version: 1, sessions: [record])))
        require(restored.sessions.first?.id == record.id && restored.sessions.first?.received == 12)
        require(!HealthPolicy.complete([]))
        require(!HealthPolicy.complete(full.filter { $0.name != "IPv4 exit" } + [Evidence("IPv4 public address", .passed, "HTTPS address response")]))
        let profileID = UUID()
        let profiled = SessionRecord(id: UUID(), started: Date(), ended: Date(), received: 1, sent: 2, outcome: .disconnected, profileID: profileID)
        let encoded = try JSONEncoder().encode(profiled)
        require(try JSONDecoder().decode(SessionRecord.self, from: encoded).profileID == profileID)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "profileID")
        require(try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: legacy)).profileID == nil)
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        require(!EmbeddedMacProfile.present(in: bundle))
        try Data("fixture".utf8).write(to: bundle.appendingPathComponent("Contents/Resources/embedded.provisionprofile"))
        require(!EmbeddedMacProfile.present(in: bundle))
        let profile = bundle.appendingPathComponent("Contents/embedded.provisionprofile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        require(!EmbeddedMacProfile.present(in: bundle))
        try FileManager.default.removeItem(at: profile)
        try Data("fixture".utf8).write(to: profile)
        require(EmbeddedMacProfile.present(in: bundle))
        require(ProtectionRuntime.nativeEncryptedDNS.capabilities.systemSelectionRequired)
        require(ProtectionRuntime.nativeEncryptedDNS.capabilities.rejection(remoteVPN: true) != nil)
        require(ProtectionRuntime.wireGuard.capabilities.rejection(remoteVPN: true, encryptedResolver: true) == nil)
        require(ProtectionRuntime.wireGuard.capabilities.rejection(localFiltering: true) == nil)   // filter runs in front of the WireGuard tunnel
        require(ProtectionRuntime.ikev2.capabilities.rejection(remoteVPN: true) == nil)
        require(ProtectionRuntime.ikev2.capabilities.rejection(encryptedResolver: true) != nil)
        require(ProtectionRuntime.localDNSTunnel.capabilities.rejection(encryptedResolver: true, localFiltering: true) == nil)
        require(ProtectionRuntime.localDNSTunnel.capabilities.rejection(remoteVPN: true) != nil)   // the local tunnel is not a remote VPN
        require(ProtectionRuntime.openVPN.capabilities.rejection(remoteVPN: true) != nil)
        print("Passed \(checks) lifecycle/evidence contract checks.")
    }
}
