import Darwin
import Foundation

struct GeoCountry: Codable, Identifiable, Hashable, Sendable {
    var code: String
    var name: String
    var latitude: Double
    var longitude: Double
    var id: String { code }
}

/// Read-only, memory-mapped range index. No destination is sent to a lookup service.
final class GeoDatabase: @unchecked Sendable {
    static let shared = GeoDatabase(directory: Bundle.main.resourceURL?.appendingPathComponent("Geo"))
    private let v4: Data
    private let v6: Data
    private let countries: [String: GeoCountry]
    var available: Bool { !v4.isEmpty && !v6.isEmpty }
    init(directory: URL?) {
        func read(_ name: String) -> Data { guard let directory else { return Data() }; return (try? Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)) ?? Data() }
        v4 = read("IPv4.bin"); v6 = read("IPv6.bin")
        countries = (try? JSONDecoder().decode([String: GeoCountry].self, from: read("Countries.json"))) ?? [:]
    }
    func country(code: String) -> GeoCountry? { countries[code.uppercased()] }
    func country(for address: String) -> GeoCountry? {
        let host = NetRuleEngine.normalise(address)
        var bytes = [UInt8](repeating: 0, count: 16)
        let family: Int
        if host.withCString({ inet_pton(AF_INET, $0, &bytes[12]) }) == 1 {
            family = 4
            let a = bytes[12], b = bytes[13]
            guard a != 0, a != 10, a != 127, a < 224, !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)), !(a == 192 && b == 168), !(a == 100 && (64...127).contains(b)) else { return nil }
        } else if host.withCString({ inet_pton(AF_INET6, $0, &bytes) }) == 1 {
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
                return country(for: bytes[12...15].map(String.init).joined(separator: "."))
            }
            family = 6
            guard bytes[0] & 0xe0 == 0x20 else { return nil } // Global unicast only.
        } else { return nil }
        let data = family == 4 ? v4 : v6
        guard data.count % 34 == 0 else { return nil }
        let key = Data(bytes)
        var low = 0, high = data.count / 34
        while low < high {
            let mid = (low + high) / 2
            if key.lexicographicallyPrecedes(data[(mid * 34)..<(mid * 34 + 16)]) { high = mid } else { low = mid + 1 }
        }
        guard low > 0 else { return nil }
        let offset = (low - 1) * 34
        guard !data[(offset + 16)..<(offset + 32)].lexicographicallyPrecedes(key),
              let code = String(data: data[(offset + 32)..<(offset + 34)], encoding: .ascii) else { return nil }
        return countries[code]
    }
}
