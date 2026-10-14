import Foundation

@main struct IPProbeTests {
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool) { precondition(condition); count += 1 }
        let v4 = PublicIPProbe.endpoints(.ipv4), v6 = PublicIPProbe.endpoints(.ipv6)
        check(v4.count == 2 && v6.count == 2)
        check(v4[0].url.host == "api.ipify.org" && v6[0].url.host == "api6.ipify.org")
        check(v4[1].url.host == "4.ident.me" && v6[1].url.host == "6.ident.me")
        check(v4[0].url.absoluteString == "https://api.ipify.org/?format=json")
        check(v6[0].url.absoluteString == "https://api6.ipify.org/?format=json")
        check(v4[0].url.path == "/" && v6[0].url.path == "/")
        check(URLComponents(url: v4[0].url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "format", value: "json")])
        for value in ["http://api.ipify.org/?format=json", "https://api.ipify.org?format=json", "https://secret@api.ipify.org/?format=json", "https://api.ipify.org/private-token", "https://api.ipify.org/?format=json&token=secret", "https://api.ipify.org:8443/?format=json", "https://other.example/"] {
            do { try PublicIPProbe.validateURL(URL(string: value)!); preconditionFailure("Accepted unsafe endpoint") }
            catch let error as IPFailure { check(error.kind == .invalidURL && !error.detail.contains("secret")) }
        }
        check(v4.allSatisfy { $0.url.scheme == "https" && $0.url.user == nil })
        check(try PublicIPProbe.parse(Data("{\"ip\":\"8.8.8.8\"}".utf8), status: 200, endpoint: v4[0], family: .ipv4) == "8.8.8.8")
        check(try PublicIPProbe.parse(Data("2001:4860:4860::8888\n".utf8), status: 200, endpoint: v6[1], family: .ipv6) == "2001:4860:4860::8888")
        for (body, status, endpoint, family, expected) in [("{\"ip\":\"::1\"}", 200, v4[0], IPFamily.ipv4, IPFailureKind.family), ("<html>error</html>",200,v4[0],.ipv4,.malformed), ("8.8.8.8",503,v4[1],.ipv4,.http), ("8.8.8.8 injected",200,v4[1],.ipv4,.malformed), ("",200,v4[1],.ipv4,.malformed)] {
            do { _ = try PublicIPProbe.parse(Data(body.utf8), status: status, endpoint: endpoint, family: family); preconditionFailure("Accepted invalid reply") } catch let error as IPFailure { check(error.kind == expected) }
        }
        do { _ = try PublicIPProbe.parse(Data(repeating: 65, count: 4097), status: 200, endpoint: v4[1], family: .ipv4); preconditionFailure("Accepted oversized reply") } catch let error as IPFailure { check(error.kind == .malformed) }
        for (code, expected) in [(URLError.badURL,.invalidURL),(URLError.unsupportedURL,.invalidURL),(URLError.cannotFindHost,.dns),(URLError.dnsLookupFailed,.dns),(URLError.secureConnectionFailed,.tls),(URLError.serverCertificateUntrusted,.tls),(URLError.notConnectedToInternet,.connectivity),(URLError.timedOut,.timeout),(URLError.cancelled,.cancelled)] as [(URLError.Code,IPFailureKind)] {
            let error = NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey:"SECRET", NSURLErrorFailingURLErrorKey:URL(string:"https://secret.example/token")!])
            let failure = IPFailure.classify(error); check(failure.kind == expected && !failure.detail.contains("SECRET") && !failure.detail.contains("token"))
        }
        let nested = NSError(domain: NSURLErrorDomain, code: URLError.unknown.rawValue, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENETUNREACH))])
        check(IPFailure.classify(nested).kind == .connectivity)
        check(IPFailure.classify(nested).detail.contains("NSPOSIXErrorDomain"))
        let success = await PublicIPProbe.run(.ipv4) { endpoint in if endpoint.provider == "ipify" { throw URLError(.cannotFindHost) }; return (Data("8.8.8.8\n".utf8),200) }
        check(success.address == "8.8.8.8" && success.attempts.count == 2 && success.attempts[0].failure?.kind == .dns)
        let primary = await PublicIPProbe.run(.ipv6) { _ in (Data("{\"ip\":\"2001:4860:4860::8888\"}".utf8),200) }
        check(primary.address != nil && primary.attempts.count == 1)
        let fail = await PublicIPProbe.run(.ipv4) { _ in throw URLError(.timedOut) }
        check(fail.address == nil && fail.attempts.count == 2 && fail.failure?.kind == .timeout)
        let unsupported = await PublicIPProbe.run(.ipv6, ipv6Supported: false) { _ in throw URLError(.notConnectedToInternet) }
        check(unsupported.failure?.kind == .unsupported)
        let unknown = await PublicIPProbe.run(.ipv6, ipv6Supported: true) { _ in throw URLError(.notConnectedToInternet) }
        check(unknown.failure?.kind == .connectivity)
        let cancelled = await PublicIPProbe.run(.ipv4) { _ in throw CancellationError() }
        check(cancelled.attempts.count == 1 && cancelled.failure?.kind == .cancelled)
        let badPrimary = await PublicIPProbe.run(.ipv4) { endpoint in if endpoint.provider == "ipify" { throw URLError(.badURL) }; return (Data("8.8.8.8".utf8),200) }
        check(badPrimary.address == "8.8.8.8" && badPrimary.attempts[0].failure?.kind == .invalidURL)
        check(badPrimary.attempts[0].endpointURL == "https://api.ipify.org/?format=json")
        for address in ["0.0.0.0", "::", "0:0:0:0:0:0:0:0", "127.0.0.1", "::1"] { check(SystemDestinationObservation.unusable(address)) }
        check(!SystemDestinationObservation.unusable("8.8.8.8"))
        check(!SystemDestinationObservation.unusable("2001:4860:4860::8888"))
        let badURL = IPFailure.classify(URLError(.badURL))
        check(SystemDestinationObservation.explain(badURL, observation: .init(count: 2, unusableCount: 2, errorCode: nil, timedOut: false)).kind == .dnsDestination)
        check(SystemDestinationObservation.explain(badURL, observation: .init(count: 2, unusableCount: 1, errorCode: nil, timedOut: false)).kind == .invalidURL)
        check(SystemDestinationObservation.explain(badURL, observation: .init(count: 0, unusableCount: 0, errorCode: nil, timedOut: true)).kind == .invalidURL)
        do { _ = try PublicIPProbe.parse(Data("0.0.0.0".utf8), status: 200, endpoint: v4[1], family: .ipv4); preconditionFailure("Accepted unspecified exit") } catch let error as IPFailure { check(error.kind == .malformed) }
        do { _ = try PublicIPProbe.parse(Data("::1".utf8), status: 200, endpoint: v6[1], family: .ipv6); preconditionFailure("Accepted loopback exit") } catch let error as IPFailure { check(error.kind == .malformed) }
        let dnsFallback = await PublicIPProbe.run(.ipv4) { endpoint in if endpoint.provider == "ipify" { throw IPFailure(kind: .dnsDestination, detail: "System DNS returned unspecified destination") }; return (Data("8.8.8.8".utf8), 200) }
        check(dnsFallback.address == "8.8.8.8" && dnsFallback.attempts[0].failure?.kind == .dnsDestination)
        print("Passed \(count) independent IP diagnostic checks.")
    }
}
