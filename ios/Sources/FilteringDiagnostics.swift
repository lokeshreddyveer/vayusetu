import Foundation
import Combine

enum FilteringVerdict: String, Codable { case passed = "Passed", failed = "Failed", inconclusive = "Inconclusive" }
enum DNSFilterObservation: String, Codable { case resolved, blocked, absent, inconclusive
    static func parse(_ data: Data, id: UInt16, domain: String, type: DNSRecordType) throws -> DNSFilterObservation {
        let b = Array(data)
        guard b.count >= 12, b.count <= 65535, UInt16(b[0]) << 8 | UInt16(b[1]) == id, b[2] & 0x80 != 0, b[2] & 0x7a == 0, b[4] == 0, b[5] == 1 else { throw AppIssue(message: "Invalid DNS reply.") }
        var offset = 12
        guard try DNSService.readName(b, offset: &offset) == DNSService.domain(domain), offset + 4 <= b.count, Array(b[offset..<offset+4]) == [0, UInt8(type.rawValue), 0, 1] else { throw AppIssue(message: "Mismatched DNS question.") }
        offset += 4
        let rcode = b[3] & 15
        if (rcode == 3 || rcode == 5) && b[6] == 0 && b[7] == 0 { return .blocked }
        guard rcode == 0 else { return .inconclusive }
        if b[6] == 0 && b[7] == 0 { return .absent }
        _ = try DNSService.validateReply(data, id: id, recordType: type, domain: domain)
        var names: Set<String> = [try DNSService.domain(domain)]; var addresses: [[UInt8]] = []
        for _ in 0..<(Int(b[6]) * 256 + Int(b[7])) {
            let owner = try DNSService.readName(b, offset: &offset)
            guard offset + 10 <= b.count else { throw AppIssue(message: "Truncated DNS record.") }
            let recordType = Int(b[offset]) * 256 + Int(b[offset + 1]); let cls = Int(b[offset+2]) * 256 + Int(b[offset+3]); let length = Int(b[offset+8]) * 256 + Int(b[offset+9]); offset += 10
            guard offset + length <= b.count else { throw AppIssue(message: "Truncated DNS answer.") }
            if names.contains(owner), cls == 1 {
                if recordType == Int(type.rawValue) { addresses.append(Array(b[offset..<offset+length])) }
                if recordType == 5 { var next = offset; let cname = try DNSService.readName(b, offset: &next); guard next == offset + length else { throw AppIssue(message: "Invalid CNAME.") }; names.insert(cname) }
            }
            offset += length
        }
        guard !addresses.isEmpty else { return .inconclusive }
        // Only explicit zero-address sinks count. Arbitrary redirects are not assumed blocked.
        return addresses.allSatisfy { $0.allSatisfy { $0 == 0 } } ? .blocked : .resolved
    }
    static func verdict(control: [DNSFilterObservation], target: [DNSFilterObservation]) -> FilteringVerdict {
        guard control.count == 2, target.count == 2, control.contains(.resolved), control.allSatisfy({ $0 == .resolved || $0 == .absent }) else { return .inconclusive }
        if target.contains(.resolved) { return .failed }
        return zip(control, target).allSatisfy { control, target in control == .resolved ? target == .blocked : (target == .blocked || target == .absent) } ? .passed : .inconclusive
    }
}
struct DNSFilterMeasurement: Codable {
    let recordType: String
    let date: Date
    let milliseconds: Int
    let observation: DNSFilterObservation
    let responseCode: Int?
    let error: String?
    var description: String {
        "\(recordType) · \(observation.rawValue) · RCODE \(responseCode.map(String.init) ?? "unavailable") · \(milliseconds) ms · \(date.formatted(.iso8601))" + (error.map { "\n" + $0 } ?? "")
    }
}
struct FilteringResult: Codable, Identifiable {
    let id: UUID
    let profileID: UUID
    let category: String
    let domain: String
    let verdict: FilteringVerdict
    let detail: String
    var targetMeasurements: [DNSFilterMeasurement]? = nil
    var referenceMeasurements: [DNSFilterMeasurement]? = nil
}
struct FilteringRun: Codable, Identifiable {
    let id: UUID
    let date: Date
    let tunnelStatus: String
    let results: [FilteringResult]
}
@MainActor final class FilteringDiagnostics: ObservableObject {
    @Published private(set) var history: [FilteringRun] = []
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    private var writable = true
    private var task: Task<Void, Never>?
    init() {
        let url = LocalFiles.url("filtering-history.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { history = Array(try JSONDecoder().decode([FilteringRun].self, from: LocalFiles.read(url, maximum: 512_000)).prefix(30)) }
            catch { writable = false; progress = "Stored test history is unreadable and has been preserved." }
        }
    }
    func cancel() { task?.cancel() }
    func clear() {
        guard !running else { return }
        do { let url = LocalFiles.url("filtering-history.json"); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }; history = []; writable = true; progress = "History cleared." } catch { progress = "Could not clear local history." }
    }
    func run(targets: [(UUID, URL)], reference: URL?, tests: [(String, String)], status: String) {
        guard !running, !targets.isEmpty, targets.count <= 10 else { return }
        running = true
        // Capture endpoints; never switch the active resolver or change VPN settings.
        task = Task {
            defer { running = false; task = nil }
            var results: [FilteringResult] = []
            for (category, domain) in tests {
                if Task.isCancelled { progress = "Cancelled; partial results discarded."; return }
                let valid = (try? DNSService.domain(domain)) != nil
                let controlMeasurements: [DNSFilterMeasurement]
                if valid, let reference { controlMeasurements = await Self.observeDetailed(reference, domain: domain) } else { controlMeasurements = [] }
                let control = controlMeasurements.map(\.observation)
                for (id, url) in targets {
                    progress = "Checking \(category)…"
                    let targetMeasurements = valid ? await Self.observeDetailed(url, domain: domain) : []
                    let observed = targetMeasurements.map(\.observation)
                    if Task.isCancelled { progress = "Cancelled; partial results discarded."; return }
                    let verdict = DNSFilterObservation.verdict(control: control, target: observed)
                    let detail = !valid ? "Configure a provider-supported or controlled test domain." : reference == nil ? "No reference resolver selected. Blocking cannot be distinguished from a nonexistent domain." : control.count != 2 || !control.contains(.resolved) || !control.allSatisfy({ $0 == .resolved || $0 == .absent }) ? "Reference did not establish a resolvable control domain. Result is inconclusive." : verdict == .passed ? "Reference resolves the domain; target returns NXDOMAIN, REFUSED or zero-address sinks for all available address families. Consistent with DNS blocking of this test domain." : verdict == .failed ? "Target returned at least one address despite the expected block. This test domain is not fully blocked at DNS level." : "At least one response failed or could not be classified."
                    results.append(FilteringResult(id: UUID(), profileID: id, category: category, domain: valid ? domain : "", verdict: verdict, detail: detail, targetMeasurements: targetMeasurements, referenceMeasurements: controlMeasurements))
                }
            }
            let result = FilteringRun(id: UUID(), date: Date(), tunnelStatus: status, results: results)
            history.insert(result, at: 0); history = Array(history.prefix(30)); progress = "DNS-only checks completed. Results cover the configured test domains, not the entire category."
            if writable { do { try LocalFiles.write(JSONEncoder().encode(history), to: LocalFiles.url("filtering-history.json")) } catch { progress = "Tests completed; local history could not be saved." } }
        }
    }
    nonisolated static func observe(_ url: URL, domain: String) async -> [DNSFilterObservation] {
        await observeDetailed(url, domain: domain).map(\.observation)
    }
    nonisolated static func observeDetailed(_ url: URL, domain: String) async -> [DNSFilterMeasurement] {
        var values: [DNSFilterMeasurement] = []
        for type in [DNSRecordType.a, .aaaa] {
            if Task.isCancelled { return [] }
            let date = Date(); let start = ContinuousClock.now
            var observation: DNSFilterObservation = .inconclusive; var code: Int?; var failure: String?
            do {
                let (id, reply) = try await DNSService.exchange(url, recordType: type, domain: domain)
                observation = try DNSFilterObservation.parse(reply, id: id, domain: domain, type: type)
                code = Int(reply[3] & 15)
            } catch {
                // Errors may contain personalized resolver URLs: only sanitized domain/code escapes.
                failure = IPFailure.classify(error).errorDescription
            }
            let duration = start.duration(to: .now).components
            values.append(DNSFilterMeasurement(recordType: type.title, date: date, milliseconds: Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000), observation: observation, responseCode: code, error: failure))
        }
        return values
    }
    var sanitizedReport: String { history.map { run in "\(run.date.formatted(.iso8601))\n" + run.results.map { "Profile \($0.profileID.uuidString) · \($0.category) · \($0.verdict.rawValue)\n\($0.detail)\nTarget: \(($0.targetMeasurements ?? []).map(\.description).joined(separator: "\n"))\nReference: \(($0.referenceMeasurements ?? []).map(\.description).joined(separator: "\n"))" }.joined(separator: "\n") }.joined(separator: "\n\n") + "\nDNS-only sampled checks. Resolver endpoints and custom domains omitted. No browser or device-wide protection score." }
}
