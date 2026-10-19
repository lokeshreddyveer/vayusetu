import MapKit
import SwiftUI

/// Where the Mac's connections go, laid out like a network monitor: a list of destinations on the left, and a world map with a line from
/// this Mac to each country. Click a row to light up its lines; click a country on the map to see what connects there.
private struct Located: Identifiable, Sendable {
    var flow: FlowRecord
    var country: GeoCountry
    var id: Int64 { flow.id }
}

private struct Group: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var items: [Located]
    var blocked: Int { items.filter { $0.flow.verdict == .block }.count }
    var countries: [GeoCountry] { Array(Dictionary(grouping: items, by: { $0.country.code }).compactMap { $0.value.first?.country }) }
}

struct NetworkMap: View {
    let flows: [FlowRecord]
    @ObservedObject var client: FilterClient
    private enum Grouping: String, CaseIterable, Identifiable { case country = "Countries", app = "Apps"; var id: String { rawValue } }
    private enum Window: String, CaseIterable, Identifiable { case fiveMinutes = "5 min", hour = "1 hour", all = "All"; var id: String { rawValue }
        var seconds: TimeInterval? { switch self { case .fiveMinutes: 300; case .hour: 3600; case .all: nil } } }
    @State private var grouping = Grouping.country
    @State private var window = Window.hour
    @State private var blockedOnly = false
    @State private var located: [Located] = []
    @State private var unlocated = 0
    @State private var selected: String?
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25, longitude: 10), span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 300)))

    private var filtered: [FlowRecord] {
        let cutoff = window.seconds.map { Date().addingTimeInterval(-$0) }
        return flows.filter { (cutoff == nil || $0.time > cutoff!) && (!blockedOnly || $0.verdict == .block) }
    }
    private var refreshKey: String { "\(flows.last?.id ?? 0):\(flows.count):\(window.rawValue):\(blockedOnly)" }
    /// This Mac, placed at the centre of the country its region setting names. It is a guess, drawn so the lines have a start.
    private var home: GeoCountry? { GeoDatabase.shared.country(code: Locale.current.region?.identifier ?? "US") }

    private var groups: [Group] {
        switch grouping {
        case .country:
            return Dictionary(grouping: located, by: { $0.country.code }).map { key, items in
                Group(id: key, title: items[0].country.name, subtitle: "\(Set(items.map(\.flow.app)).count) app\(Set(items.map(\.flow.app)).count == 1 ? "" : "s") · \(Set(items.map(\.flow.host)).count) destination\(Set(items.map(\.flow.host)).count == 1 ? "" : "s")", items: items)
            }.sorted { $0.items.count > $1.items.count }
        case .app:
            return Dictionary(grouping: located, by: { $0.flow.app }).map { key, items in
                let places = Set(items.map(\.country.name)).sorted()
                return Group(id: key, title: items[0].flow.appName, subtitle: places.prefix(3).joined(separator: ", ") + (places.count > 3 ? " +\(places.count - 3)" : ""), items: items)
            }.sorted { $0.items.count > $1.items.count }
        }
    }
    private var countryTotals: [(country: GeoCountry, count: Int, blocked: Int)] {
        Dictionary(grouping: located, by: { $0.country.code }).map { ($0.value[0].country, $0.value.count, $0.value.filter { $0.flow.verdict == .block }.count) }
    }
    private func arcColour(_ count: Int, _ blocked: Int) -> Color { blocked == 0 ? .green : blocked == count ? .red : .orange }
    /// A gentle curve from `a` to `b`, bent sideways so overlapping lines can be told apart.
    private func arc(from a: GeoCountry, to b: GeoCountry) -> [CLLocationCoordinate2D] {
        let (x1, y1, x2, y2) = (a.longitude, a.latitude, b.longitude, b.latitude)
        let dx = x2 - x1, dy = y2 - y1, length = max(0.001, (dx * dx + dy * dy).squareRoot())
        let bend = length * 0.18
        let cx = (x1 + x2) / 2 - dy / length * bend, cy = (y1 + y2) / 2 + dx / length * bend
        return (0...24).map { i in
            let t = Double(i) / 24, u = 1 - t
            return CLLocationCoordinate2D(latitude: min(85, max(-85, u * u * y1 + 2 * u * t * cy + t * t * y2)), longitude: min(180, max(-180, u * u * x1 + 2 * u * t * cx + t * t * x2)))
        }
    }
    private func lit(_ code: String) -> Bool {
        guard let selected else { return true }
        return groups.first { $0.id == selected }?.countries.contains { $0.code == code } ?? true
    }

    var body: some View {
        MacPanel("Where connections go", icon: "map", trailing: { Text("\(countryTotals.count) countries · \(unlocated) local or unlocated").font(.system(size: 11)).foregroundStyle(.secondary) }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Picker("", selection: $grouping) { ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 170).onChange(of: grouping) { _, _ in selected = nil }
                    Picker("", selection: $window) { ForEach(Window.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    Toggle("Blocked only", isOn: $blockedOnly).toggleStyle(.checkbox).font(.system(size: 12))
                    Spacer()
                    if selected != nil { Button("Show all") { selected = nil }.buttonStyle(MacHoverButtonStyle()).fixedSize() }
                    Button("World") { camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25, longitude: 10), span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 300))) }.buttonStyle(MacHoverButtonStyle()).fixedSize()
                }
                HStack(alignment: .top, spacing: 12) {
                    list.frame(width: 290, height: 460)
                    mapView.frame(height: 460).frame(maxWidth: .infinity)
                }
                if let group = groups.first(where: { $0.id == selected }) { detail(group) }
                HStack(spacing: 16) {
                    Label("Allowed", systemImage: "circle.fill").foregroundStyle(.green)
                    Label("Blocked", systemImage: "circle.fill").foregroundStyle(.red)
                    Label("Both", systemImage: "circle.fill").foregroundStyle(.orange)
                    Label("This Mac (approximate)", systemImage: "house.fill").foregroundStyle(.blue)
                }.font(.system(size: 11))
                if !GeoDatabase.shared.available { Text("The local geolocation database is unavailable in this build.").font(.system(size: 11)).foregroundStyle(.orange) }
                Text("Country estimates come from the address, looked up on this Mac; nothing is sent anywhere. Lines go to a country's centre, not to the exact server, and local addresses are left off. The map tiles load from Apple Maps.").font(.system(size: 11)).foregroundStyle(.secondary)
                Link("IP Geolocation by DB-IP · CC BY 4.0", destination: URL(string: "https://db-ip.com/")!).font(.system(size: 11))
            }
        }.task(id: refreshKey) {
            let input = filtered
            let result = await Task.detached(priority: .utility) { () -> ([Located], Int) in
                var out: [Located] = []; var unknown = 0
                for flow in input {
                    guard let country = GeoDatabase.shared.country(for: flow.remoteAddress ?? flow.host) else { unknown += 1; continue }
                    out.append(Located(flow: flow, country: country))
                }
                return (out, unknown)
            }.value
            guard !Task.isCancelled else { return }
            located = result.0; unlocated = result.1
        }
    }

    // MARK: Left: the list
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if groups.isEmpty { Text("No public destinations in this window yet.").font(.system(size: 12)).foregroundStyle(.secondary).padding(16) }
                ForEach(groups) { group in
                    Button { selected = selected == group.id ? nil : group.id } label: {
                        HStack(spacing: 10) {
                            Circle().fill(arcColour(group.items.count, group.blocked)).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(group.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(group.items.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                if group.blocked > 0 { Text("\(group.blocked) blocked").font(.system(size: 10)).foregroundStyle(.red) }
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(selected == group.id ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Right: the map
    private var mapView: some View {
        Map(position: $camera) {
            if let home {
                Annotation("This Mac", coordinate: CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude)) {
                    Image(systemName: "house.fill").font(.system(size: 11)).foregroundStyle(.white).padding(6).background(Color.blue, in: Circle())
                }
                ForEach(countryTotals, id: \.country.code) { total in
                    if total.country.code != home.code {
                        let on = lit(total.country.code)
                        MapPolyline(coordinates: arc(from: home, to: total.country))
                            .stroke(arcColour(total.count, total.blocked).opacity(on ? 0.85 : 0.12), lineWidth: min(5, 1.2 + log2(Double(total.count) + 1) * 0.5))
                    }
                }
            }
            ForEach(countryTotals, id: \.country.code) { total in
                let on = lit(total.country.code)
                Annotation(total.country.name, coordinate: CLLocationCoordinate2D(latitude: total.country.latitude, longitude: total.country.longitude)) {
                    Button { selected = grouping == .country ? total.country.code : selected } label: {
                        Text("\(total.count)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(arcColour(total.count, total.blocked).opacity(on ? 1 : 0.35), in: Capsule())
                            .overlay(Capsule().stroke(selected == total.country.code ? Color.white : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).help("\(total.country.name): \(total.count) connections, \(total.blocked) blocked")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapZoomStepper(); MapCompass() }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Below: what is behind the selection
    private func detail(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack { Text(group.title).font(.headline); Spacer(); Text("\(group.blocked) blocked of \(group.items.count)").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(Array(group.items.reversed().prefix(40))) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.flow.verdict == .block ? "xmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(item.flow.verdict == .block ? .red : .green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(grouping == .country ? item.flow.appName : item.country.name).font(.system(size: 12, weight: .medium))
                        Text(item.flow.host + (item.flow.port.isEmpty ? "" : ":" + item.flow.port)).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Block") { client.addRule(NetRule(app: item.flow.app, host: item.flow.host, port: "*", action: .block, note: "From the map")) }.buttonStyle(MacHoverButtonStyle()).fixedSize()
                }
            }
        }
    }
}
