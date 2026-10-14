import Foundation
import Darwin

enum IPFamily: Int, Codable, CaseIterable { case ipv4 = 4, ipv6 = 6 }
enum IPFailureKind: String, Codable {
    case invalidURL = "URL request rejected"
    case dnsDestination = "DNS destination unusable"
    case unsupported = "IPv6 unavailable on reported network path"
    case connectivity = "Connectivity unavailable", dns = "DNS lookup failed", tls = "TLS validation or handshake failed"
    case http = "HTTP failure", malformed = "Malformed response", family = "Unexpected address family"
    case timeout = "Request timed out", cancelled = "Cancelled", other = "Network request failed"
}
struct IPFailure: Error, LocalizedError, Codable {
    let kind: IPFailureKind
    let detail: String
    var errorDescription: String? { "\(kind.rawValue). \(detail)" }
    static func classify(_ error: Error) -> IPFailure {
        if let failure = error as? IPFailure { return failure }
        if error is CancellationError { return IPFailure(kind: .cancelled, detail: "Diagnostic cancelled.") }
        let ns = error as NSError
        var code = ns.domain == NSURLErrorDomain ? ns.code : 0
        var current = ns; var chain: [String] = []
        for _ in 0..<4 {
            let allowed = [NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "kCFErrorDomainCFNetwork"]
            chain.append("\(allowed.contains(current.domain) ? current.domain : "OtherErrorDomain"):\(current.code)")
            if current.domain == NSURLErrorDomain { code = current.code }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }; current = underlying
        }
        var kind: IPFailureKind
        switch code {
        case URLError.badURL.rawValue, URLError.unsupportedURL.rawValue: kind = .invalidURL
        case URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue: kind = .dns
        case URLError.secureConnectionFailed.rawValue, URLError.serverCertificateHasBadDate.rawValue, URLError.serverCertificateUntrusted.rawValue, URLError.serverCertificateHasUnknownRoot.rawValue, URLError.serverCertificateNotYetValid.rawValue, URLError.clientCertificateRejected.rawValue, URLError.clientCertificateRequired.rawValue, URLError.appTransportSecurityRequiresSecureConnection.rawValue: kind = .tls
        case URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue, URLError.cannotConnectToHost.rawValue, URLError.dataNotAllowed.rawValue, URLError.internationalRoamingOff.rawValue: kind = .connectivity
        case URLError.timedOut.rawValue: kind = .timeout
        case URLError.cancelled.rawValue: kind = .cancelled
        default: kind = .other
        }
        if kind == .other || kind == .connectivity {
            if current.domain == NSPOSIXErrorDomain {
                if [Int(ENETDOWN), Int(ENETUNREACH), Int(EHOSTUNREACH), Int(ECONNREFUSED), Int(ECONNRESET)].contains(current.code) { kind = .connectivity }
                if current.code == Int(ETIMEDOUT) { kind = .timeout }
            }
        }
        // Never include NSError.userInfo, localizedDescription, URLs, or request headers.
        return IPFailure(kind: kind, detail: chain.joined(separator: " → "))
    }
}
struct IPEndpoint: Equatable {
    enum Format { case json, text }
    let provider: String
    let url: URL
    let format: Format
}
struct IPAttempt: Codable {
    let provider: String
    let date: Date
    let milliseconds: Int
    let failure: IPFailure?
    var endpointURL: String? = nil
}
struct IPProbeResult {
    let family: IPFamily
    let address: String?
    let attempts: [IPAttempt]
    let failure: IPFailure?
    var detail: String { attempts.map { "\($0.date.formatted(.iso8601)) · \($0.provider) · \($0.endpointURL ?? "Endpoint unavailable") · \($0.milliseconds) ms · \($0.failure?.errorDescription ?? "Address response received")" }.joined(separator: "\n") }
}
enum PublicIPProbe {
    static let requestTimeout: TimeInterval = 8
    static let resourceTimeout: TimeInterval = 10
    static let maximumBytes = 4096
    static func endpointURL(host: String, json: Bool) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.path = "/"
        if json { components.queryItems = [URLQueryItem(name: "format", value: "json")] }
        guard let url = components.url else { throw IPFailure(kind: .invalidURL, detail: "Endpoint construction failed.") }
        try validateURL(url)
        return url
    }
    static func validateURL(_ url: URL) throws {
        // Diagnostics use only these public, credential-free services. Never log a
        // personalized DNS endpoint or accept a redirect to an arbitrary service.
        let hosts = ["api.ipify.org", "api6.ipify.org", "api64.ipify.org", "4.ident.me", "6.ident.me"]
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", hosts.contains(components.host ?? ""),
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, components.path == "/",
              components.percentEncodedQuery == nil || components.percentEncodedQuery == "format=json" else {
            throw IPFailure(kind: .invalidURL, detail: "Expected a supported HTTPS endpoint with an explicit root path and no credentials.")
        }
    }
    static func endpoints(_ family: IPFamily) -> [IPEndpoint] {
        // Fixed public constants are validated at construction and before transport.
        [IPEndpoint(provider: "ipify", url: try! endpointURL(host: family == .ipv4 ? "api.ipify.org" : "api6.ipify.org", json: true), format: .json),
         IPEndpoint(provider: "ident.me", url: try! endpointURL(host: family == .ipv4 ? "4.ident.me" : "6.ident.me", json: false), format: .text)]
    }
    static func canonical(_ value: String, family: IPFamily) -> String? {
        var bytes = [UInt8](repeating: 0, count: 16); var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let af = family == .ipv4 ? AF_INET : AF_INET6
        guard value.withCString({ inet_pton(af, $0, &bytes) }) == 1, inet_ntop(af, &bytes, &output, socklen_t(output.count)) != nil else { return nil }
        return String(cString: output)
    }
    static func parse(_ data: Data, status: Int, endpoint: IPEndpoint, family: IPFamily) throws -> String {
        guard status == 200 else { throw IPFailure(kind: .http, detail: "HTTP status \(status).") }
        guard !data.isEmpty, data.count <= maximumBytes else { throw IPFailure(kind: .malformed, detail: "Empty or oversized reply.") }
        let candidate: String
        switch endpoint.format {
        case .json:
            struct Reply: Decodable { let ip: String }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw IPFailure(kind: .malformed, detail: "Expected JSON with an IP string.") }; candidate = reply.ip
        case .text:
            guard let text = String(data: data, encoding: .utf8) else { throw IPFailure(kind: .malformed, detail: "Expected a UTF-8 address.") }; candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let address = canonical(candidate, family: family) {
            guard !SystemDestinationObservation.unusable(address) else { throw IPFailure(kind: .malformed, detail: "Service returned an unspecified or loopback address, not a public exit address.") }
            return address
        }
        if canonical(candidate, family: family == .ipv4 ? .ipv6 : .ipv4) != nil { throw IPFailure(kind: .family, detail: "IPv\(family.rawValue) check returned the other family.") }
        throw IPFailure(kind: .malformed, detail: "Reply is not a valid IP address.")
    }
    static func fetch(_ endpoint: IPEndpoint) async throws -> (Data, Int) { try await transport(endpoint, requestTimeout: requestTimeout, resourceTimeout: resourceTimeout) }
    /// Diagnostic control reproduces the original request without adding a bypass.
    static func legacyControl(family: IPFamily? = nil) async -> IPAttempt {
        let host = family == .ipv4 ? "api.ipify.org" : family == .ipv6 ? "api6.ipify.org" : "api64.ipify.org"
        let endpoint = IPEndpoint(provider: "ipify original empty-path control", url: URL(string: "https://" + host + "?format=json")!, format: .json)
        let date = Date(); let start = ContinuousClock.now
        do {
            let (data, status) = try await transport(endpoint, requestTimeout: 8, resourceTimeout: 10, allowLegacyPath: true)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
            guard status == 200, let ip = json?["ip"], let family = ProfileParser.ipFamily(ip), let value = IPFamily(rawValue: family) else { throw IPFailure(kind: .malformed, detail: "Invalid legacy JSON IP response.") }
            _ = try parse(data, status: status, endpoint: endpoint, family: value)
            return IPAttempt(provider: endpoint.provider + " (IPv\(family) response)", date: date, milliseconds: milliseconds(start), failure: nil, endpointURL: endpoint.url.absoluteString)
        } catch { return IPAttempt(provider: endpoint.provider, date: date, milliseconds: milliseconds(start), failure: IPFailure.classify(error), endpointURL: endpoint.url.absoluteString) }
    }
    private static func transport(_ endpoint: IPEndpoint, requestTimeout: TimeInterval, resourceTimeout: TimeInterval, allowLegacyPath: Bool = false) async throws -> (Data, Int) {
        if allowLegacyPath {
            // An explicit development-only A/B control of the old fixed public URL.
            // Validate the normalized URL, but send the original path unchanged.
            guard var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false), components.path.isEmpty else { throw IPFailure(kind: .invalidURL, detail: "Invalid legacy control.") }
            components.path = "/"
            guard let url = components.url else { throw IPFailure(kind: .invalidURL, detail: "Invalid legacy control.") }
            try validateURL(url)
        } else { try validateURL(endpoint.url) }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = requestTimeout; config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        // Default OS routing applies. No interface binding, proxy override, excluded
        // route, custom DNS resolution, TLS trust override or VPN bypass is used.
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint.url); request.timeoutInterval = requestTimeout; request.cachePolicy = .reloadIgnoringLocalCacheData
        let bytes: URLSession.AsyncBytes; let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch {
            let failure = IPFailure.classify(error)
            if failure.kind == .invalidURL, let host = endpoint.url.host {
                // Observe the system resolver; do not substitute DNS, an IP literal or a route.
                let observation = await SystemDestinationObservation.resolve(host)
                throw SystemDestinationObservation.explain(failure, observation: observation)
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw IPFailure(kind: .http, detail: "Non-HTTP response.") }
        guard http.statusCode == 200 else { throw IPFailure(kind: .http, detail: "HTTP status \(http.statusCode).") }
        var data = Data()
        for try await byte in bytes { guard data.count < maximumBytes else { throw IPFailure(kind: .malformed, detail: "Reply exceeds 4096 bytes.") }; data.append(byte) }
        return (data, http.statusCode)
    }
    static func run(_ family: IPFamily, ipv6Supported: Bool? = nil, fetch: (IPEndpoint) async throws -> (Data, Int) = PublicIPProbe.fetch) async -> IPProbeResult {
        var attempts: [IPAttempt] = []
        for endpoint in endpoints(family) { // At most two attempts, one per independent operator.
            if Task.isCancelled { return IPProbeResult(family: family, address: nil, attempts: attempts, failure: IPFailure(kind: .cancelled, detail: "Diagnostic cancelled.")) }
            let date = Date(); let start = ContinuousClock.now
            do {
                try validateURL(endpoint.url)
                let (data, status) = try await fetch(endpoint)
                let address = try parse(data, status: status, endpoint: endpoint, family: family)
                attempts.append(IPAttempt(provider: endpoint.provider, date: date, milliseconds: milliseconds(start), failure: nil, endpointURL: endpoint.url.absoluteString))
                return IPProbeResult(family: family, address: address, attempts: attempts, failure: nil)
            } catch {
                let failure = IPFailure.classify(error)
                attempts.append(IPAttempt(provider: endpoint.provider, date: date, milliseconds: milliseconds(start), failure: failure, endpointURL: endpoint.url.absoluteString))
                if failure.kind == .cancelled { break }
            }
        }
        var failure = attempts.last?.failure ?? IPFailure(kind: .other, detail: "No address response.")
        if family == .ipv6, ipv6Supported == false, attempts.allSatisfy({ $0.failure?.kind == .connectivity || $0.failure?.kind == .dns }) { failure = IPFailure(kind: .unsupported, detail: "NWPath reports no IPv6 support; probes failed. This does not verify IPv6 blocking.") }
        return IPProbeResult(family: family, address: nil, attempts: attempts, failure: failure)
    }
    private static func milliseconds(_ start: ContinuousClock.Instant) -> Int { let value = start.duration(to: .now).components; return Int(value.seconds * 1000 + value.attoseconds / 1_000_000_000_000_000) }
}

/// A valid URL can still be rejected after DNS produces an unspecified destination.
/// Only public diagnostic service names are observed using the current system DNS.
struct SystemDestinationObservation: Sendable {
    let count: Int
    let unusableCount: Int
    let errorCode: Int?
    let timedOut: Bool
    var unusableOnly: Bool { count > 0 && count == unusableCount && errorCode == nil && !timedOut }
    var summary: String {
        if timedOut { return "System DNS observation timed out after 4 seconds." }
        if let errorCode { return "System DNS observation failed (getaddrinfo \(errorCode))." }
        return "System DNS returned \(count) destination(s), \(unusableCount) unspecified/loopback. No resolver or route was substituted."
    }
    static func unusable(_ address: String) -> Bool {
        if let v4 = PublicIPProbe.canonical(address, family: .ipv4) { return v4 == "0.0.0.0" || v4.hasPrefix("127.") }
        if let v6 = PublicIPProbe.canonical(address, family: .ipv6) { return v6 == "::" || v6 == "::1" || v6 == "::ffff:0.0.0.0" || v6.hasPrefix("::ffff:127.") }
        return false
    }
    static func explain(_ failure: IPFailure, observation: Self) -> IPFailure {
        IPFailure(kind: failure.kind == .invalidURL && observation.unusableOnly ? .dnsDestination : failure.kind,
                  detail: failure.detail + " URL passed local validation. " + observation.summary)
    }
    static func resolve(_ host: String) async -> Self {
        guard ["api.ipify.org", "api6.ipify.org", "api64.ipify.org", "4.ident.me", "6.ident.me"].contains(host) else { return Self(count: 0, unusableCount: 0, errorCode: Int(EAI_NONAME), timedOut: false) }
        return await resolveAllowedHost(host)
    }
    #if DEBUG
    static func resolveAuditHost(_ host: String) async -> Self {
        guard ["example.com", "pagead2.googlesyndication.com", "www.google-analytics.com", "malware.testcategory.com"].contains(host) else {
            return Self(count: 0, unusableCount: 0, errorCode: Int(EAI_NONAME), timedOut: false)
        }
        return await resolveAllowedHost(host)
    }
    #endif
    private static func resolveAllowedHost(_ host: String) async -> Self {
        return await withCheckedContinuation { continuation in
            let waiter = SystemDestinationWaiter(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) { waiter.finish(Self(count: 0, unusableCount: 0, errorCode: nil, timedOut: true)) }
            DispatchQueue.global(qos: .utility).async {
                guard SystemDestinationWaiter.workerSlots.wait(timeout: .now()) == .success else { waiter.finish(Self(count: 0, unusableCount: 0, errorCode: nil, timedOut: true)); return }
                defer { SystemDestinationWaiter.workerSlots.signal() }
                var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
                var head: UnsafeMutablePointer<addrinfo>?
                let code = getaddrinfo(host, "443", &hints, &head)
                guard code == 0 else { waiter.finish(Self(count: 0, unusableCount: 0, errorCode: Int(code), timedOut: false)); return }
                defer { if let head { freeaddrinfo(head) } }
                var current = head; var addresses = Set<String>()
                while let item = current {
                    var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 { addresses.insert(String(cString: name)) }
                    current = item.pointee.ai_next
                }
                waiter.finish(Self(count: addresses.count, unusableCount: addresses.filter(unusable).count, errorCode: nil, timedOut: false))
            }
        }
    }
}
private final class SystemDestinationWaiter: @unchecked Sendable {
    static let workerSlots = DispatchSemaphore(value: 4)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SystemDestinationObservation, Never>?
    init(_ continuation: CheckedContinuation<SystemDestinationObservation, Never>) { self.continuation = continuation }
    func finish(_ value: SystemDestinationObservation) {
        lock.lock(); let callback = continuation; continuation = nil; lock.unlock()
        callback?.resume(returning: value)
    }
}
