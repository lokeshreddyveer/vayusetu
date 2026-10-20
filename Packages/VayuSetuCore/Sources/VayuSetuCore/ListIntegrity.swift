import CryptoKit
import Foundation

public struct SignedListManifest: Codable, Sendable, Equatable {
    public let source: String
    public let sha256: String
    public let keyID: String
    public let signature: Data
    public init(source: String, sha256: String, keyID: String, signature: Data) {
        self.source = source; self.sha256 = sha256.lowercased(); self.keyID = keyID; self.signature = signature
    }
    public func verify(data: Data, publicKey: P256.Signing.PublicKey) throws {
        guard !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: source), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else {
            throw PolicyError.invalid("Filter list manifest identity or source is invalid.")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == sha256 else { throw PolicyError.invalid("Filter list checksum does not match its manifest.") }
        let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard publicKey.isValidSignature(sig, for: Data((source + "\n" + sha256).utf8)) else { throw PolicyError.invalid("Filter list manifest signature is invalid.") }
    }
}
