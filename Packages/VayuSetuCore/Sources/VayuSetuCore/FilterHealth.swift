import Foundation

/// What the Filter Health screen needs to judge the filtering pipeline, as plain values so the judgement can be tested.
public struct FilterHealthInput: Sendable {
    public struct List: Sendable {
        public let name: String
        public let enabled: Bool
        public let domainRules: Int
        public let pageRules: Int
        public let unsupportedLines: Int
        public let updated: Date?
        public init(name: String, enabled: Bool, domainRules: Int, pageRules: Int, unsupportedLines: Int, updated: Date?) {
            self.name = name; self.enabled = enabled; self.domainRules = domainRules; self.pageRules = pageRules; self.unsupportedLines = unsupportedLines; self.updated = updated
        }
    }
    public var lists: [List]
    public var safariOn: Bool
    public var extensionsNeeded: Int
    public var extensionsEnabled: Int
    public var extensionsLoaded: Int
    public var safariApplied: Int
    public var safariCandidates: Int
    public var uniqueRules: Int
    public var ruleLimit: Int
    public var lastFailure: String
    public var now: Date
    public init(lists: [List], safariOn: Bool, extensionsNeeded: Int, extensionsEnabled: Int, extensionsLoaded: Int, safariApplied: Int, safariCandidates: Int, uniqueRules: Int, ruleLimit: Int, lastFailure: String, now: Date) {
        self.lists = lists; self.safariOn = safariOn; self.extensionsNeeded = extensionsNeeded; self.extensionsEnabled = extensionsEnabled; self.extensionsLoaded = extensionsLoaded
        self.safariApplied = safariApplied; self.safariCandidates = safariCandidates; self.uniqueRules = uniqueRules; self.ruleLimit = ruleLimit; self.lastFailure = lastFailure; self.now = now
    }
}

public struct HealthIssue: Equatable, Identifiable, Sendable {
    public enum Severity: Int, Comparable, Sendable { case info, warning, problem; public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue } }
    public let severity: Severity
    public let title: String
    public let detail: String
    public var id: String { title }
}

public enum FilterHealthModel {
    public static let staleDays = 14
    /// Every finding is a fact about the current configuration with a reason, never a guess about whether ads are really blocked.
    public static func issues(_ input: FilterHealthInput) -> [HealthIssue] {
        var out: [HealthIssue] = []
        let enabled = input.lists.filter(\.enabled)
        if enabled.isEmpty && input.safariOn { out.append(.init(severity: .warning, title: "No filter lists are on", detail: "Safari protection is on but has no lists to use. Pick a filtering mode on the Adblock screen.")) }
        for list in enabled {
            guard let updated = list.updated else { out.append(.init(severity: .problem, title: "\(list.name) was never downloaded", detail: "It is switched on but has no rules yet. Update the lists.")); continue }
            if list.domainRules == 0 && list.pageRules == 0 { out.append(.init(severity: .warning, title: "\(list.name) has no usable rules", detail: "It downloaded but nothing in it is something VayuSetu can apply. The list may have changed format.")) }
            let days = Calendar.current.dateComponents([.day], from: updated, to: input.now).day ?? 0
            if days > staleDays { out.append(.init(severity: .warning, title: "\(list.name) is \(days) days old", detail: "Lists change often. Update to get new rules.")) }
        }
        if input.safariOn && input.extensionsNeeded > 0 {
            if input.extensionsEnabled < input.extensionsNeeded { out.append(.init(severity: .warning, title: "\(input.extensionsNeeded - input.extensionsEnabled) of \(input.extensionsNeeded) Safari extensions are off", detail: "Turn them on in Settings → Apps → Safari → Extensions. Rules in an extension that is off do nothing.")) }
            else if input.extensionsLoaded < input.extensionsNeeded { out.append(.init(severity: .warning, title: "Safari has not confirmed the rules", detail: "The extensions are on but Safari has not acknowledged loading them. Rebuild the Safari rules.")) }
        }
        if input.safariOn && input.safariCandidates > input.safariApplied {
            out.append(.init(severity: .info, title: "Safari uses \(input.safariApplied.formatted()) of \(input.safariCandidates.formatted()) rules", detail: "Safari takes a limited number per extension, so the least common rules are left out. DNS filtering uses all of them."))
        }
        if input.ruleLimit > 0 && Double(input.uniqueRules) > Double(input.ruleLimit) * 0.85 {
            out.append(.init(severity: .warning, title: "Close to the rule limit", detail: "\(input.uniqueRules.formatted()) of \(input.ruleLimit.formatted()) distinct rules. A bigger mode may not fit."))
        }
        if !input.lastFailure.isEmpty { out.append(.init(severity: .warning, title: "The last update had a problem", detail: input.lastFailure)) }
        return out.sorted { $0.severity > $1.severity }
    }
    public enum Level: String, Sendable { case healthy = "Healthy", attention = "Needs attention", problem = "Problem" }
    public static func level(_ issues: [HealthIssue]) -> Level {
        let worst = issues.map(\.severity).max()
        switch worst { case .problem: return .problem; case .warning: return .attention; default: return .healthy }
    }
}
