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
        // Keep this contract tied to the curated catalogue so adding a vetted
        // default list cannot silently make the storage audit fail.
        precondition(saved.subscriptions.count == FilterCatalog.defaults.count && saved.subscriptions.allSatisfy { !$0.enabled && $0.rules.isEmpty })
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
        // Retention: shortening it removes what is outside it at once, without another event being recorded; and an expired event is never returned.
        let key = PrivacyDatabase.retentionKey, savedRetention = UserDefaults.standard.object(forKey: key)
        defer { if let savedRetention { UserDefaults.standard.set(savedRetention, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        try restored.clearEvents()
        let now = Date()
        UserDefaults.standard.set(30, forKey: key)       // so the old events survive being recorded; each step below then shortens it
        try restored.event("ten days ago", at: now.addingTimeInterval(-10 * 86_400))
        try restored.event("two days ago", at: now.addingTimeInterval(-2 * 86_400))
        try restored.event("an hour ago", at: now.addingTimeInterval(-3_600))
        UserDefaults.standard.set(30, forKey: key)
        let removed30 = try restored.purgeEvents(now: now)
        precondition(removed30 == 0 && restored.eventCount() == 3, "30 days keeps all three")
        UserDefaults.standard.set(7, forKey: key)
        precondition(restored.recentEvents(now: now).count == 2, "an event outside 7 days is not shown even before it is purged")
        precondition(restored.eventCount() == 3)
        let removed7 = try restored.purgeEvents(now: now)
        precondition(removed7 == 1 && restored.eventCount() == 2 && !restored.events().contains { $0.contains("ten days ago") }, "setting 7 days removes the ten-day-old event now")
        UserDefaults.standard.set(1, forKey: key)
        let removed1 = try restored.purgeEvents(now: now)
        precondition(removed1 == 1 && restored.eventCount() == 1 && restored.events().first!.contains("an hour ago"), "setting 1 day removes the two-day-old event now")
        UserDefaults.standard.set(365, forKey: key)
        precondition(PrivacyDatabase.retentionDays() == 7, "an unsupported value reads as 7 days")
        let removedNone = try restored.purgeEvents(now: now)
        precondition(removedNone == 0 && restored.eventCount() == 1)
        UserDefaults.standard.removeObject(forKey: key)
        try restored.event("old, recorded long ago", at: now.addingTimeInterval(-40 * 86_400))
        precondition(restored.eventCount() == 1, "recording an event also applies the period: the 40-day-old one never stays")
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
