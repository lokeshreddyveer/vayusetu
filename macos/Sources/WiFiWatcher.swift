import CoreLocation
import CoreWLAN
import Foundation
import SwiftUI
import VayuSetuCore

/// Watches which Wi-Fi network this Mac is on and applies the user's Wi-Fi rules when it changes. macOS only reveals a network's name
/// to an app that may use Location, so the first use asks for that; VayuSetu reads the name and never the place.
@MainActor final class WiFiWatcher: NSObject, ObservableObject, CWEventDelegate, CLLocationManagerDelegate {
    @Published private(set) var ssid: String?
    @Published private(set) var isOpen: Bool?
    @Published private(set) var permission: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastApplied = ""
    /// A question waiting for a yes: a general rule or the built-in open-network prompt matched. Nothing has been changed.
    @Published private(set) var suggestion: WiFiSuggestion?
    /// "Ask me about open Wi-Fi": on unless switched off. Needs the Location permission, like the rules, because only then is the network's name readable.
    var promptOnOpenNetworks: Bool {
        get { UserDefaults.standard.object(forKey: "open-wifi-prompt") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "open-wifi-prompt"); objectWillChange.send() }
    }
    private var dismissedNow: String?
    private static let ignoredKey = "wifi-prompt-ignored"
    var ignoredNetworks: [String] { get { UserDefaults.standard.stringArray(forKey: Self.ignoredKey) ?? [] } set { UserDefaults.standard.set(Array(newValue.prefix(100)), forKey: Self.ignoredKey) } }
    @Published var rules: NetworkRuleSet { didSet { save() } }
    /// Called when a rule says to change the protection. The app decides how (it owns the confirmations).
    var apply: ((NetworkRulePlanner.Decision) -> Void)?
    /// What is on now, supplied by the app so a rule that is already satisfied does nothing.
    var current: (() -> NetworkAction)?
    private let client = CWWiFiClient.shared()
    private let location = CLLocationManager()
    private var lastChange = Date.distantPast
    private static let key = "wifi-rules"

    override init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode(NetworkRuleSet.self, from: data) { rules = saved } else { rules = NetworkRuleSet() }
        super.init()
        location.delegate = self
        permission = location.authorizationStatus
    }
    private func save() { if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: Self.key) } }

    var permitted: Bool { permission == .authorizedAlways }
    func start() {
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        read()
    }
    func stop() { try? client.stopMonitoringAllEvents() }
    func requestPermission() { location.requestWhenInUseAuthorization() }

    /// Reads the current network. The name is nil when there is no permission or no Wi-Fi.
    func read() {
        let interface = client.interface()
        let name = interface?.ssid()
        let open = interface.map { $0.security() == .none }
        let changed = name != ssid
        ssid = name; isOpen = name == nil ? nil : open
        if changed { suggestion = nil; dismissedNow = nil; evaluate() }
    }
    /// Applies a matching rule. A network change is the only trigger, and rules fire at most once every few seconds, so two events for one
    /// change (or a network that keeps reconnecting) cannot loop.
    func evaluate(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastChange) > 5 else { return }
        if rules.enabled, let decision = NetworkRulePlanner.decide(ssid: ssid, open: isOpen, rules: rules, current: current?()) {
            lastChange = Date()
            // Only a rule written for this exact network acts by itself. A general rule is a question, and so is the built-in open-network prompt.
            if decision.automatic { lastApplied = decision.reason; apply?(decision) }
            else { offer(WiFiSuggestion(ssid: ssid ?? "", action: decision.action, message: decision.reason + " Switch now?")) }
            return
        }
        if let s = OpenNetworkPrompt.suggestion(ssid: ssid, open: isOpen, current: current?(), enabled: promptOnOpenNetworks, ignored: ignoredNetworks, dismissedNow: dismissedNow) {
            lastChange = Date(); offer(WiFiSuggestion(ssid: s.ssid, action: s.action, message: s.message))
        }
    }
    private func offer(_ new: WiFiSuggestion) {
        guard suggestion != new else { return }
        suggestion = new
        AlertNotifier.post(id: "wifi-suggestion", title: "Unprotected Wi-Fi", body: new.message)
    }
    func acceptSuggestion() {
        guard let s = suggestion else { return }
        suggestion = nil; lastApplied = "You accepted: \(s.action.title) on “\(s.ssid)”."
        apply?(NetworkRulePlanner.Decision(action: s.action, reason: lastApplied, automatic: false))
    }
    func dismissSuggestion(forever: Bool = false) {
        guard let s = suggestion else { return }
        suggestion = nil; dismissedNow = s.ssid
        if forever { ignoredNetworks = ignoredNetworks + [s.ssid] }
    }

    // MARK: Rules
    func addRule(ssid: String, action: NetworkAction) {
        rules.rules = NetworkRulePlanner.normalized(rules.rules + [WiFiRule(ssid: ssid, action: action)])
    }
    func removeRule(_ id: UUID) { rules.rules.removeAll { $0.id == id } }
    func setAction(_ id: UUID, _ action: NetworkAction) { rules.rules = rules.rules.map { var r = $0; if r.id == id { r.action = action }; return r } }

    // MARK: Delegates
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) { Task { @MainActor in self.read() } }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.permission = manager.authorizationStatus; self.read() }
    }
}

/// The Wi-Fi rules panel (Settings).
struct MacWiFiRules: View {
    @ObservedObject var watcher: WiFiWatcher
    @State private var newName = ""
    @State private var newAction = NetworkAction.vpnWithDNS

    var body: some View {
        MacPanel("Wi-Fi rules", icon: "wifi", trailing: { MacChip(text: watcher.rules.enabled ? "On" : "Off", tint: watcher.rules.enabled ? .green : .secondary) }) {
            VStack(alignment: .leading, spacing: 12) {
                MacRow(icon: "bolt.horizontal", title: "Change protection by network", detail: "When this Mac joins a network named below, VayuSetu switches to the protection you chose for it. It only acts when the network changes, so you can still change things by hand afterwards.") {
                    Toggle("", isOn: $watcher.rules.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Wi-Fi rules")
                }
                Divider()
                MacRow(icon: "wifi.exclamationmark", title: "Ask me about open Wi-Fi", detail: "When this Mac joins a network with no password and nothing is protecting it, Home asks whether to turn protection on. It only asks; nothing is switched on without a yes. Needs the Location permission to read the network's name.") {
                    Toggle("", isOn: Binding(get: { watcher.promptOnOpenNetworks }, set: { watcher.promptOnOpenNetworks = $0 })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Ask me about open Wi-Fi")
                }
                if watcher.rules.enabled { details }
            }
        }
    }

    @ViewBuilder private var details: some View {
        Divider()
        if !watcher.permitted {
            VStack(alignment: .leading, spacing: 6) {
                Label(watcher.permission == .denied || watcher.permission == .restricted ? "macOS is not letting VayuSetu read the network name." : "VayuSetu needs permission to read the Wi-Fi network name.", systemImage: "location.slash").font(.system(size: 12)).foregroundStyle(.orange)
                Text("macOS ties the network's name to Location. VayuSetu reads only the name, never where you are. Rules cannot work without it.").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    if watcher.permission == .notDetermined { Button("Allow…") { watcher.requestPermission() }.buttonStyle(MacHoverButtonStyle(prominent: true)) }
                    else { Button("Open Location settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }.buttonStyle(MacHoverButtonStyle()) }
                }
            }
        } else {
            Text(watcher.ssid.map { "Now on “\($0)”\(watcher.isOpen == true ? " (open network)" : "")" } ?? "Not on Wi-Fi").font(.system(size: 12, weight: .medium))
            if !watcher.lastApplied.isEmpty { Text("Last rule applied: " + watcher.lastApplied).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        ForEach(watcher.rules.rules) { rule in
            MacRow(icon: "wifi", title: rule.ssid, detail: "") {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { rule.action }, set: { watcher.setAction(rule.id, $0) })) { ForEach(NetworkAction.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 130)
                    Button(role: .destructive) { watcher.removeRule(rule.id) } label: { Image(systemName: "trash") }.buttonStyle(MacHoverButtonStyle()).help("Remove this rule")
                }
            }
        }
        MacWrap {
            TextField("Network name", text: $newName).textFieldStyle(.roundedBorder).frame(minWidth: 200)
            if let current = watcher.ssid { Button("Use “\(current)”") { newName = current }.buttonStyle(MacHoverButtonStyle()).fixedSize() }
            Picker("", selection: $newAction) { ForEach(NetworkAction.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 130)
            Button("Add") { watcher.addRule(ssid: newName, action: newAction); newName = "" }.buttonStyle(MacHoverButtonStyle(prominent: true))
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || watcher.rules.rules.count >= NetworkRuleSet.maximumRules)
        }
        Divider()
        MacRow(icon: "lock.open", title: "Open networks (no password)", detail: "Public Wi-Fi is where a VPN matters most. A rule for a named network still comes first.") {
            optional(Binding(get: { watcher.rules.openNetworks }, set: { watcher.rules.openNetworks = $0 }))
        }
        MacRow(icon: "questionmark.circle", title: "Any other network", detail: "Used when no rule above matches. \"Leave as is\" changes nothing.") {
            optional(Binding(get: { watcher.rules.otherNetworks }, set: { watcher.rules.otherNetworks = $0 }))
        }
    }
    private func optional(_ binding: Binding<NetworkAction?>) -> some View {
        Picker("", selection: binding) {
            Text("Leave as is").tag(NetworkAction?.none)
            ForEach(NetworkAction.allCases) { Text($0.title).tag(NetworkAction?.some($0)) }
        }.labelsHidden().frame(width: 150)
    }
}

struct WiFiSuggestion: Equatable {
    let ssid: String
    let action: NetworkAction
    let message: String
}

/// The question on Home. Nothing has been switched on; the buttons are the answer.
struct MacWiFiSuggestionCard: View {
    @ObservedObject var watcher: WiFiWatcher
    @ObservedObject var store: AppStore
    var body: some View {
        // A question that has been answered some other way (the person turned protection on themselves) is not shown any more.
        let now = NetworkRulePlanner.current(vpn: store.vpnPill != .off, dns: store.dnsPill != .off)
        if let s = watcher.suggestion, s.action != now {
            MacPanel("Unprotected Wi-Fi", icon: "wifi.exclamationmark") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Turn on \(s.action.title)") { withAnimation(.easeInOut(duration: 0.2)) { watcher.acceptSuggestion() } }.buttonStyle(MacHoverButtonStyle(prominent: true))
                        Button("Not now") { withAnimation(.easeInOut(duration: 0.2)) { watcher.dismissSuggestion() } }.buttonStyle(MacHoverButtonStyle())
                        Button("Don’t ask for this network") { withAnimation(.easeInOut(duration: 0.2)) { watcher.dismissSuggestion(forever: true) } }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }.transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
private struct WiFiWatcherKey: EnvironmentKey { static let defaultValue: WiFiWatcher? = nil }
extension EnvironmentValues { var wifiWatcher: WiFiWatcher? { get { self[WiFiWatcherKey.self] } set { self[WiFiWatcherKey.self] = newValue } } }
