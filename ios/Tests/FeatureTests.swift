import Foundation

@main struct FeatureTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        func rejects(_ name: String, _ action: () throws -> Void) { do { try action(); fatalError(name) } catch { checks += 1 } }
        let start = TunnelCounterSample(date: Date(), received: 10, sent: 20)
        let reset = TunnelCounterSample(date: start.date.addingTimeInterval(1), received: 0, sent: 0)
        let later = TunnelCounterSample(date: start.date.addingTimeInterval(1), received: 30, sent: 50)
        check(TunnelCounterSample.compare(start, reset).contains("inconclusive"), "counter reset is not path evidence")
        check(TunnelCounterSample.compare(start, start).contains("inconclusive"), "same timestamp is not fresh evidence")
        check(TunnelCounterSample.compare(start, later).contains("Activity does not prove"), "counter increases never verify isolation")
        let backup = ConfigurationBackup(version: 1, created: Date(), vpn: [], dns: [.init(name: "Test", endpoint: "https://dns.example.com/dns-query")])
        let password = "test-only-password-123"
        let encrypted = try BackupCrypto.encrypt(backup, password: password)
        let decoded = try BackupCrypto.decrypt(encrypted, password: password)
        check(decoded.dns.first?.endpoint == backup.dns.first?.endpoint, "encrypted round-trip")
        check(!String(decoding: encrypted, as: UTF8.self).contains("dns.example.com"), "endpoint absent from encrypted file")
        check(try BackupCrypto.encrypt(backup, password: password) != encrypted, "randomized encryption")
        rejects("wrong password") { _ = try BackupCrypto.decrypt(encrypted, password: "incorrect-password") }
        rejects("truncated ciphertext") { _ = try BackupCrypto.decrypt(encrypted.dropLast(), password: password) }
        var object = try JSONSerialization.jsonObject(with: encrypted) as! [String: Any]
        var bytes = Data(base64Encoded: object["sealed"] as! String)!; bytes[12] ^= 1
        object["sealed"] = bytes.base64EncodedString()
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        rejects("modified ciphertext") { _ = try BackupCrypto.decrypt(corrupt, password: password) }
        object["rounds"] = 4_000_000_000
        rejects("unbounded KDF") { _ = try BackupCrypto.decrypt(JSONSerialization.data(withJSONObject: object), password: password) }
        rejects("short password") { _ = try BackupCrypto.encrypt(backup, password: "short") }
        rejects("unsupported archive version") { try ConfigurationBackup(version: 3, created: Date(), vpn: [], dns: []).validate() }
        rejects("invalid endpoint") { try ConfigurationBackup(version: 1, created: Date(), vpn: [], dns: [.init(name: "Test", endpoint: "http://dns.example.com/dns-query")]).validate() }
        rejects("excessive profiles") { try ConfigurationBackup(version: 1, created: Date(), vpn: [], dns: Array(repeating: backup.dns[0], count: 51)).validate() }
        rejects("invalid name") { try ConfigurationBackup(version: 1, created: Date(), vpn: [], dns: [.init(name: "", endpoint: backup.dns[0].endpoint)]).validate() }
        var metadataOnly = ConfigurationBackup(version: 1, created: Date(), vpn: [], dns: [])
        metadataOnly.includesCredentials = false
        metadataOnly.metadata = [.init(name: "Personal VPN", kind: "vpn")]
        metadataOnly.rules = [.init(domain: "ads.example.com", action: "block", scope: "exact", enabled: false)]
        let metadataRoundtrip = try BackupCrypto.decrypt(BackupCrypto.encrypt(metadataOnly, password: password), password: password)
        check(metadataRoundtrip.vpn.isEmpty && metadataRoundtrip.dns.isEmpty && metadataRoundtrip.includesCredentials == false, "credential-free metadata roundtrip")
        check(metadataRoundtrip.rules?.first?.enabled == false, "disabled rules preserved")
        var contradictory = backup; contradictory.includesCredentials = false
        rejects("credential-free declaration rejects resolver secret") { try contradictory.validate() }
        metadataOnly.lists = [.init(name: "Private list", url: "https://example.com/token-secret")]
        rejects("credential-free declaration rejects list URL") { try metadataOnly.validate() }
        metadataOnly.lists = nil; metadataOnly.metadata = [.init(name: "Invalid", kind: "unknown")]
        rejects("unknown profile metadata type") { try metadataOnly.validate() }
        let quality = QualityResult(id: UUID(), date: Date(), status: "test", milliseconds: [100, 120, 110], failures: 2)
        check(quality.mean == 110, "mean")
        check(quality.jitter == 15, "adjacent timing variation")
        check(quality.failurePercent == 40, "HTTP failure percentage")
        let empty = QualityResult(id: UUID(), date: Date(), status: "test", milliseconds: [], failures: 5)
        check(empty.mean == nil && empty.jitter == nil && empty.failurePercent == 100, "no invented metrics for failed probes")
        check(try DNSService.domain(" EXAMPLE.COM. ") == "example.com", "domain normalization")
        rejects("invalid domain labels") { _ = try DNSService.domain("example..com") }
        var blockedReply = try DNSService.queryForDomain(id: 123, domain: "blocked.example.com")
        blockedReply[2] = 0x81; blockedReply[3] = 0x83
        check(try DNSService.validateReply(blockedReply, id: 123, domain: "blocked.example.com", expectNXDOMAIN: true) == 0, "matched NXDOMAIN")
        rejects("mismatched blocked question") { _ = try DNSService.validateReply(blockedReply, id: 123, expectNXDOMAIN: true) }
        rejects("NXDOMAIN rejected by ordinary address probe") { _ = try DNSService.validateReply(blockedReply, id: 123, domain: "blocked.example.com") }
        var addressReply = try DNSService.queryForDomain(id: 456, domain: "custom.example.com")
        addressReply[2] = 0x81; addressReply[3] = 0x80; addressReply[7] = 1
        addressReply.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1])
        check(try DNSService.validateReply(addressReply, id: 456, domain: "custom.example.com") == 1, "custom domain address response")
        let journal = RestoreJournal(version: 1, profiles: nil, dns: nil, accounts: [UUID().uuidString])
        try journal.validate(); checks += 1
        rejects("journal cannot target unrelated Keychain account") { try RestoreJournal(version: 1, profiles: nil, dns: nil, accounts: ["active-tunnel"]).validate() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VayuRestoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileURL = directory.appendingPathComponent("profiles.json"); let dnsURL = directory.appendingPathComponent("dns.json"); let journalURL = directory.appendingPathComponent("journal.json")
        let old = Data("original-metadata".utf8); let account = UUID().uuidString
        let recovery = RestoreJournal(version: 1, profiles: old, dns: nil, accounts: [account])
        try LocalFiles.write(JSONEncoder().encode(recovery), to: journalURL)
        try LocalFiles.write(Data("partially-restored".utf8), to: profileURL)
        try LocalFiles.write(Data("new-resolver-metadata".utf8), to: dnsURL)
        var deleted: [String] = []
        try RestoreRecovery.rollback(journalURL: journalURL, profilesURL: profileURL, dnsURL: dnsURL) { deleted.append($0) }
        check(try Data(contentsOf: profileURL) == old, "interrupted restore reinstates original metadata")
        check(!FileManager.default.fileExists(atPath: dnsURL.path), "interrupted restore removes originally absent metadata")
        check(deleted == [account], "cleanup targets only generated credential account")
        check(!FileManager.default.fileExists(atPath: journalURL.path), "successful rollback removes journal")
        try LocalFiles.write(JSONEncoder().encode(recovery), to: journalURL)
        rejects("failed credential cleanup retains journal") { try RestoreRecovery.rollback(journalURL: journalURL, profilesURL: profileURL, dnsURL: dnsURL) { _ in throw AppIssue(message: "injected cleanup failure") } }
        check(FileManager.default.fileExists(atPath: journalURL.path), "failed cleanup preserves recovery journal")
        try RestoreRecovery.rollback(journalURL: journalURL, profilesURL: profileURL, dnsURL: dnsURL) { _ in }
        check(!FileManager.default.fileExists(atPath: journalURL.path), "retry recovers failed cleanup")
        print("Feature checks passed: \(checks)")
    }
}
