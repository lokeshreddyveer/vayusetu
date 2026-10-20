import CryptoKit
import XCTest
@testable import VayuSetuCore

final class EnterprisePolicyTests: XCTestCase {
    func testSignedPolicyRoundTripAndTamperRejection() throws {
        let key = P256.Signing.PrivateKey()
        let policy = EnterprisePolicy(id: "fixture", revision: 2, networkDefault: .block, managedListURLs: ["https://example.com/list.txt"])
        let signed = try SignedEnterprisePolicy(policy: policy, privateKey: key, keyID: "fixture-key")
        XCTAssertEqual(try signed.verify(publicKey: key.publicKey).revision, 2)
        var tampered = signed
        tampered = SignedEnterprisePolicy(payload: Data("{}".utf8), signature: signed.signature, keyID: signed.keyID)
        XCTAssertThrowsError(try tampered.verify(publicKey: key.publicKey))
    }

    func testAuditHashChainDetectsMutation() {
        let first = EnterpriseAuditEvent(actor: "system", action: "policy.applied", detail: "fixture")
        let second = EnterpriseAuditEvent(actor: "user", action: "rule.blocked", detail: "example.com", previousHash: first.hash)
        XCTAssertTrue(first.verifies()); XCTAssertTrue(second.verifies())
        let changed = EnterpriseAuditEvent(time: second.time, actor: second.actor, action: "rule.allowed", detail: second.detail, previousHash: second.previousHash)
        XCTAssertNotEqual(changed.hash, second.hash)
    }

    func testManagedListManifestBindsSourceAndChecksum() throws {
        let key = P256.Signing.PrivateKey()
        let data = Data("example.com\n".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let signature = try key.signature(for: Data(("https://example.com/list.txt" + "\n" + digest).utf8)).derRepresentation
        let manifest = SignedListManifest(source: "https://example.com/list.txt", sha256: digest, keyID: "fixture", signature: signature)
        XCTAssertNoThrow(try manifest.verify(data: data, publicKey: key.publicKey))
        XCTAssertThrowsError(try manifest.verify(data: Data("changed\n".utf8), publicKey: key.publicKey))
    }
}
