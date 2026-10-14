import XCTest
@testable import VayuSetuCore
final class CoreTests: XCTestCase {
    func testSecurityEvidenceCannotBeInferredFromTunnelOrResolver() {
        XCTAssertFalse(HealthPolicy.complete([Evidence("Handshake", .passed, "adapter"), Evidence("Resolver response", .passed, "HTTPS")]))
    }
    func testRetryBudgetAndBounds() {
        let retry = RetryPolicy(maximumAttempts: 3)
        XCTAssertEqual(retry.delay(after: 0), 1)
        XCTAssertEqual(retry.delay(after: 2), 4)
        XCTAssertNil(retry.delay(after: 3))
        XCTAssertNil(retry.delay(after: -1))
    }
    func testConfigurationRoundTrip() throws {
        let profile = DNSProfile(id: UUID(), name: "Custom resolver")
        let archive = DNSArchive(version: 1, profiles: [profile])
        let decoded = try JSONDecoder().decode(DNSArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(decoded.profiles.first, profile)
    }
    func testLegacyResolverAndBootstrapRoundTrip() throws {
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Resolver\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(DNSProfile.self, from: legacy).bootstrapAddresses)
        let configured = DNSProfile(id: id, name: "Resolver", bootstrapAddresses: ["1.1.1.1", "2606:4700:4700::1111"])
        XCTAssertEqual(try JSONDecoder().decode(DNSProfile.self, from: JSONEncoder().encode(configured)), configured)
    }
}
