import WidgetKit
import SwiftUI
import AppIntents

// MARK: Home Screen and Lock Screen status
struct StatusEntry: TimelineEntry { let date: Date; let status: WidgetStatus }

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: Date(), status: WidgetStatus(mode: "VPN + DNS", vpn: true, dns: true, adblock: true, profile: nil)) }
    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) { completion(StatusEntry(date: Date(), status: WidgetStatus.read())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // The app reloads this whenever protection changes; there is nothing to poll.
        completion(Timeline(entries: [StatusEntry(date: Date(), status: WidgetStatus.read())], policy: .never))
    }
}

private struct StatusDot: View {
    let label: String, on: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.green : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
            Text(label).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(on ? Color.primary : Color.secondary)
        }
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry
    var body: some View {
        let s = entry.status
        switch family {
        case .accessoryInline: Text("VayuSetu · " + s.mode)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("VayuSetu").font(.headline)
                Text(s.mode).font(.caption)
                Text([s.vpn ? "VPN" : nil, s.dns ? "DNS" : nil, s.adblock ? "Ads" : nil].compactMap { $0 }.joined(separator: " · ").isEmpty ? "All off" : [s.vpn ? "VPN" : nil, s.dns ? "DNS" : nil, s.adblock ? "Ads" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) { Image(systemName: "wind").foregroundStyle(Color(red: 0.35, green: 0.78, blue: 1.0)); Text("VayuSetu").font(.system(size: 14, weight: .semibold, design: .rounded)) }
                Text(s.mode).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(2).minimumScaleFactor(0.8)
                if let profile = s.profile, family != .systemSmall { Text(profile).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                HStack(spacing: 12) { StatusDot(label: "VPN", on: s.vpn); StatusDot(label: "DNS", on: s.dns); StatusDot(label: "Ads", on: s.adblock) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct VayuSetuStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.vayusetu.status", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry).containerBackground(for: .widget) { Color(red: 0.055, green: 0.085, blue: 0.125) }
                .environment(\.colorScheme, .dark)
        }
        .configurationDisplayName("VayuSetu status")
        .description("Shows whether the VPN, DNS protection and Safari ad blocking are on. Tap to open VayuSetu.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: Control Center (iOS 18 and later)
@available(iOS 18.0, *)
struct DNSOnlyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.vayusetu.control.dns") {
            ControlWidgetButton(action: TurnOnDNSOnlyIntent()) { Label("DNS Only", systemImage: "network") }
        }.displayName("DNS Only").description("Starts encrypted DNS and filtering.")
    }
}
@available(iOS 18.0, *)
struct VPNControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.vayusetu.control.vpn") {
            ControlWidgetButton(action: TurnOnVPNIntent()) { Label("Connect VPN", systemImage: "shield.lefthalf.filled") }
        }.displayName("Connect VPN").description("Connects the selected VPN profile.")
    }
}
@available(iOS 18.0, *)
struct TurnOffControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.vayusetu.control.off") {
            ControlWidgetButton(action: TurnOffProtectionIntent()) { Label("Turn Off", systemImage: "power") }
        }.displayName("Turn Off VPN & DNS").description("Disconnects the VPN and stops DNS protection.")
    }
}
@available(iOS 18.0, *)
struct AdblockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.vayusetu.control.adblock") {
            ControlWidgetButton(action: TurnOnAdblockIntent()) { Label("Ad Blocking", systemImage: "hand.raised.slash") }
        }.displayName("Safari Ad Blocking").description("Switches Safari ad blocking on.")
    }
}
