import Foundation
import CryptoKit
import CommonCrypto
import Security

struct ConfigurationBackup: Codable, Sendable {
    struct VPN: Codable, Sendable { let name: String; let configuration: String }
    struct DNS: Codable, Sendable { let name: String; let endpoint: String; var bootstrapAddresses: [String]? = nil }
    struct ProfileMetadata: Codable, Sendable { let name: String; let kind: String }
    struct RuleMetadata: Codable, Sendable { let domain: String; let action: String; let scope: String; let enabled: Bool }
    struct ListMetadata: Codable, Sendable { let name: String; let url: String? }
    var nativeIKEv2: [ManualVPNDraft]? = nil
    var metadata: [ProfileMetadata]? = nil
    var rules: [RuleMetadata]? = nil
    var lists: [ListMetadata]? = nil
    var includesCredentials: Bool? = nil
    let version: Int
    let created: Date
    let vpn: [VPN]
    let dns: [DNS]
    func validate() throws {
        guard [1, 2].contains(version), vpn.count <= 50, dns.count <= 50, (nativeIKEv2?.count ?? 0) <= 100 else { throw AppIssue(message: "Unsupported backup or too many profiles (maximum 50 of each).") }
        guard (metadata?.count ?? 0) <= 200, (rules?.count ?? 0) <= 50_000, (lists?.count ?? 0) <= 100 else { throw AppIssue(message: "Backup metadata exceeds its safety limits.") }
        for item in metadata ?? [] { try Self.validateName(item.name, maximumBytes: item.kind == "ikev2" ? 128 : 80); guard (version == 2 ? ["vpn", "dns", "ikev2"] : ["vpn", "dns"]).contains(item.kind) else { throw AppIssue(message: "Unknown metadata profile type.") } }
        for item in rules ?? [] { guard !item.domain.isEmpty, item.domain.utf8.count <= 253, ["allow", "block"].contains(item.action), ["exact", "domainAndSubdomains"].contains(item.scope) else { throw AppIssue(message: "Invalid backup rule.") } }
        for item in lists ?? [] { try Self.validateName(item.name); if let source = item.url { guard source.utf8.count <= 4096, let url = URL(string: source), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw AppIssue(message: "Invalid backup list source.") } } }
        if includesCredentials == false && (!vpn.isEmpty || !dns.isEmpty || !(nativeIKEv2 ?? []).isEmpty || (lists ?? []).contains(where: { $0.url != nil })) { throw AppIssue(message: "Credential-free backup contains secret-bearing configuration.") }
        if let nativeIKEv2 {
            guard version == 2 else { throw AppIssue(message: "IKEv2 backups require the newer backup format.") }
            for item in nativeIKEv2 { guard item.protocolKind == .ikev2 else { throw AppIssue(message: "Unsupported native backup protocol.") }; try item.validate() }
        }
        for item in vpn {
            try Self.validateName(item.name)
            _ = try ProfileParser.parse(item.configuration)
        }
        for item in dns { try Self.validateName(item.name); _ = try DNSService.endpoint(item.endpoint); if let addresses = item.bootstrapAddresses, !addresses.isEmpty { _ = try ResolverBootstrap.validated(addresses) } }
    }
    private static func validateName(_ name: String, maximumBytes: Int = 80) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= maximumBytes else { throw AppIssue(message: "Backup contains an invalid profile name.") }
    }
}

enum BackupCrypto {
    // The fixed KDF budget prevents attacker-controlled backups requesting excessive work.
    private static let rounds: UInt32 = 600_000
    private static let magic = Data("VAYUSETU-BACKUP-1".utf8)
    private struct Envelope: Codable { let version: Int; let rounds: UInt32; let salt: Data; let sealed: Data }
    static func key(password: String, salt: Data) throws -> SymmetricKey {
        guard password.utf8.count >= 12, password.utf8.count <= 1024, salt.count == 32 else { throw AppIssue(message: "Use a password of 12–1024 UTF-8 bytes.") }
        let passwordBytes = Array(password.utf8); var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { p in salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress!.assumingMemoryBound(to: Int8.self), p.count, s.baseAddress!.assumingMemoryBound(to: UInt8.self), s.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count)
        } }
        guard status == kCCSuccess else { throw AppIssue(message: "Could not derive the backup encryption key.") }
        defer { _ = derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return SymmetricKey(data: derived)
    }
    static func encrypt(_ backup: ConfigurationBackup, password: String) throws -> Data {
        try backup.validate()
        let plain = try JSONEncoder().encode(backup)
        guard plain.count <= 8_000_000 else { throw AppIssue(message: "Backup exceeds the 8 MB limit.") }
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AppIssue(message: "Could not generate backup encryption randomness.") }
        let sealed = try AES.GCM.seal(plain, using: key(password: password, salt: salt), authenticating: magic + salt)
        guard let combined = sealed.combined else { throw AppIssue(message: "Could not encrypt the backup.") }
        return try JSONEncoder().encode(Envelope(version: 1, rounds: rounds, salt: salt, sealed: combined))
    }
    static func decrypt(_ data: Data, password: String) throws -> ConfigurationBackup {
        guard data.count <= 12_000_000 else { throw AppIssue(message: "Backup exceeds the 12 MB file limit.") }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.rounds == rounds, envelope.salt.count == 32, envelope.sealed.count <= 8_000_028 else { throw AppIssue(message: "Unsupported backup format.") }
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key(password: password, salt: envelope.salt), authenticating: magic + envelope.salt)
            let backup = try JSONDecoder().decode(ConfigurationBackup.self, from: plain)
            try backup.validate(); return backup
        } catch { throw AppIssue(message: "Could not open backup. Check the password and file integrity.") }
    }
}

struct RestoreJournal: Codable {
    let version: Int
    let profiles: Data?
    let dns: Data?
    var nativeProfiles: Data? = nil
    let accounts: [String]
    func validate() throws {
        guard [1, 2].contains(version), (version == 2 || nativeProfiles == nil), accounts.count <= 200, (nativeProfiles?.count ?? 0) <= 128_000, (profiles?.count ?? 0) <= 2_000_000, (dns?.count ?? 0) <= 256_000,
              Set(accounts).count == accounts.count, accounts.allSatisfy({ account in
                  let identifier = account.hasPrefix("manual-vpn-") && version == 2 ? String(account.dropFirst(11)) : account.hasPrefix("dns-") ? String(account.dropFirst(4)) : account
                  return UUID(uuidString: identifier) != nil
              }) else { throw AppIssue(message: "Interrupted restore journal is invalid; saved data has been preserved.") }
    }
}

// Cleanup is injected so interrupted-restore behavior can be tested without touching the real Keychain.
enum RestoreRecovery {
    static func rollback(journalURL: URL, profilesURL: URL, dnsURL: URL, nativeURL: URL? = nil, deleteAccount: (String) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let journal = try JSONDecoder().decode(RestoreJournal.self, from: LocalFiles.read(journalURL, maximum: 4_000_000))
        try journal.validate()
        if journal.version == 2 && nativeURL == nil { throw AppIssue(message: "Native restore recovery requires its metadata path.") }
        var files = [(profilesURL, journal.profiles), (dnsURL, journal.dns)]
        if journal.version == 2, let nativeURL { files.append((nativeURL, journal.nativeProfiles)) }
        for (url, data) in files {
            if let data { try LocalFiles.write(data, to: url) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        for account in journal.accounts { try deleteAccount(account) }
        try FileManager.default.removeItem(at: journalURL)
    }
}

/// A profile-specific export uses the same encrypted container and additive restore path.
enum NativeProfileBackup {
    static func snapshot(_ profile: ManualVPNDraft, includeCredentials: Bool) throws -> ConfigurationBackup {
        guard profile.protocolKind == .ikev2 else { throw AppIssue(message: "Only IKEv2 profile export is available.") }
        var backup = ConfigurationBackup(version: 2, created: Date(), vpn: [], dns: [])
        backup.includesCredentials = includeCredentials
        if includeCredentials { try profile.validate(); backup.nativeIKEv2 = [profile] }
        else { backup.metadata = [.init(name: profile.name, kind: "ikev2")] }
        try backup.validate(); return backup
    }
}
