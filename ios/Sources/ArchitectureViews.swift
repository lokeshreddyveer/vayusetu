import SwiftUI
import SafariServices
import UserNotifications
#if os(iOS)
import AVFoundation
#endif
import VayuSetuCore
import NetworkExtension

struct VSConnectionDetailsScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @StateObject private var network = NetworkDiagnostics()
    private var profile: SavedProfile? { store.profiles.first(where: { $0.id == tunnel.configuredProfile }) ?? store.active }
    private var counters: TunnelCounterSample? { tunnel.observedCounters() }
    private var isWireGuard: Bool { tunnel.protocolName == "WireGuard" }
    var body: some View {
        VSCardList {
            VSSection {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.observedMode.title).font(.headline)
                    Text(store.protection(.vpn).label).font(.subheadline).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(tunnel.status == .connected ? "Connected for " + tunnel.duration : "No established session").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
            if tunnel.running {
                VSSection("Connection") {
                    VSEvidenceRow(title: "Profile", value: profile?.name ?? store.connectionName ?? "Unknown")
                    VSEvidenceRow(title: "Type", value: tunnel.localDNSRunning ? "VayuSetu DNS tunnel (no VPN server)" : store.connectionProtocol)
                    if isWireGuard, let endpoint = profile?.endpoints.first { VSEvidenceRow(title: "Server", value: endpoint) }
                    if isWireGuard {
                        VSEvidenceRow(title: "Last handshake", value: tunnel.stats?.latestHandshake.map { $0.formatted(.relative(presentation: .named)) } ?? "Waiting for the first handshake")
                    }
                }
                if counters != nil {
                    VSSection("Traffic") {
                        VSEvidenceRow(title: "Download now", value: rate(tunnel.receivedPerSecond))
                        VSEvidenceRow(title: "Upload now", value: rate(tunnel.sentPerSecond))
                        VSEvidenceRow(title: "Received this session", value: bytes(counters?.received))
                        VSEvidenceRow(title: "Sent this session", value: bytes(counters?.sent))
                    }
                } else {
                    VSSection { Text(tunnel.localDNSRunning ? "DNS Only carries DNS questions, not your traffic, so there are no transfer totals." : "This connection type does not report transfer totals to the app.").font(.footnote).foregroundStyle(.secondary) } header: { Text("Traffic") }
                }
                VSSection("DNS") {
                    VSEvidenceRow(title: "Source", value: tunnel.protocolName == "IKEv2" ? "Set by the VPN server" : "VayuSetu encrypted resolver")
                    VSEvidenceRow(title: "Applied", value: tunnel.appliedDNSDescription)
                    if let c = tunnel.stats?.dnsCounters { VSEvidenceRow(title: "Answered / blocked", value: "\(c.answered.formatted()) / \(c.blocked.formatted())") }
                }
            }
            VSSection("Routing") {
                VSNavLink { VSPrivacyLockScreen(store: store, tunnel: tunnel) } label: {
                    VSEvidenceRow(title: "Privacy Lock", value: store.strictRouting ? "On" : "Off")
                }.accessibilityIdentifier("ConnectionPrivacyLock")
                VSNavLink { VSRoutingEvidenceScreen(store: store, tunnel: tunnel, network: network) } label: { Text("Routing & Verification") }
                    .accessibilityIdentifier("ConnectionRoutingEvidence")
            }
            VSSection("Actions") {
                Button("Disconnect") { Task { await store.powerOffNetwork() } }.disabled(!tunnel.running || tunnel.busy)
                VSNavLink { VSProfilesScreen(store: store, tunnel: tunnel) } label: { Text("Switch Profile") }
                VSNavLink { VSChecksScreen(store: store, tunnel: tunnel, network: network) } label: { Text("Run Checks") }
                VSNavLink { VSLogsScreen(tunnel: tunnel) } label: { Text("Connection Events") }
            }
        }.vsList().vsCompactDetails().vsHeader("Connection Details").vsEditor()
    }
    func bytes(_ value: UInt64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .binary) } ?? "—" }
    func rate(_ value: Double) -> String { tunnel.ratesAvailable ? String(format: "%.2f Mbps", value * 8 / 1_000_000) : "—" }
}
struct VSHomeActions: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var network: NetworkDiagnostics
    @ObservedObject var filtering: FilteringController
    init(store: AppStore, tunnel: TunnelController, network: NetworkDiagnostics) { self.store = store; self.tunnel = tunnel; self.network = network; filtering = store.filtering }
    var body: some View {
        #if os(iOS)
        homeActions
        #else
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                NavigationLink { VSChecksScreen(store: store, tunnel: tunnel, network: network) } label: { VSRow(title: "Run Checks", subtitle: "On-demand IP, DNS and route observations", icon: "waveform.path.ecg", chevron: true) }
                Divider().padding(.vertical, 8)
                NavigationLink { VSProfilesScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Switch Profile", icon: "point.3.connected.trianglepath.dotted", chevron: true) }
                Divider().padding(.vertical, 8)
                NavigationLink { VSConnectionDetailsScreen(store: store, tunnel: tunnel) } label: { VSRow(title: "Connection Details", icon: "info.circle", chevron: true) }
            }.buttonStyle(VSPlainButtonStyle()).padding(12).background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 12) {
                Text("RECENT ACTIVITY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if filtering.events.isEmpty { Text("No recent activity").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(Array(filtering.events.prefix(3).enumerated()), id: \.offset) { _, event in Text(event).font(.caption).foregroundStyle(.secondary) }
                NavigationLink { VSActivityScreen(filtering: filtering, tunnel: tunnel) } label: { Text("View All Activity").font(.subheadline.weight(.medium)) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        #endif
    }
    #if os(iOS)
    private var recent: [HomeActivitySummary] {
        let privacy = filtering.recentEvents.compactMap { HomeActivitySummary.privacy($0) }
        let connections = tunnel.structuredEvents.compactMap { HomeActivitySummary.connection($0) }
        let sorted = (privacy + connections).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        var summaries: [HomeActivitySummary] = []
        for event in sorted where summaries.last?.title != event.title {
            summaries.append(event)
            if summaries.count == 3 { break }
        }
        return summaries
    }
    private var homeActions: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("QUICK ACTIONS")
                NavigationLink { VSChecksScreen(store: store, tunnel: tunnel, network: network) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 22)).foregroundStyle(.secondary)
                        Text("Run Privacy Checks").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, minHeight: 60)
                        .background(VSDesign.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VSDesign.separator, lineWidth: 1))
                }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("HomePrivacyChecks")
            }
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("RECENT ACTIVITY")
                if recent.isEmpty { Text("No recent activity").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(recent) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.icon).font(.caption).foregroundStyle(.secondary).frame(width: 16)
                        Text(event.title).font(.subheadline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(event.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
                NavigationLink { VSActivityScreen(filtering: filtering, tunnel: tunnel) } label: {
                    HStack { Text("View All Activity").font(.subheadline.weight(.medium)); Spacer(); Image(systemName: "chevron.right").font(.caption) }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(VSPlainButtonStyle()).accessibilityIdentifier("HomeAllActivity")
            }
        }
    }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary) }
    #endif
}

/// Fixed summaries prevent raw diagnostic detail from reaching the Home dashboard.
private struct HomeActivitySummary: Identifiable {
    let id: String
    let date: Date
    let title: String
    let icon: String
    static func privacy(_ event: LocalPrivacyEvent) -> Self? {
        let title: String
        switch event.message {
        case let text where text.hasPrefix("Safari rules reloaded"): title = "Safari rules applied"
        case "Filter configuration saved; Safari application pending": title = "Safari configuration saved"
        case let text where text.hasPrefix("Filter-list update failed"), let text where text.hasPrefix("Filter update failed"): title = "Filter update failed"
        case "Controlled Safari compilation and rollback passed": title = "Safari rules test completed"
        case "Interrupted Safari update recovered; previous rules reloaded": title = "Safari rules recovered"
        case let text where text.hasPrefix("Privacy Lock temporarily relaxed"): title = "Privacy Lock relaxed"
        case let text where text.hasPrefix("Strict routing restored"): title = "Privacy Lock policy restored"
        case let text where text.hasPrefix("Emergency reset requested"): title = "Emergency reset requested"
        case let text where text.hasPrefix("Owned Keychain configuration metadata recovered"): title = "Saved configuration recovered"
        case "Custom subscription added; no download started": title = "Filter subscription added"
        default: return nil
        }
        return Self(id: "privacy-" + String(event.id), date: event.timestamp, title: title, icon: "clock")
    }
    static func connection(_ event: ConnectionEvent) -> Self? {
        let title: String
        switch event.message {
        case "Tunnel established · unverified", "Connected · checks verified", "Tunnel established · verification incomplete": title = "VPN tunnel established"
        case "Disconnected": title = "VPN disconnected"
        case "Connecting": title = "VPN connecting"
        case "Reconnecting": title = "VPN reconnecting"
        case "Disconnecting": title = "VPN disconnecting"
        case "Connection failed", "Connection setup failed; previous configuration restored": title = "VPN connection failed"
        case "Network unavailable": title = "Network unavailable"
        case "Connection checks completed; routing security remains unverified": title = "Connection checks completed"
        case "Emergency reset removed managed VPN configurations": title = "VPN configuration reset"
        default: return nil
        }
        return Self(id: "vpn-" + event.id.uuidString, date: event.timestamp, title: title, icon: "network")
    }
}

struct VSPrivacyLockScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @StateObject private var network = NetworkDiagnostics()
    @AppStorage("privacy-lock-relaxed") private var relaxed = false
    @State private var relaxing = false
    @State private var restoring = false
    @State private var trusted = TrustedNetworks.saved
    @State private var newNetwork = ""
    private func addNetwork() {
        let updated = TrustedNetworks.normalized(trusted + [newNetwork])
        guard updated.count > trusted.count else { newNetwork = ""; return }
        trusted = updated; TrustedNetworks.save(updated); newNetwork = ""
    }
    var body: some View {
        VSCardList {
            VSSection {
                VSEvidenceRow(title: "Requested policy", value: store.strictRouting ? "Strict" : "Compatibility")
                VSEvidenceRow(title: "Applied configuration", value: tunnel.appliedConfigurationDescription)
                VSEvidenceRow(title: "Isolation verification", value: "Not verified")
                Toggle("Privacy Lock", isOn: $store.strictRouting).disabled(tunnel.running || tunnel.busy)
                Toggle("Require dual-stack WireGuard profile", isOn: $store.requireNativeIPv6).disabled(tunnel.running || tunnel.busy)
                Text("Requires an IPv6 tunnel address and IPv6 default route in the profile. This does not require IPv6 from your Wi-Fi or cellular network, or prove IPv6 leak prevention. IKEv2 cannot connect with this requirement enabled.").font(.caption).foregroundStyle(.secondary)
                Toggle("Allow local network", isOn: Binding(get: { !store.strictRouting && tunnel.allowLAN }, set: { tunnel.allowLAN = $0; UserDefaults.standard.set($0, forKey: "allow-lan") })).disabled(tunnel.running || tunnel.busy || store.strictRouting)
                Toggle("Connect on demand", isOn: Binding(get: { store.strictRouting || store.onDemand }, set: { store.onDemand = $0 })).disabled(tunnel.running || tunnel.busy || store.strictRouting)
                Toggle("Automatic reconnect", isOn: Binding(get: { tunnel.autoReconnect }, set: { tunnel.autoReconnect = $0; UserDefaults.standard.set($0, forKey: "auto-reconnect") }))
            } header: { Text("Routing policy") } footer: { Text("Privacy Lock requests strict routing and on-demand connection using Apple’s supported controls. OS-required exceptions may remain. It is not an absolute kill switch. Changes apply on the next connection.") }
            VSSection {
                ForEach(trusted, id: \.self) { name in
                    HStack(spacing: 10) {
                        Image(systemName: "wifi").foregroundStyle(.secondary)
                        Text(name)
                        Spacer(minLength: 8)
                        Button { trusted.removeAll { $0 == name }; TrustedNetworks.save(trusted) } label: { Image(systemName: "trash").foregroundStyle(.red).frame(width: 36, height: 36) }
                            .buttonStyle(VSPlainButtonStyle()).accessibilityLabel("Remove \(name)")
                    }
                }
                HStack(spacing: 8) {
                    TextField("Wi-Fi network name", text: $newNetwork).vsInput().submitLabel(.done).onSubmit(addNetwork)
                    Button("Add", action: addNetwork).disabled(newNetwork.trimmingCharacters(in: .whitespaces).isEmpty || trusted.count >= TrustedNetworks.limit)
                }
            } header: { Text("Trusted Wi-Fi") } footer: {
                Text(store.strictRouting
                     ? "Privacy Lock is on, so trusted networks are ignored: it keeps the VPN on everywhere. Turn Privacy Lock off to use them."
                     : "With Connect on demand on, the VPN switches off on these Wi-Fi networks and on again everywhere else. Type the name exactly as Wi-Fi shows it. Applies the next time you connect.")
            }
            VSSection("Recovery") {
                if relaxed {
                    Label("Privacy Lock is temporarily relaxed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Restore Strict Policy") { restoring = true }
                } else { Button("Temporarily Relax Privacy Lock") { relaxing = true }.disabled(!store.strictRouting || tunnel.busy) }
                VSNavLink { VSEmergencyResetScreen(store: store, tunnel: tunnel) } label: { Text("Emergency Reset") }
            }
            VSSection("Details") {
                VSNavLink { VSRoutingEvidenceScreen(store: store, tunnel: tunnel, network: network) } label: { Text("Technical Details") }.accessibilityIdentifier("PrivacyTechnicalDetails")
                VSNavLink { VSConflictsScreen(store: store, tunnel: tunnel) } label: { Text("Compatibility & Conflicts") }
            }
            VSSection("Connection recovery") { RetryPreferences(tunnel: tunnel, store: store) }
        }.vsList().vsCompactDetails().vsHeader("Privacy Lock").vsEditor()
        .vsConfirm(isPresented: $relaxing, title: "Temporarily relax routing?", message: "This disconnects VayuSetu and disables its on-demand policy. Traffic may use the ordinary network until you reconnect. Restore Strict Policy stays visible here.", confirm: "Temporarily Relax", destructive: true, icon: "lock.open.fill") { Task { store.stopPendingConnectionRequests(); await tunnel.emergencyReset(); store.strictRouting = false; store.onDemand = false; relaxed = true; store.filtering.record("Privacy Lock temporarily relaxed; restore explicitly after network recovery") } }
        .vsConfirm(isPresented: $restoring, title: "Restore strict routing?", message: "The current tunnel disconnects. Strict policy applies when you explicitly reconnect.", confirm: "Restore Strict Policy", icon: "lock.shield.fill") { Task { store.stopPendingConnectionRequests(); await tunnel.disconnect(); store.strictRouting = true; relaxed = false; store.filtering.record("Strict routing restored as desired policy; reconnect to apply") } }
    }
}
struct VSEmergencyResetScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var dns: SystemDNSController
    @State private var confirming = false
    @State private var resetting = false
    @State private var result = ""
    init(store: AppStore, tunnel: TunnelController) { self.store = store; self.tunnel = tunnel; dns = store.systemDNS }
    var body: some View {
        VSCardList {
            VSSection { Text("Emergency Reset stops VayuSetu-managed VPN and DNS configuration. Other apps’ settings are outside its control.").font(.subheadline) }
            VSSection("Current state") { VSRow(title: "VPN", value: tunnel.statusText); VSRow(title: "OS encrypted DNS", value: dns.snapshot().label) }
            VSSection("Reset actions") { Label("Cancel pending connect and switch operations", systemImage: "xmark.circle"); Label("Disconnect and remove managed VPN configuration", systemImage: "power"); Label("Remove VayuSetu-managed DNS settings", systemImage: "network"); Text("Removing the VPN configuration removes its applied routing controls. Saved strict policy can be reapplied by explicitly reconnecting.").font(.footnote).foregroundStyle(.secondary) }
            VSSection { Text("After reset, reconnecting a saved profile asks iOS to recreate its VPN configuration if needed. Ordinary network DNS may apply until you enable encrypted DNS again.").font(.footnote).foregroundStyle(.secondary) }
            VSSection("Preserved data") { Text("Saved VPN profiles and Keychain credentials"); Text("DNS resolver profiles"); Text("Filter lists and custom rules"); Text("Safari remains separately controlled in Adblock.").font(.footnote).foregroundStyle(.secondary) }
            VSSection { Button(resetting ? "Resetting…" : "Confirm Emergency Reset", role: .destructive) { confirming = true }.disabled(resetting); if !result.isEmpty { Text(result).font(.footnote).textSelection(.enabled) } }
        }.vsList().vsCompactDetails().vsHeader("Emergency Reset").vsEditor()
        .vsConfirm(isPresented: $confirming, title: "Disable VayuSetu VPN and DNS?", message: "Profiles, keys and filter rules are preserved. Manual system settings steps are shown if any operation cannot be confirmed.", confirm: "Reset", destructive: true, icon: "power") { resetting = true; Task { await store.emergencyReset(); result = store.notice; store.notice = ""; resetting = false } }
    }
}
struct VSConflictsScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var dns: SystemDNSController
    @ObservedObject var filtering: FilteringController
    init(store: AppStore, tunnel: TunnelController) { self.store = store; self.tunnel = tunnel; dns = store.systemDNS; filtering = store.filtering }
    private func yes(_ value: Bool) -> String { value ? "Yes" : "No" }
    private func capability(_ title: String, _ owner: RuntimeKind) -> some View {
        let a = RuntimeAbilities.current(owner)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if !a.available { Text(a.unavailableReason ?? "Not available in this version.").font(.caption).foregroundStyle(.secondary) }
            else {
                Text("Uses your chosen encrypted DNS: \(yes(a.appliesSelectedResolver)) · Filter lists: \(yes(a.hostsLocalFiltering)) · Never falls back to plain DNS: \(yes(a.enforcesStrictDNS))").font(.caption).foregroundStyle(.secondary)
                if let reason = a.filteringUnavailableReason { Text(reason).font(.caption).foregroundStyle(.orange) }
            }
        }.padding(.vertical, 2)
    }
    var body: some View {
        VSCardList {
            VSSection("Things that may conflict") {
                if tunnel.running && dns.hasSavedConfiguration { Label("An older iOS DNS profile is still saved and may compete with VayuSetu. Remove it on the DNS screen.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if filtering.configuration.safariDesired && filtering.enabled != true { Label("Safari protection is on but some Safari extensions are off. \(filtering.extensionSummary).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if store.protection(.vpn).observed == .error { Label(store.protection(.vpn).reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if !(tunnel.running && dns.hasSavedConfiguration) && !(filtering.configuration.safariDesired && filtering.enabled != true) && store.protection(.vpn).observed != .error {
                    Label("No conflicts detected", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                Text("Other apps’ VPN settings cannot be seen by VayuSetu. iOS runs one VPN at a time, so another VPN app switching on will turn VayuSetu’s off.").font(.footnote).foregroundStyle(.secondary)
            }
            VSSection("How each connection handles DNS") {
                capability("DNS Only (VayuSetu DNS tunnel)", .localDNS)
                capability("WireGuard", .vpn(.wireGuard))
                capability("IKEv2", .vpn(.ikev2))
                capability("OpenVPN", .vpn(.openVPN))
            }
            VSSection("Safari") { VSRow(title: "Content blocker extensions", value: filtering.extensionSummary); VSRow(title: "Rules in Safari", value: "\((filtering.configuration.safariApplied ?? 0).formatted())") }
            VSSection { Text("A matching IP or resolver answer does not prove that other apps are isolated. VayuSetu reports its own state and conflicts it can measure.").font(.footnote).foregroundStyle(.secondary) }
            VSSection { VSNavLink { VSExtensionStatusScreen(store: store, tunnel: tunnel) } label: { Text("Extension Status") }; VSNavLink { VSEmergencyResetScreen(store: store, tunnel: tunnel) } label: { Text("Recovery") } }
        }.vsList().vsHeader("Compatibility").task { await dns.refresh(); await filtering.refresh() }
    }
}
struct VSExtensionStatusScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var filtering: FilteringController
    @ObservedObject var dns: SystemDNSController
    init(store: AppStore, tunnel: TunnelController) { self.store = store; self.tunnel = tunnel; filtering = store.filtering; dns = store.systemDNS }
    var body: some View {
        VSCardList {
            VSSection("VPN and DNS tunnel") {
                VSRow(title: "Availability", value: TunnelController.available ? "Available" : "Needs the signed build")
                VSRow(title: "State", value: tunnel.statusText)
                VSRow(title: "Running", value: tunnel.localDNSRunning ? "VayuSetu DNS tunnel" : tunnel.running ? tunnel.protocolName : "Nothing")
                if !tunnel.message.isEmpty { Text(tunnel.message).font(.footnote) }
                Text(tunnel.configuredPolicySummary).font(.footnote).foregroundStyle(.secondary)
            }
            VSSection("Safari content blockers") {
                ForEach(SafariExtensionID.allCases) { id in
                    let state = filtering.extensionStates[id]
                    let rules = filtering.configuration.safariExtensionRules?[id.rawValue] ?? 0
                    VSRow(title: "VayuSetu " + id.title, subtitle: rules == 0 ? "No rules" : "\(rules.formatted()) rules · " + (state?.reloaded == true ? "loaded" : "not confirmed"), value: state?.enabled.map { $0 ? "On" : "Off" } ?? "Unknown")
                }
                VSNavLink { VSSafariScreen(filtering: filtering) } label: { Text("Safari Details") }
            }
            if dns.hasSavedConfiguration {
                VSSection("Older iOS DNS profile") { VSRow(title: "State", value: dns.snapshot().label); Text("An earlier version saved an iOS DNS profile. VayuSetu no longer uses one; remove it on the DNS screen.").font(.footnote).foregroundStyle(.secondary) }
            }
        }.vsList().vsHeader("Extension Status").task { await filtering.refresh(); await dns.refresh() }
    }
}
struct VSActivityScreen: View {
    @ObservedObject var filtering: FilteringController
    @ObservedObject var tunnel: TunnelController
    @AppStorage("local-events-retention-days") private var retention = 7
    @State private var category = "All"
    @State private var clearing = false
    var rows: [String] { filtering.events.filter { category == "All" || $0.localizedCaseInsensitiveContains(category) } }
    var body: some View {
        VSCardList {
            VSSection { Picker("Category", selection: $category) { ForEach(["All", "VPN", "DNS", "Safari", "Filter", "Privacy Lock"], id: \.self) { Text($0).tag($0) } }; Picker("Retention", selection: $retention) { Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) } }
            VSSection("VPN events") { ForEach(tunnel.structuredEvents.prefix(200)) { event in VStack(alignment: .leading, spacing: 4) { Text(event.message).font(.subheadline); Text(event.timestamp, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) } } }
            VSSection("Local events") { ForEach(Array(rows.enumerated()), id: \.offset) { _, event in Text(event).font(.footnote) }; if rows.isEmpty { ContentUnavailableView("No Recent Activity", systemImage: "clock", description: Text("Actual protection events appear here. Browsing and DNS query history are not collected.")) } }
            VSSection { ShareLink("Export Redacted Events", item: rows.joined(separator: "\n")); Button("Clear History", role: .destructive) { clearing = true } }
        }.vsList().vsHeader("Privacy Activity").vsConfirm(isPresented: $clearing, title: "Delete local event history?", message: "Events recorded on this device are removed. Nothing leaves your phone either way.", confirm: "Delete", destructive: true, icon: "trash.fill") { filtering.clearEvents() }
    }
}
struct VSAppearanceScreen: View {
    @AppStorage("appearance") private var appearance = "dark"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View { VSCardList { VSSection("Theme") { Picker("Theme", selection: $appearance) { Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system") }.pickerStyle(.segmented).labelsHidden() }; VSSection("Accessibility") { VSRow(title: "Reduce Motion", value: reduceMotion ? "System setting enabled" : "System setting disabled"); Text("Text follows Dynamic Type. Icons include status labels and VoiceOver descriptions; color alone is never the protection signal.").font(.footnote).foregroundStyle(.secondary) } }.vsList().vsHeader("Appearance") }
}
struct VSNotificationsScreen: View {
    @ObservedObject var tunnel: TunnelController
    var body: some View { VSCardList { VSSection { Toggle("Connection notifications", isOn: Binding(get: { tunnel.notificationsEnabled }, set: { tunnel.setNotifications($0) })) } footer: { Text("Requests system permission only when enabled. Reports actual VPN connection changes and configured data thresholds. No advertising or promotional notifications.") }; VSSection("Scope") { Text("DNS and filter-update failures remain visible in the app. Filter lists refresh in the background when iOS allows it; that never sends a notification.").font(.footnote).foregroundStyle(.secondary) } }.vsList().vsHeader("Notifications") }
}
struct VSOnboardingScreen: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarding-complete") private var completed = false
    var body: some View {
        VSCardList {
            VSSection { VStack(alignment: .leading, spacing: 12) { VSPrivacyGlyph(subsystem: .vpn).foregroundStyle(VSDesign.accent); Text("Welcome to VayuSetu").font(.title2.weight(.semibold)); Text("Your VPN profiles, encrypted DNS and Safari rules, in one native control center.").foregroundStyle(.secondary) }.padding(.vertical, 12) }
            VSSection("Privacy first") { Label("Local-first storage", systemImage: "iphone"); Label("No mandatory account", systemImage: "person.crop.circle.badge.checkmark"); Label("No telemetry or browsing history", systemImage: "hand.raised"); Text("External checks and list downloads run only when requested. Permission prompts appear when the corresponding feature is used.").font(.footnote).foregroundStyle(.secondary) }
            VSSection("Optional setup") { VSNavLink { VSProtectionPermissionsScreen(store: store, tunnel: store.tunnel) } label: { Text("Review & Request Permissions") }; VSNavLink { VSProfilesScreen(store: store, tunnel: store.tunnel) } label: { Text("Add Your VPN Profile") }; VSNavLink { VSDNSScreen(store: store, tunnel: store.tunnel) } label: { Text("Configure Encrypted DNS") }; VSNavLink { VSSafariScreen(filtering: store.filtering) } label: { Text("Set Up Safari") } }
            VSSection { Button("Open VayuSetu") { completed = true; dismiss() }.buttonStyle(VSActionStyle(primary: true)) }
        }.vsList().vsHeader("Welcome").vsEditor().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip Setup") { completed = true; dismiss() }.vsTapHaptic() } }
    }
}

struct VSProtectionPermissionsScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var filtering: FilteringController
    @ObservedObject var dns: SystemDNSController
    @State private var notificationStatus = "Checking…"
    @State private var cameraStatus = "Checking…"
    @Environment(\.scenePhase) private var scenePhase
    @State private var message = ""
    #if os(macOS)
    @StateObject private var extensions = ExtensionManager()
    #endif
    init(store: AppStore, tunnel: TunnelController) { self.store = store; self.tunnel = tunnel; filtering = store.filtering; dns = store.systemDNS }
    var body: some View {
        VSCardList {
            VSSection("Saved configuration") { Button("Recover Saved Configuration") { store.recoverSavedConfiguration() }.disabled(tunnel.running || tunnel.busy); Text("Recovers missing metadata from this app’s existing Keychain entries. No keys are exported and no connection is started.").font(.footnote).foregroundStyle(.secondary) }
            VSSection("VPN permission") {
                VSRow(title: "System VPN state", value: tunnel.statusText)
                Text("The system asks to add a VPN configuration when you first connect. WireGuard needs a profile and encrypted resolver; IKEv2 uses its saved native configuration and server-managed DNS.").font(.footnote).foregroundStyle(.secondary)
                Button("Connect & Request VPN Permission") {
                    #if os(macOS)
                    extensions.activate { store.connect() }
                    #else
                    store.connect()
                    #endif
                }.disabled((store.selectedManualProfile == nil ? (store.dnsOnlyChosen ? store.endpoint.isEmpty : store.active == nil || store.endpoint.isEmpty) : !store.manualDrafts.contains(where: { $0.id == store.selectedManualProfile && $0.protocolKind == .ikev2 })) || tunnel.running || tunnel.busy || store.connectionOperation || !TunnelController.available)
                #if os(macOS)
                Button("Request VPN System Extension Activation") { extensions.activate() }.disabled(extensions.requesting || !TunnelController.available)
                if !extensions.message.isEmpty { Text(extensions.message).font(.footnote) }
                #endif
            }
            VSSection("Safari content blockers") {
                VSRow(title: "Extensions", value: filtering.extensionSummary)
                VSRow(title: "Rules", value: filtering.configuration.pendingApply == true ? "Waiting to apply" : filtering.packageReady ? "Loaded in Safari" : "Not confirmed by Safari")
                Button("Open Safari Extension Settings") { openSafariSettings() }
                Button("Refresh & Apply Pending Rules") { Task { await filtering.refresh(); if filtering.extensionStates.values.contains(where: { $0.enabled == true }) { await filtering.reload() } } }.disabled(filtering.busy)
                Text("Safari controls each extension’s switch. Turn on every VayuSetu extension that holds rules, then come back; pending rules apply then. Extensions with no rules need no switch.").font(.footnote).foregroundStyle(.secondary)
            }
            VSSection("VayuSetu DNS tunnel") {
                VSRow(title: "State", value: tunnel.localDNSRunning ? "Running" : "Off")
                Button(tunnel.localDNSRunning ? "DNS Only is running" : "Turn On DNS Only") { Task { await store.chooseMode(vpn: false, dns: true) } }.disabled(store.endpoint.isEmpty || tunnel.running || tunnel.busy || store.protectionBusy)
                Text("DNS Only runs in VayuSetu’s own local tunnel. iOS asks once for permission to add a VPN configuration; no VPN server and no DNS profile are involved, and only DNS questions enter the tunnel. Disconnect any VPN first.").font(.footnote).foregroundStyle(.secondary)
                if dns.hasSavedConfiguration { VSRow(title: "Older iOS DNS profile", value: dns.snapshot().label); Text("An earlier version saved an iOS DNS profile. It is not used any more; remove it on the DNS screen.").font(.footnote).foregroundStyle(.secondary) }
            }
            #if os(iOS)
            VSSection("QR camera") {
                VSRow(title: "Camera authorization", value: cameraStatus)
                VSNavLink { VSProfilesScreen(store: store, tunnel: tunnel) } label: { Text("QR Setup in Profiles") }
                Text("Scan QR Code opens the camera directly. The system requests permission only when needed. Images are not stored or uploaded.").font(.footnote).foregroundStyle(.secondary)
            }
            #endif
            VSSection("Notifications") {
                VSRow(title: "System authorization", value: notificationStatus)
                Button("Request Notification Permission") { tunnel.setNotifications(true); Task { try? await Task.sleep(for: .seconds(1)); await refreshNotifications() } }
                Text("If denied previously, change permission in system notification settings. The OS may not repeat its prompt.").font(.footnote).foregroundStyle(.secondary)
            }
            if !message.isEmpty { VSSection("Settings") { Text(message).font(.footnote) } }
            VSSection { VSNavLink { VSSafariScreen(filtering: filtering) } label: { Text("Safari Rules & Setup") }; VSNavLink { VSExtensionStatusScreen(store: store, tunnel: tunnel) } label: { Text("Extension Status") } }
        }.vsList().vsHeader("Permissions")
        .task { await filtering.refresh(); await dns.refresh(); await refreshNotifications(); refreshCameraAuthorization() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshCameraAuthorization(); Task { await refreshNotifications() } } }
    }
    func refreshCameraAuthorization() {
        #if os(iOS)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraStatus = "Allowed"
        case .notDetermined: cameraStatus = "Not requested"
        case .denied: cameraStatus = "Denied · change in Settings"
        case .restricted: cameraStatus = "Restricted by system policy"
        @unknown default: cameraStatus = "Unknown"
        }
        #endif
    }
    func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: notificationStatus = "Allowed"
        case .provisional: notificationStatus = "Provisional"
        case .denied: notificationStatus = "Denied · change in Settings"
        case .notDetermined: notificationStatus = "Not requested"
        default: notificationStatus = "Other system authorization"
        }
    }
    func openSafariSettings() {
        #if os(iOS)
        if #available(iOS 26.2, *) {
            Task { do { try await SFSafariSettings.openExtensionsSettings(forIdentifiers: filtering.neededIdentifiers) } catch { message = "Open Settings → Apps → Safari → Extensions → VayuSetu. The system could not open this pane automatically." } }
        } else { message = "Open Settings → Safari → Extensions → VayuSetu and enable the content blocker." }
        #else
        SFSafariApplication.showPreferencesForExtension(withIdentifier: filtering.identifier) { error in if error != nil { Task { @MainActor in message = "Open Safari → Settings → Extensions and enable VayuSetu." } } }
        #endif
    }
}

/// Compact read-only evidence expands for long values and large text without shrinking touch targets.
struct VSEvidenceRow: View {
    let title: String
    let value: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).font(.subheadline)
                Spacer(minLength: 8)
                Text(value).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline)
                Text(value).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(minHeight: 26).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)).accessibilityElement(children: .combine)
    }
}
private struct VSRoutingEvidenceScreen: View {
    @ObservedObject var store: AppStore
    @ObservedObject var tunnel: TunnelController
    @ObservedObject var network: NetworkDiagnostics
    var body: some View {
        VSCardList {
            VSSection("DNS configuration") {
                VSEvidenceRow(title: "Requested source", value: tunnel.protocolName == "IKEv2" ? "VPN server-managed" : "VayuSetu DNS")
                VSEvidenceRow(title: "Applied DNS", value: tunnel.appliedDNSDescription)
                Text("Imported WireGuard DNS values remain saved but are replaced by VayuSetu’s encrypted resolver when connecting. Native IKEv2 uses server-provided DNS. Accepted settings do not verify the actual query path.").font(.footnote).foregroundStyle(.secondary)
            }
            VSSection("System evidence") {
                Text(tunnel.configuredPolicySummary).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            VSSection("Independent checks") {
                VSNavLink { VSVerificationScreen(store: store, tunnel: tunnel, network: network) } label: { Text("View Independent Verification") }
                Text("Configuration acceptance is separate from testing IPv4, IPv6, DNS transport and failure isolation.").font(.footnote).foregroundStyle(.secondary)
            }
        }.vsList().vsCompactDetails().vsHeader("Routing & Verification").vsEditor()
    }
}
extension View {
    func vsCompactDetails() -> some View {
        #if os(iOS)
        self.environment(\.defaultMinListRowHeight, 44).listSectionSpacing(.compact).toolbar(.hidden, for: .tabBar)
        #else
        self.environment(\.defaultMinListRowHeight, 44)
        #endif
    }
}
