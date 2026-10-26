import Foundation

/// First-seen tracking: which apps connect, and to which sites, for the first time. It exists to answer "what is new on my Mac today" without a
/// stream of alerts. It stores an app and a site per entry and nothing about when within a day; people turn it on, and turning it off deletes it.
/// For the first `learningDays` days it only learns: everything is new on day one, and listing it would be noise.
public struct FirstSeenTracker: Codable, Equatable, Sendable {
    public static let learningDays = 3
    public static let maximumPairs = 5000
    public static let maximumApps = 500

    /// App → day first seen (days since 1970).
    public private(set) var apps: [String: Int] = [:]
    /// "app|site" → day first seen.
    public private(set) var pairs: [String: Int] = [:]
    /// The first day this tracker saw anything.
    public private(set) var startDay: Int?
    public private(set) var appNames: [String: String] = [:]
    public init() {}

    public enum Event: Equatable, Sendable {
        case newApp(app: String, name: String)
        case newSite(app: String, name: String, site: String)
    }

    public func isLearning(on day: Int) -> Bool { guard let startDay else { return true }; return day < startDay + Self.learningDays }

    /// The part of a host that identifies who runs it: the last two labels, or three under a two-letter country code with a short second label.
    /// Addresses are kept whole.
    public static func site(of host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !h.isEmpty, h.contains("."), !h.contains(":"), h.split(separator: ".").contains(where: { Int($0) == nil }) else { return h }
        let labels = h.split(separator: ".").map(String.init)
        if labels.count >= 3, let last = labels.last, last.count == 2, labels[labels.count - 2].count <= 3 { return labels.suffix(3).joined(separator: ".") }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Records one connection and says whether it was new (and reportable). Nothing is reported while learning.
    @discardableResult
    public mutating func record(app: String, name: String, host: String, day: Int) -> Event? {
        guard !app.isEmpty, !host.isEmpty else { return nil }
        if startDay == nil { startDay = day }
        let learning = isLearning(on: day)
        let site = Self.site(of: host)
        var event: Event?
        if apps[app] == nil {
            guard apps.count < Self.maximumApps else { return nil }
            apps[app] = day; appNames[app] = name.isEmpty ? app : name
            if !learning { event = .newApp(app: app, name: appNames[app] ?? app) }
        }
        let key = app + "|" + site
        if pairs[key] == nil {
            if pairs.count >= Self.maximumPairs, let oldest = pairs.min(by: { $0.value < $1.value })?.key { pairs.removeValue(forKey: oldest) }
            pairs[key] = day
            if !learning, event == nil { event = .newSite(app: app, name: appNames[app] ?? name, site: site) }
        }
        return event
    }

    public struct Summary: Equatable, Sendable {
        public var newApps: [String]
        public var newSites: [(app: String, site: String)]
        public var learning: Bool
        public static func == (l: Summary, r: Summary) -> Bool { l.newApps == r.newApps && l.learning == r.learning && l.newSites.count == r.newSites.count }
    }
    /// What is new on `day`, in plain lists.
    public func summary(day: Int) -> Summary {
        let newApps = apps.filter { $0.value == day }.map { appNames[$0.key] ?? $0.key }.sorted()
        let newSites = pairs.filter { $0.value == day && apps[$0.key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""] != day }
            .compactMap { entry -> (String, String)? in
                let parts = entry.key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (appNames[parts[0]] ?? parts[0], parts[1])
            }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        return Summary(newApps: newApps, newSites: newSites.map { (app: $0.0, site: $0.1) }, learning: isLearning(on: day))
    }
}
