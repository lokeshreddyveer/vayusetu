import Foundation

@main struct ProfileManagementTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        func rejects(_ action: () throws -> Void) { do { try action(); fatalError("Invalid input accepted") } catch { checks += 1 } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.conf")
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let peer = Data(repeating: 2, count: 32).base64EncodedString()
        let config = "[Interface]\nPrivateKey = \(key)\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = \(peer)\nEndpoint = vpn.example.com:51820\nAllowedIPs = 0.0.0.0/0\n"
        try Data(config.utf8).write(to: file)
        check(try WireGuardImportReview.read(file) == config)
        check(try Data(contentsOf: file) == Data(config.utf8))
        for payload in [Data("https://example.com".utf8), Data((config + "PostUp = execute\n").utf8), Data(repeating: 65, count: 128_001), Data([255,254])] {
            try payload.write(to: file); rejects { _ = try WireGuardImportReview.read(file) }
        }
        rejects { _ = try WireGuardImportReview.read(folder) }
        var profile = ManualVPNDraft(protocolKind: .ikev2)
        profile.name = "Fixture"; profile.server = "vpn.example.com"; profile.remoteIdentifier = "vpn.example.com"
        profile.username = "fixture-user"; profile.password = "fixture-secret"
        let metadata = try NativeProfileBackup.snapshot(profile, includeCredentials: false)
        let json = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        check(metadata.version == 2 && metadata.nativeIKEv2 == nil && metadata.includesCredentials == false)
        check(!json.contains(profile.server) && !json.contains(profile.username) && !json.contains(profile.password))
        let included = try NativeProfileBackup.snapshot(profile, includeCredentials: true)
        let encrypted = try BackupCrypto.encrypt(included, password: "fixture-password-123")
        let decoded = try BackupCrypto.decrypt(encrypted, password: "fixture-password-123")
        check(decoded.nativeIKEv2?.first == profile)
        rejects { _ = try BackupCrypto.decrypt(encrypted, password: "wrong-password-123") }
        var contradictory = included; contradictory.includesCredentials = false
        rejects { try contradictory.validate() }
        var wrong = included; wrong.nativeIKEv2?[0].protocolKind = .openVPN
        rejects { try wrong.validate() }
        let legacy = ConfigurationBackup(version: 1, created: Date(), vpn: [], dns: [])
        try legacy.validate(); check(try JSONDecoder().decode(ConfigurationBackup.self, from: JSONEncoder().encode(legacy)).nativeIKEv2 == nil)
        var invalidLegacy = legacy; invalidLegacy.nativeIKEv2 = [profile]
        rejects { try invalidLegacy.validate() }
        let accounts = [UUID().uuidString, "dns-" + UUID().uuidString, "manual-vpn-" + UUID().uuidString]
        let journal = RestoreJournal(version: 2, profiles: Data("old-wg".utf8), dns: Data("old-dns".utf8), nativeProfiles: Data("old-native".utf8), accounts: accounts)
        let journalURL = folder.appendingPathComponent("journal"), wgURL = folder.appendingPathComponent("wg"), dnsURL = folder.appendingPathComponent("dns"), nativeURL = folder.appendingPathComponent("native")
        try JSONEncoder().encode(journal).write(to: journalURL)
        var deleted: [String] = []
        try RestoreRecovery.rollback(journalURL: journalURL, profilesURL: wgURL, dnsURL: dnsURL, nativeURL: nativeURL) { deleted.append($0) }
        check(try Data(contentsOf: wgURL) == journal.profiles)
        check(try Data(contentsOf: dnsURL) == journal.dns)
        check(try Data(contentsOf: nativeURL) == journal.nativeProfiles)
        check(deleted == accounts && !FileManager.default.fileExists(atPath: journalURL.path))
        rejects { try RestoreJournal(version: 2, profiles: nil, dns: nil, accounts: ["unrelated-account"]).validate() }
        rejects { try RestoreJournal(version: 1, profiles: nil, dns: nil, nativeProfiles: Data(), accounts: []).validate() }
        rejects { try RestoreJournal(version: 1, profiles: nil, dns: nil, accounts: [accounts[2]]).validate() }
        print("Passed \(checks) profile import, encrypted native backup and restore-recovery checks. No real credentials or VPN preferences used.")
    }
}
