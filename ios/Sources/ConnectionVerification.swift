import Foundation
import Combine
import Darwin

/// A match describes only the sampled request, never device-wide leak protection.
enum ExitComparison: String {
    case matched = "Expected exit matched", mismatch = "Unexpected exit", missing = "Expected exit not set", unavailable = "Inconclusive"
    static func canonical(_ value: String, family: Int) -> String? {
        guard let family = IPFamily(rawValue: family) else { return nil }
        return PublicIPProbe.canonical(value, family: family)
    }

    static func evaluate(observed: String?, expected: String, family: Int) -> ExitComparison {
        guard let observed, let address = canonical(observed, family: family) else { return .unavailable }
        let values = expected.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !values.isEmpty else { return .missing }
        let parsed = values.compactMap { canonical($0, family: family) }
        guard parsed.count == values.count, parsed.count <= 16 else { return .unavailable }
        return parsed.contains(address) ? .matched : .mismatch
    }
}
struct VerificationSample {
    let date: Date
    let connected: Bool
    let ipv4Result: IPProbeResult
    let ipv6Result: IPProbeResult
    var ipv4: String? { ipv4Result.address }
    var ipv6: String? { ipv6Result.address }
    let controlDEvidence: Bool?
    var network: String = "Not recorded"
    var routingMode: String = "Not recorded"
}
/// getaddrinfo runs off the UI thread. A once-only gate bounds the UI wait even
/// when the OS resolver stalls; the OS operation itself cannot be cancelled.
private final class ResolverReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String]?, Never>?
    init(_ continuation: CheckedContinuation<[String]?, Never>) { self.continuation = continuation }
    func finish(_ values: [String]?) { lock.lock(); let current = continuation; continuation = nil; lock.unlock(); current?.resume(returning: values) }
}
@MainActor final class ConnectionVerification: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var sample: VerificationSample?
    @Published private(set) var baseline: VerificationSample?
    @Published private(set) var message = ""
    private var revision = UUID()
    private var task: Task<Void, Never>?
    func invalidate() { revision = UUID(); task?.cancel(); sample = nil; message = "Connection or configuration changed. Run verification again." }
    func run(connected: Bool, captureBaseline: Bool = false, ipv6Supported: Bool? = nil, network: String = "Not recorded", routingMode: String = "Not recorded") {
        guard !running else { return }
        guard !captureBaseline || !connected else { message = "Disconnect the VPN before capturing a baseline."; return }
        guard network != "Network unavailable" && network != "Checking network…" else { message = "Wait for a usable network before measuring."; return }
        running = true; sample = nil; message = "Checking IPv4, IPv6 and the system DNS path…"
        let token = revision
        task = Task {
            defer { running = false; task = nil }
            async let v4 = PublicIPProbe.run(.ipv4)
            async let v6 = PublicIPProbe.run(.ipv6, ipv6Supported: ipv6Supported)
            async let dns = Self.controlDSystemEvidence()
            let result = await VerificationSample(date: Date(), connected: connected, ipv4Result: v4, ipv6Result: v6, controlDEvidence: dns, network: network, routingMode: routingMode)
            guard !Task.isCancelled, revision == token else { return }
            sample = result
            if captureBaseline && !connected {
                guard result.ipv4 != nil || result.ipv6 != nil else { baseline = nil; message = "No public address was discovered; baseline not captured. Inspect the per-family failure details."; return }
                baseline = result
            }
            message = "Completed. Results apply to this app and this sampled DNS path; other apps may override DNS."
        }
    }
    nonisolated static func controlDSystemEvidence() async -> Bool? {
        let addresses: [String]? = await withCheckedContinuation { continuation in
            let gate = ResolverReply(continuation)
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
                var head: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo("verify.controld.com", nil, &hints, &head) == 0, let head else { gate.finish(nil); return }
                defer { freeaddrinfo(head) }
                var addresses: [String] = []; var node: UnsafeMutablePointer<addrinfo>? = head
                while let current = node {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { addresses.append(String(cString: host)) }
                    node = current.pointee.ai_next
                }
                gate.finish(addresses)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { gate.finish(nil) }
        }
        guard let addresses, !addresses.isEmpty else { return nil }
        return addresses.contains("147.185.34.1") || addresses.contains("2606:1a40:3::1")
    }
    func comparableBaseline(family: Int) -> String? {
        guard let sample, let baseline else { return nil }
        return Self.baselineAddress(sample: sample, baseline: baseline, family: family)
    }
    nonisolated static func baselineAddress(sample: VerificationSample, baseline: VerificationSample, family: Int) -> String? {
        guard sample.connected, !baseline.connected, baseline.network == sample.network,
              sample.network != "Not recorded", sample.date.timeIntervalSince(baseline.date) >= 0,
              sample.date.timeIntervalSince(baseline.date) <= 900 else { return nil }
        return family == 4 ? baseline.ipv4 : family == 6 ? baseline.ipv6 : nil
    }
    var sanitizedReport: String {
        guard let sample else { return "Connection verification: no current results." }
        return "VayuSetu connection verification\nMeasured: \(sample.date.formatted(.iso8601))\nNetwork: \(sample.network)\nRouting mode: \(sample.routingMode)\nTunnel established at start: \(sample.connected)\nIPv4 response: \(sample.ipv4 != nil)\n\(sample.ipv4Result.detail)\nIPv6 response: \(sample.ipv6 != nil)\n\(sample.ipv6Result.detail)\nControl D system-DNS evidence: \(sample.controlDEvidence.map { $0 ? "detected" : "not detected" } ?? "inconclusive")\nMethod: family-specific HTTPS public services plus a system-resolver verification name. OS routing and TLS validation remain enabled.\nDNS routing and device-wide leaks: unverified; requires controlled packet-path or provider-side evidence.\nBaseline: \(baseline?.date.formatted(.iso8601) ?? "not captured"); useful only as sampled address-change evidence, not a prerequisite or isolation proof.\nPublic IP addresses, VPN keys and resolver credentials omitted."
    }
}

// Provider checks observe the application's current system route. They never query an
// alternate DoH resolver, install DNS settings, or substitute an IP address to obtain a match.
enum DNSProviderSite: String, CaseIterable, Identifiable, Sendable {
    case controlD = "Control D", nextDNS = "NextDNS", adguard = "AdGuard", cloudflare = "Cloudflare", quad9 = "Quad9", browserLeaks = "BrowserLeaks", dnsLeakTest = "DNSLeakTest"
    var id: String { rawValue }
    var website: URL { URL(string: {
        switch self {
        case .controlD: return "https://controld.com/status"
        case .nextDNS: return "https://test.nextdns.io/"
        case .adguard: return "https://adguard.com/en/test.html"
        case .cloudflare: return "https://one.one.one.one/help"
        case .quad9: return "https://on.quad9.net/"
        case .browserLeaks: return "https://browserleaks.com/dns"
        case .dnsLeakTest: return "https://www.dnsleaktest.com/"
        }
    }())! }
    static let providers: [Self] = [.controlD, .nextDNS, .adguard, .cloudflare, .quad9]
    static func selected(endpoint: String) -> Self? {
        guard let host = URL(string: endpoint)?.host?.lowercased() else { return nil }
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if matches("controld.com") { return .controlD }
        if matches("nextdns.io") { return .nextDNS }
        if matches("adguard-dns.com") || matches("adguard.com") { return .adguard }
        if matches("cloudflare-dns.com") || matches("one.one.one.one") { return .cloudflare }
        if matches("quad9.net") { return .quad9 }
        return nil
    }
}
enum ProviderVerdict: String, Sendable { case detected = "Detected", notDetected = "Not detected", inconclusive = "Inconclusive", websiteRequired = "Website test required" }
struct ProviderObservation: Identifiable, Sendable {
    let provider: DNSProviderSite
    let verdict: ProviderVerdict
    let date: Date
    let method: String
    let detail: String
    var id: DNSProviderSite { provider }
}
private final class ProviderHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum ProviderVerificationProbe {
    static let maximumBytes = 128_000
    // Never retain IPs, profile/device IDs, raw bodies or server-provided account metadata.
    static func parse(_ data: Data, provider: DNSProviderSite) -> (ProviderVerdict, String) {
        guard data.count <= maximumBytes else { return (.inconclusive, "Response exceeded the safety limit.") }
        if provider == .quad9 {
            guard let text = String(data: data, encoding: .utf8), let regex = try? NSRegularExpression(pattern: "<h1(?:\\s[^>]*)?>\\s*(YES|NO)\\s*</h1>", options: [.caseInsensitive]), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return (.inconclusive, "Quad9 page format was not recognized. Open its official website.") }
            let detected = text[range].uppercased() == "YES"
            return (detected ? .detected : .notDetected, "Quad9's DNS-sensitive test page returned " + (detected ? "Yes." : "No. This is not proof of a DNS leak."))
        }
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (.inconclusive, "Expected verification JSON was not returned.") }
        if provider == .nextDNS {
            guard let status = body["status"] as? String else { return (.inconclusive, "NextDNS status was missing.") }
            switch status {
            case "ok": return (.detected, "NextDNS reported OK for its randomized DNS test. Profile identity is not retained.")
            case "ko": return (.notDetected, "NextDNS reported a negative test. This does not identify the replacement resolver.")
            case "unconfigured": return (.inconclusive, "NextDNS reported unconfigured; the selected profile was not confirmed.")
            default: return (.inconclusive, "NextDNS returned an unknown status.")
            }
        }
        if provider == .adguard {
            guard let server = body["server_name"] as? String, let protocolName = body["protocol"] as? String else { return (.inconclusive, "AdGuard's server/protocol fields were missing.") }
            let type = String(server.split(separator: "_").first ?? "")
            let transport = String(protocolName.split(separator: "-").first ?? "")
            guard ["dns", "doh", "doh2", "doh3", "dot", "doq", "dnscrypt"].contains(transport) else { return (.inconclusive, "AdGuard returned an unknown transport.") }
            if type == "disabled" { return (.notDetected, "AdGuard reported disabled for this sampled path.") }
            guard ["regular", "family", "unfiltered", "clients"].contains(type) else { return (.inconclusive, "AdGuard returned an unknown service type.") }
            return (.detected, "AdGuard reported " + type + " service over " + transport.uppercased() + ". Device/account identifiers are omitted.")
        }
        return (.inconclusive, "No validated parser for this response.")
    }
    static func nextDNSHandoff(_ data: Data) -> URL? {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8), let regex = try? NSRegularExpression(pattern: "https://([a-z0-9]{1,63})\\.test\\.nextdns\\.io/"), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) else { return nil }
        // Only the provider's published random-host handshake is followed, never arbitrary JS.
        return URL(string: String(text[range]))
    }
    static func fetch(_ url: URL) async throws -> Data {
        let delegate = ProviderHTTPDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NSError(domain: "VayuSetu.Provider", code: 1) }
        guard http.statusCode == 200 else { throw NSError(domain: "VayuSetu.Provider.HTTP", code: http.statusCode) }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw NSError(domain: "VayuSetu.Provider", code: 2) }
        var data = Data()
        for try await byte in bytes { try Task.checkCancellation(); guard data.count < maximumBytes else { throw NSError(domain: "VayuSetu.Provider", code: 2) }; data.append(byte) }
        return data
    }
    static func run(_ provider: DNSProviderSite) async -> ProviderObservation {
        let method: String
        switch provider {
        case .controlD: method = "Published system-resolver verification name"
        case .nextDNS: method = "Official randomized-host HTTPS test"
        case .adguard: method = "Official randomized DNS-check endpoint"
        case .quad9: method = "Official DNS-sensitive HTTPS test page"
        default: method = "Embedded official website"
        }
        if provider == .controlD {
            let evidence = await ConnectionVerification.controlDSystemEvidence()
            // Control D documents that a missing verification answer cannot distinguish
            // a different resolver from DNS/service failure, so it is never a negative proof.
            return .init(provider: provider, verdict: evidence == true ? .detected : .inconclusive, date: Date(), method: method, detail: evidence == true ? "Published Control D verification address observed through system DNS. Cache and upstream forwarding may affect the sample." : "Published Control D identity was not confirmed. Use its Status page and compare ordinary DNS connectivity.")
        }
        if provider == .cloudflare || !DNSProviderSite.providers.contains(provider) {
            return .init(provider: provider, verdict: .websiteRequired, date: Date(), method: method, detail: "Run the actual website's JavaScript test below. Page reachability and Cloudflare hosting are not DNS identity evidence.")
        }
        do {
            let data: Data
            if provider == .nextDNS {
                let initial = try await fetch(provider.website)
                if let target = nextDNSHandoff(initial) { data = try await fetch(target) } else { data = initial }
            } else if provider == .adguard {
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                data = try await fetch(URL(string: "https://\(nonce)-dnscheck.adguard-dns.com/dnscheck/test")!)
            } else { data = try await fetch(provider.website) }
            let parsed = parse(data, provider: provider)
            return .init(provider: provider, verdict: parsed.0, date: Date(), method: method, detail: parsed.1)
        } catch {
            let error = error as NSError
            let code = error.domain == NSURLErrorDomain ? "URLSession \(error.code)" : error.domain == "VayuSetu.Provider.HTTP" ? "HTTP \(error.code)" : "Response rejected"
            return .init(provider: provider, verdict: .inconclusive, date: Date(), method: method, detail: "Verification request failed: " + code + ". No VPN bypass or resolver substitution was attempted.")
        }
    }
}
@MainActor final class DNSProviderVerification: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var observations: [ProviderObservation] = []
    @Published private(set) var message = ""
    private var revision = UUID()
    private var task: Task<Void, Never>?
    func invalidate() { revision = UUID(); task?.cancel(); observations = []; message = "Network or resolver changed; rerun the checks." }
    func run(endpoint: String) {
        guard !running else { return }; running = true; observations = []; message = "Checking provider identity on the current route…"
        let token = revision
        let selected = DNSProviderSite.selected(endpoint: endpoint)
        let order = selected.map { chosen in [chosen] + DNSProviderSite.providers.filter { $0 != chosen } } ?? DNSProviderSite.providers
        task = Task {
            defer { running = false; task = nil }
            for provider in order {
                guard !Task.isCancelled, revision == token else { return }
                let observation = await ProviderVerificationProbe.run(provider)
                guard !Task.isCancelled, revision == token else { return }
                observations.append(observation)
            }
            message = "Completed for this app's sampled DNS path. Use independent website tests to investigate disagreements."
        }
    }
    var sanitizedReport: String {
        "VayuSetu DNS provider checks\n" + observations.map { "\($0.provider.rawValue): \($0.verdict.rawValue) · \($0.date.formatted(.iso8601))\nMethod: \($0.method)\n\($0.detail)" }.joined(separator: "\n\n") + "\nThese samples do not prove device-wide DNS isolation, routing order or filtering effectiveness. Credentials, IPs, account IDs and raw responses are omitted."
    }
}
