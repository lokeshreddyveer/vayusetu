import CryptoKit
import Foundation

/// A signed, portable policy envelope for managed deployments. The policy is
/// intentionally capability based: clients ignore fields they cannot enforce
/// and must report that limitation instead of claiming equivalent protection.
public struct EnterprisePolicy: Codable, Equatable, Sendable {
    public enum NetworkDefault: String, Codable, Sendable { case allow, block, ask }
    public let id: String
    public let revision: Int
    public let issuedAt: Date
    public let expiresAt: Date?
    public let networkDefault: NetworkDefault
    public let allowAppleSigned: Bool
    public let userMayOverride: Bool
    public let managedListURLs: [String]
    public let blockedApplications: [String]
    public let allowedApplications: [String]

    public init(id: String, revision: Int, issuedAt: Date = .now, expiresAt: Date? = nil,
                networkDefault: NetworkDefault = .ask, allowAppleSigned: Bool = true,
                userMayOverride: Bool = true, managedListURLs: [String] = [],
                blockedApplications: [String] = [], allowedApplications: [String] = []) {
        self.id = id; self.revision = revision; self.issuedAt = issuedAt; self.expiresAt = expiresAt
        self.networkDefault = networkDefault; self.allowAppleSigned = allowAppleSigned
        self.userMayOverride = userMayOverride; self.managedListURLs = managedListURLs
        self.blockedApplications = blockedApplications; self.allowedApplications = allowedApplications
    }
    public func validate(now: Date = .now) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, revision >= 0 else { throw PolicyError.invalid("Policy identity or revision is invalid.") }
        guard expiresAt.map({ $0 > now }) ?? true else { throw PolicyError.expired }
        guard managedListURLs.allSatisfy({ URL(string: $0)?.scheme?.lowercased() == "https" }) else { throw PolicyError.invalid("Managed filter lists must use HTTPS.") }
        guard Set(blockedApplications).isDisjoint(with: allowedApplications) else { throw PolicyError.invalid("An application cannot be both allowed and blocked.") }
    }
}

public struct SignedEnterprisePolicy: Codable, Sendable {
    public let payload: Data
    public let signature: Data
    public let keyID: String
    public init(policy: EnterprisePolicy, privateKey: P256.Signing.PrivateKey, keyID: String) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        payload = try encoder.encode(policy); signature = try privateKey.signature(for: payload).derRepresentation; self.keyID = keyID
    }
    public init(payload: Data, signature: Data, keyID: String) { self.payload = payload; self.signature = signature; self.keyID = keyID }
    public func verify(publicKey: P256.Signing.PublicKey, now: Date = .now) throws -> EnterprisePolicy {
        guard !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PolicyError.invalid("Policy key identity is missing.") }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard publicKey.isValidSignature(signature, for: payload) else { throw PolicyError.invalid("Policy signature is invalid.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let policy = try decoder.decode(EnterprisePolicy.self, from: payload); try policy.validate(now: now); return policy
    }
}

public enum PolicyError: Error, LocalizedError, Sendable {
    case invalid(String), expired
    public var errorDescription: String? { switch self { case .invalid(let text): text; case .expired: "The enterprise policy has expired." } }
}

/// Append-only audit entries with a hash chain. The chain detects local edits;
/// it is not a replacement for a remote SIEM or an OS security log.
public struct EnterpriseAuditEvent: Codable, Sendable, Equatable {
    public let time: Date
    public let actor: String
    public let action: String
    public let detail: String
    public let previousHash: String?
    public let hash: String
    public init(time: Date = .now, actor: String, action: String, detail: String, previousHash: String? = nil) {
        self.time = time; self.actor = actor; self.action = action; self.detail = detail; self.previousHash = previousHash
        let chain = previousHash ?? ""
        let material = "\(time.timeIntervalSince1970)|\(actor)|\(action)|\(detail)|\(chain)"
        self.hash = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func verifies() -> Bool {
        EnterpriseAuditEvent(time: time, actor: actor, action: action, detail: detail, previousHash: previousHash).hash == hash
    }
}
