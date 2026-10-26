import Foundation
import SwiftUI
import VayuSetuCore

/// "What is new" on this Mac: apps and sites seen for the first time. It stores an app and a site per entry, nothing else, only while it is
/// switched on, and switching it off deletes what it kept. Alerts are off by default; the daily list is the quiet way to read it.
@MainActor final class FirstSeenStore: ObservableObject {
    static let shared = FirstSeenStore()
    @Published private(set) var revision = 0
    private var tracker = FirstSeenTracker()
    private var dirty = false
    private var saving: Task<Void, Never>?
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VayuSetuVPN", isDirectory: true).appendingPathComponent("first-seen.json")
    }
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "first-seen-on") }
        set {
            UserDefaults.standard.set(newValue, forKey: "first-seen-on")
            if newValue { load() } else { clear() }
            revision += 1
        }
    }
    var notifyNewApps: Bool {
        get { UserDefaults.standard.bool(forKey: "first-seen-notify") }
        set { UserDefaults.standard.set(newValue, forKey: "first-seen-notify"); revision += 1 }
    }
    private init() { if enabled { load() } }

    private func load() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(FirstSeenTracker.self, from: data) { tracker = saved }
    }
    func clear() {
        tracker = FirstSeenTracker(); dirty = false
        try? FileManager.default.removeItem(at: Self.url)
    }
    var summaryToday: FirstSeenTracker.Summary { tracker.summary(day: DomainHistory.day(for: Date())) }
    var trackedApps: Int { tracker.apps.count }

    /// Called with each batch of new connections the network filter reports.
    func ingest(_ flows: [FlowRecord]) {
        guard enabled else { return }
        let day = DomainHistory.day(for: Date())
        var announce: [String] = []
        for flow in flows where flow.outbound {
            if case .newApp(_, let name)? = tracker.record(app: flow.app, name: flow.appName, host: flow.host.isEmpty ? (flow.remoteAddress ?? "") : flow.host, day: day) { announce.append(name) }
        }
        guard !flows.isEmpty else { return }
        dirty = true; revision += 1
        if notifyNewApps, !announce.isEmpty {
            AlertNotifier.post(id: "first-seen", title: "New app on the network", body: announce.prefix(3).joined(separator: ", ") + " connected for the first time.")
        }
        scheduleSave()
    }
    private func scheduleSave() {
        guard saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self else { return }
            self.saving = nil
            guard self.dirty, self.enabled else { return }
            self.dirty = false
            try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(self.tracker) { try? data.write(to: Self.url, options: .atomic) }
        }
    }
}

struct MacFirstSeenPanel: View {
    @ObservedObject var store: FirstSeenStore
    var body: some View {
        let _ = store.revision
        MacPanel("What is new", icon: "sparkle.magnifyingglass") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { store.enabled }, set: { store.enabled = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep track of what is new").font(.system(size: 13, weight: .semibold))
                        Text("Remembers which apps have connected and to which sites, to show what appeared for the first time today. It stores an app and a site per entry, no times, and switching this off deletes it. The first three days only learn.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch)
                if store.enabled {
                    let s = store.summaryToday
                    if s.learning { Label("Learning what is normal here (\(store.trackedApps) apps so far). New things are listed after three days.", systemImage: "hourglass").font(.system(size: 12)).foregroundStyle(.secondary) }
                    else if s.newApps.isEmpty && s.newSites.isEmpty { Label("Nothing new today.", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary) }
                    else {
                        if !s.newApps.isEmpty { list("New apps today", s.newApps) }
                        if !s.newSites.isEmpty { list("New sites today", s.newSites.prefix(12).map { "\($0.app) → \($0.site)" }) }
                    }
                    Toggle(isOn: Binding(get: { store.notifyNewApps }, set: { store.notifyNewApps = $0 })) {
                        Text("Notify me when an app connects for the first time").font(.system(size: 12))
                    }.toggleStyle(.switch)
                }
            }
        }
    }
    private func list(_ title: String, _ rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.0).foregroundStyle(.secondary)
            ForEach(rows, id: \.self) { Text($0).font(.system(size: 12)).lineLimit(1).truncationMode(.middle) }
        }
    }
}

/// Apps that appear to ask for names through their own encrypted DNS, which VayuSetu's lists cannot see.
struct MacDNSBypassPanel: View {
    let flows: [FlowRecord]
    var body: some View {
        let found = DNSBypassDetector.findings(flows.map { BypassFlow(app: $0.app, appName: $0.appName, host: $0.host, port: $0.port, proto: $0.proto, remoteAddress: $0.remoteAddress, outbound: $0.outbound) })
        MacPanel("Apps with their own DNS", icon: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 10) {
                if found.isEmpty {
                    Label("No app was seen using its own encrypted DNS.", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(found) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.appName).font(.system(size: 13, weight: .semibold))
                            Text(f.message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Judged from the connections the network filter has recorded: a connection to a public resolver on a DNS-only port or name. It is a likely sign, not proof, and VayuSetu cannot block it, only point it out.").font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
