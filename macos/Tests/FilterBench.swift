import Foundation
import NetworkExtension

/// Not a pass/fail test: it measures how long the filter takes to decide a connection when it holds a lot (thousands of rules, hundreds of
/// thousands of list entries), because every connection waits on that decision. Run with tools/bench-filter.sh.
final class BenchFlow: NEFilterFlow {
    private let own = UUID()
    override var identifier: UUID { own }
}

@main enum FilterBench {
    static func rss() -> Double {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return Double(info.resident_size) / 1_048_576
    }
    static func measure(_ label: String, _ n: Int, _ body: (Int) -> Void) {
        var samples: [Double] = []; samples.reserveCapacity(n)
        let start = DispatchTime.now()
        for i in 0..<n { let t = DispatchTime.now(); body(i); samples.append(Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1000) }
        let total = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        samples.sort()
        func pct(_ p: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count) * p))] }
        print(String(format: "%-46@ %7d decisions  %8.0f/s   p50 %7.1f µs   p99 %8.1f µs   max %9.1f µs", label as NSString, n, Double(n) / total, pct(0.5), pct(0.99), samples.last ?? 0))
    }
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FilterStore(storageURL: dir.appendingPathComponent("filter.json"), clientAvailable: { true })
        var settings = FilterSettings(); settings.askMode = false; store.setSettings(settings)
        let apps = (0..<60).map { "com.example.app\($0)" }
        func info(_ i: Int) -> FlowInfo { FlowInfo(app: apps[i % apps.count], appName: "App", host: "host\(i % 9973).cdn\(i % 41).example.net", port: "443", proto: "TCP", outbound: true, team: "T", valid: true) }
        print("memory at start: \(String(format: "%.0f", rss())) MB")

        measure("no rules, no lists", 50_000) { _ = store.decide(BenchFlow(), info($0)) }

        var rules: [NetRule] = []
        for i in 0..<5000 {
            switch i % 5 {
            case 0: rules.append(NetRule(app: "*", host: "blocked\(i).tracker.example", port: "*", action: .block))
            case 1: rules.append(NetRule(app: apps[i % apps.count], host: "*", port: "25", action: .block))
            case 2: rules.append(NetRule(app: "*", host: "*.ads\(i).example", port: "*", action: .block))
            case 3: rules.append(NetRule(app: "*", host: "10.\(i / 256 % 256).0.0/16", port: "*", action: .block))
            default: rules.append(NetRule(app: apps[i % apps.count], host: "allow\(i).example.org", port: "443", action: .allow))
            }
        }
        store.setRules(rules)
        measure("5,000 rules (worst case: none match)", 5_000) { _ = store.decide(BenchFlow(), info($0)) }

        var entries: [String] = []; entries.reserveCapacity(400_000)
        for i in 0..<400_000 { entries.append("ad\(i).tracker\(i % 3000).example.com") }
        let t = DispatchTime.now()
        store.setLists([NetList(name: "Big block list", kind: .block, entries: entries)])
        print(String(format: "loading a 400,000-entry list took %.2f s; memory now %.0f MB", Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e9, rss()))
        measure("5,000 rules + 400,000-entry list", 5_000) { _ = store.decide(BenchFlow(), info($0)) }

        // The poll the app makes every second, and rule edits, while connections are being decided.
        let group = DispatchGroup(); var polls = 0
        group.enter()
        DispatchQueue.global().async { for _ in 0..<200 { _ = store.recent(after: 0); _ = store.pendingQuestions(); polls += 1; Thread.sleep(forTimeInterval: 0.005) }; group.leave() }
        measure("same, while the app polls 200x/s", 5_000) { _ = store.decide(BenchFlow(), info($0)) }
        group.wait()

        print(String(format: "memory at end: %.0f MB (history is capped at 5,000 connections)", rss()))
    }
}
