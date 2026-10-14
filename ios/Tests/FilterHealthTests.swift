import Foundation

@main struct FilterHealthTests {
    static var count = 0
    static func check(_ condition: Bool, _ line: Int = #line) { if !condition { fatalError("FilterHealthTests failed at line \(line)") }; count += 1 }
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func list(_ name: String, enabled: Bool = true, domain: Int = 1000, page: Int = 0, daysOld: Int? = 1) -> FilterHealthInput.List {
        FilterHealthInput.List(name: name, enabled: enabled, domainRules: domain, pageRules: page, unsupportedLines: 0, updated: daysOld.map { now.addingTimeInterval(-Double($0) * 86400) })
    }
    static func input(_ lists: [FilterHealthInput.List], safari: Bool = true, needed: Int = 2, on: Int = 2, loaded: Int = 2, applied: Int = 100, candidates: Int = 100, unique: Int = 1000, failure: String = "") -> FilterHealthInput {
        FilterHealthInput(lists: lists, safariOn: safari, extensionsNeeded: needed, extensionsEnabled: on, extensionsLoaded: loaded, safariApplied: applied, safariCandidates: candidates, uniqueRules: unique, ruleLimit: 650_000, lastFailure: failure, now: now)
    }
    static func main() {
        // A clean setup is healthy
        let ok = FilterHealthModel.issues(input([list("A"), list("B")]))
        check(ok.isEmpty && FilterHealthModel.level(ok) == .healthy)
        // Never downloaded is a problem; disabled lists are not judged
        let never = FilterHealthModel.issues(input([list("A", daysOld: nil), list("Off", enabled: false, domain: 0, daysOld: nil)]))
        check(never.count == 1 && never[0].severity == .problem && FilterHealthModel.level(never) == .problem)
        // No usable rules, and stale
        let empty = FilterHealthModel.issues(input([list("A", domain: 0, page: 0), list("B", daysOld: 30)]))
        check(empty.count == 2 && FilterHealthModel.level(empty) == .attention && empty.contains { $0.title.contains("30 days") })
        // A list of only page rules is usable
        check(FilterHealthModel.issues(input([list("P", domain: 0, page: 500)])).isEmpty)
        // Extensions off / not loaded
        let off = FilterHealthModel.issues(input([list("A")], on: 1, loaded: 1))
        check(off.count == 1 && off[0].title.hasPrefix("1 of 2"))
        let unloaded = FilterHealthModel.issues(input([list("A")], on: 2, loaded: 0))
        check(unloaded.count == 1 && unloaded[0].title.contains("not confirmed"))
        check(FilterHealthModel.issues(input([list("A")], safari: false, on: 0, loaded: 0)).isEmpty)       // Safari off: extensions are not a problem
        // Budget is information, not a warning
        let budget = FilterHealthModel.issues(input([list("A")], applied: 80, candidates: 100))
        check(budget.count == 1 && budget[0].severity == .info && FilterHealthModel.level(budget) == .healthy)
        // Near the limit, a failure, and no lists at all
        check(FilterHealthModel.issues(input([list("A")], unique: 600_000)).contains { $0.title == "Close to the rule limit" })
        check(FilterHealthModel.issues(input([list("A")], failure: "HTTP 500")).contains { $0.detail == "HTTP 500" })
        check(FilterHealthModel.issues(input([])).contains { $0.title == "No filter lists are on" })
        // Worst first
        let mixed = FilterHealthModel.issues(input([list("A", daysOld: nil), list("B", daysOld: 40)], applied: 1, candidates: 9))
        check(mixed.map(\.severity) == mixed.map(\.severity).sorted(by: >))
        print("Filter health checks passed: \(count)")
    }
}
