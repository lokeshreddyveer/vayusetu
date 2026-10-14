import Foundation
import VayuSetuCore

@main struct PrivacyStorageTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("privacy.sqlite")
        var db: PrivacyDatabase? = try PrivacyDatabase(url: url)
        let empty = try db!.read(); precondition(empty == nil)
        precondition(db!.dnsIntent() == nil)
        try db!.setDNSIntent(true); precondition(db!.dnsIntent() == true)
        let saved = FilterConfiguration()
        precondition(saved.subscriptions.count == 3 && saved.subscriptions.allSatisfy { !$0.enabled && $0.rules.isEmpty })
        let data = try JSONEncoder().encode(saved)
        try db!.save(data)
        let roundTrip = try db!.read(); precondition(roundTrip == data)
        try db!.event("Apostrophe ' and quote \" are stored as text")
        precondition(db!.events().first!.contains("Apostrophe '"))
        for i in 0..<205 { try db!.event("Event \(i)") }
        precondition(db!.events().count == 200)
        db = nil
        let restored = try PrivacyDatabase(url: url)
        let restoredData = try restored.read(); precondition(restoredData == data)
        precondition(restored.events().count == 200)
        precondition(restored.dnsIntent() == true)
        try restored.setDNSIntent(false); precondition(restored.dnsIntent() == false)
        try restored.clearEvents()
        precondition(restored.events().isEmpty)
        let preservedData = try restored.read(); precondition(preservedData == data)
        let good = Data(#"{"status":"ok","data":{"prefix":"203.0.113.0/24","asns":["64496",64497]}}"#.utf8)
        let goodResult = try ASNResponse.parse(good); precondition(goodResult.contains("AS64496, AS64497"))
        let bad = [#"{"status":"error","data":{"prefix":"203.0.113.0/24","asns":[]}}"#,
                   #"{"status":"ok","data":{"prefix":"not an IP","asns":[]}}"#,
                   #"{"status":"ok","data":{"prefix":"203.0.113.0/90","asns":[]}}"#,
                   #"{"status":"ok","data":{"prefix":"203.0.113.0/24","asns":[0]}}"#,
                   #"{"status":"ok","data":{"prefix":"203.0.113.0/24","asns":["not an ASN"]}}"#]
        for text in bad { do { _ = try ASNResponse.parse(Data(text.utf8)); fatalError("Malformed ASN accepted") } catch {} }
        let v6 = Data(#"{"status":"ok","data":{"prefix":"2001:db8::/32","asns":[]}}"#.utf8)
        let v6Result = try ASNResponse.parse(v6); precondition(v6Result.contains("Not reported"))
        print("Passed 20 privacy-storage, list-default and ASN validation checks.")
    }
}
