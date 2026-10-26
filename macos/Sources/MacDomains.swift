import Charts
import Combine
import SQLite3
import SwiftUI
import VayuSetuCore

/// The optional domain history: how many times each domain was blocked or let through, per day, kept only on this Mac.
/// Off until the user switches it on. The tunnel counts at the point where it decides a lookup; this store collects those counts every few
/// seconds and keeps them. It holds names and counts only: no times of day, no apps, no addresses.
@MainActor final class DomainHistoryStore: ObservableObject {
    static let shared = DomainHistoryStore()
    @Published private(set) var revision = 0
    @Published private(set) var failure: String?
    /// Every batch taken from the tunnel, for the live view. The history keeps it only when the user has switched the history on.
    let batches = PassthroughSubject<[DomainCount], Never>()
    @Published var retentionDays = UserDefaults.standard.object(forKey: "domain-history-days") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "domain-history-days"); purgeOld(); revision += 1 }
    }
    private var db: OpaquePointer?
    private var collecting: Task<Void, Never>?
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VayuSetuVPN", isDirectory: true).appendingPathComponent("domain-history.sqlite")
    }

    private init() {}
    deinit { if let db { sqlite3_close(db) } }

    private func open() -> OpaquePointer? {
        if let db { return db }
        let url = Self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { failure = "The domain history could not be opened."; return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS domain_day (day INTEGER NOT NULL, name TEXT NOT NULL, allowed INTEGER NOT NULL, blocked INTEGER NOT NULL, PRIMARY KEY (day, name)) WITHOUT ROWID;", nil, nil, nil)
        db = handle
        return handle
    }

    // MARK: Collecting
    /// Starts collecting from the tunnel while the switch is on and a DNS-filtering tunnel is connected. Safe to call again.
    func startCollecting(tunnel: TunnelController) {
        guard collecting == nil else { return }
        collecting = Task { [weak self, weak tunnel] in
            var announced = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let tunnel else { return }
                guard tunnel.domainCounting, tunnel.domainsAvailable else { announced = false; continue }
                if !announced { tunnel.pushDomainSetting(); announced = true; continue }
                if let taken = await tunnel.takeDomains(), !taken.isEmpty {
                    if tunnel.domainHistoryOn { self.merge(taken) }
                    self.batches.send(taken)
                }
            }
        }
    }

    private func merge(_ taken: [DomainCount]) {
        guard let db else { _ = open(); if self.db == nil { return }; return merge(taken) }
        let day = DomainHistory.day(for: Date())
        var existing: [String: (allowed: Int, blocked: Int)] = [:]
        var select: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name, allowed, blocked FROM domain_day WHERE day = ?", -1, &select, nil) == SQLITE_OK {
            sqlite3_bind_int64(select, 1, Int64(day))
            while sqlite3_step(select) == SQLITE_ROW { existing[String(cString: sqlite3_column_text(select, 0))] = (Int(sqlite3_column_int64(select, 1)), Int(sqlite3_column_int64(select, 2))) }
        }
        sqlite3_finalize(select)
        let merged = DomainHistory.merge(day: day, existing: existing, taken: taken.map { ($0.n, Int($0.a), Int($0.b)) })
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM domain_day WHERE day = \(day)", nil, nil, nil)
        var insert: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO domain_day (day, name, allowed, blocked) VALUES (?, ?, ?, ?)", -1, &insert, nil) == SQLITE_OK {
            for (name, value) in merged {
                sqlite3_reset(insert)
                sqlite3_bind_int64(insert, 1, Int64(day)); sqlite3_bind_text(insert, 2, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int64(insert, 3, Int64(value.allowed)); sqlite3_bind_int64(insert, 4, Int64(value.blocked))
                sqlite3_step(insert)
            }
        }
        sqlite3_finalize(insert)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        purgeOld()
        revision += 1
    }

    // MARK: Reading
    func rows(in days: ClosedRange<Int>) -> [DomainDayCount] {
        _ = revision
        guard let db = open() else { return [] }
        var out: [DomainDayCount] = []
        var statement: OpaquePointer?
        let low = max(days.lowerBound, -1_000_000)
        guard sqlite3_prepare_v2(db, "SELECT day, name, allowed, blocked FROM domain_day WHERE day BETWEEN ? AND ?", -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(statement, 1, Int64(low)); sqlite3_bind_int64(statement, 2, Int64(days.upperBound))
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(DomainDayCount(day: Int(sqlite3_column_int64(statement, 0)), name: String(cString: sqlite3_column_text(statement, 1)), allowed: Int(sqlite3_column_int64(statement, 2)), blocked: Int(sqlite3_column_int64(statement, 3))))
        }
        sqlite3_finalize(statement)
        return out
    }
    var isEmpty: Bool { rows(in: Int.min / 4 ... Int.max / 4).isEmpty }

    // MARK: Keeping it small, and deleting it
    func purgeOld() {
        guard let db = open() else { return }
        sqlite3_exec(db, "DELETE FROM domain_day WHERE day < \(DomainHistory.firstDayKept(now: Date(), retentionDays: retentionDays))", nil, nil, nil)
    }
    func clear() {
        guard let db = open() else { return }
        sqlite3_exec(db, "DELETE FROM domain_day", nil, nil, nil)
        sqlite3_exec(db, "VACUUM", nil, nil, nil)
        revision += 1
    }
}

/// The Domains panel on the DNS tab: the switch, a blocked-against-allowed ring, and the most blocked and most allowed domains.
struct MacDomainPanel: View {
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var history: DomainHistoryStore
    @AppStorage(ActivityPeriodStore.key) private var periodRaw = ActivityPeriod.week.rawValue
    @State private var confirmDelete = false
    @State private var detail: String?

    private var period: Binding<ActivityPeriod> { Binding(get: { ActivityPeriod(rawValue: periodRaw) ?? .week }, set: { periodRaw = $0.rawValue }) }
    private var days: ClosedRange<Int>? { DomainHistory.dayRange(period: period.wrappedValue, now: Date(), custom: ActivityPeriodStore.customRange) }

    var body: some View {
        MacPanel("Domains", icon: "globe.badge.chevron.backward", trailing: { if tunnel.domainHistoryOn { VSActivityPeriodButton(period: period) } }) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: Binding(get: { tunnel.domainHistoryOn }, set: { tunnel.setDomainHistory($0); history.startCollecting(tunnel: tunnel) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep a domain history").font(.system(size: 13, weight: .semibold))
                        Text("Counts how often each domain was blocked or let through. It stays on this Mac, with no times of day and no apps.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch)
                if tunnel.domainHistoryOn {
                    if !tunnel.domainsAvailable { Label("Counting starts when a DNS-filtering connection is on.", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                    if let range = days { content(range) } else { Text("Choose a range in the period menu.").font(.footnote).foregroundStyle(.secondary) }
                    Divider()
                    controls
                }
            }
        }
        .onAppear { if tunnel.domainHistoryOn { history.startCollecting(tunnel: tunnel) } }
        .alert("Delete the domain history?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every stored count is removed from this Mac. Collection stays \(tunnel.domainHistoryOn ? "on" : "off").") }
        .sheet(item: Binding(get: { detail.map(DomainDetailID.init) }, set: { detail = $0?.name })) { item in
            if let range = days { MacDomainDetail(name: item.name, rows: history.rows(in: range), days: range) { detail = nil }.frame(width: 440, height: 400) }
        }
    }

    @ViewBuilder private func content(_ range: ClosedRange<Int>) -> some View {
        let rows = history.rows(in: range)
        let totals = DomainHistory.totals(rows, days: range)
        if totals.total == 0 {
            Text(history.isEmpty ? "Nothing counted yet. Domains appear here as lookups are filtered." : "Nothing counted in this period.").font(.footnote).foregroundStyle(.secondary)
        } else {
            let sub = period.wrappedValue == .hour || period.wrappedValue == .today || period.wrappedValue == .day
            HStack(alignment: .top, spacing: 22) {
                ring(totals)
                VStack(alignment: .leading, spacing: 18) {
                    ranking("Most blocked", kind: .blocked, rows: rows, range: range, tint: .orange)
                    byCompany(rows, range: range)
                    ranking("Most allowed", kind: .allowed, rows: rows, range: range, tint: VSDesign.accent)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if sub { Text("The history is kept per day, so this period shows whole days.").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    /// Blocked lookups grouped by the company behind each domain. The table is short and hand-written; domains without a known company are counted apart.
    @ViewBuilder private func byCompany(_ rows: [DomainDayCount], range: ClosedRange<Int>) -> some View {
        let sums = Dictionary(grouping: rows.filter { range.contains($0.day) }, by: \.name).map { (name: $0.key, blocked: $0.value.reduce(0) { $0 + $1.blocked }) }
        let grouped = TrackerOwners.group(blocked: sums)
        if !grouped.groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("BLOCKED, BY COMPANY").font(.system(size: 11, weight: .semibold)).tracking(1.0).foregroundStyle(.secondary)
                ForEach(grouped.groups.prefix(6)) { g in
                    HStack {
                        Text(g.company).font(.system(size: 12, weight: .medium))
                        Text(g.domains.prefix(2).joined(separator: ", ") + (g.domains.count > 2 ? " +\(g.domains.count - 2)" : "")).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(g.blocked.formatted()).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if grouped.unattributed > 0 { Text("\(grouped.unattributed.formatted()) more from domains with no company on file.").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
        }
    }

    private func ring(_ totals: DomainTotals) -> some View {
        ZStack {
            Chart {
                SectorMark(angle: .value("Allowed", totals.allowed), innerRadius: .ratio(0.64), angularInset: 1.5).foregroundStyle(VSDesign.accent).cornerRadius(3)
                SectorMark(angle: .value("Blocked", totals.blocked), innerRadius: .ratio(0.64), angularInset: 1.5).foregroundStyle(Color.orange).cornerRadius(3)
            }.chartLegend(.hidden)
            VStack(spacing: 1) {
                Text("\(Int((totals.blockedShare * 100).rounded()))%").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("blocked").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(totals.total.formatted()) lookups").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }.frame(width: 150, height: 150).accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Int((totals.blockedShare * 100).rounded())) percent blocked of \(totals.total) lookups")
    }

    private func ranking(_ title: String, kind: DomainHistory.Kind, rows: [DomainDayCount], range: ClosedRange<Int>, tint: Color) -> some View {
        let ranked = DomainHistory.rank(rows, kind: kind, days: range, limit: 8)
        let top = ranked.first?.count ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.0).foregroundStyle(.secondary)
            if ranked.isEmpty { Text(kind == .blocked ? "Nothing was blocked." : "Nothing went through.").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(ranked) { row in
                Button { detail = row.name } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(row.count.formatted()).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.75)).frame(width: max(3, proxy.size.width * Double(row.count) / Double(top)))
                        }.frame(height: 4)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("\(Int((row.share * 100).rounded()))% of everything \(kind == .blocked ? "blocked" : "allowed"). Click for its history.")
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Keep for", selection: Binding(get: { history.retentionDays }, set: { history.retentionDays = $0 })) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("1 year").tag(365)
                }.pickerStyle(.menu).frame(maxWidth: 220)
                Spacer()
                Button("Delete history") { confirmDelete = true }.buttonStyle(MacHoverButtonStyle())
            }
            Text("Counts domains your Mac asked for through VayuSetu DNS filtering, only while the app is running. Apps with their own built-in DNS bypass it, and a domain asked for is not a page you opened.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DomainDetailID: Identifiable { let name: String; var id: String { name } }

/// One domain's daily counts over the chosen period.
struct MacDomainDetail: View {
    let name: String
    let rows: [DomainDayCount]
    let days: ClosedRange<Int>
    let close: () -> Void

    var body: some View {
        let series = DomainHistory.series(for: name, rows: rows, days: days)
        let blocked = series.reduce(0) { $0 + $1.blocked }, allowed = series.reduce(0) { $0 + $1.allowed }
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(name).font(.headline).lineLimit(1).truncationMode(.middle); Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
            HStack(spacing: 24) {
                MacFigure(caption: "Blocked", value: blocked.formatted(), tint: .orange)
                MacFigure(caption: "Allowed", value: allowed.formatted(), tint: VSDesign.accent)
            }
            if series.isEmpty { Text("No counts for this domain in the period.").foregroundStyle(.secondary) }
            else {
                Chart(series, id: \.day) { point in
                    let date = Date(timeIntervalSince1970: Double(point.day) * 86400)
                    BarMark(x: .value("Day", date, unit: .day), y: .value("Allowed", point.allowed)).foregroundStyle(VSDesign.accent)
                    BarMark(x: .value("Day", date, unit: .day), y: .value("Blocked", point.blocked)).foregroundStyle(Color.orange)
                }.frame(height: 190)
            }
            Text("Counts are per day. A blocked lookup was answered by VayuSetu and never left this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(20)
    }
}
