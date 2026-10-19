import VayuSetuCore
import Foundation
import Combine
import NetworkExtension
import Network
import OSLog
import UserNotifications
#if os(macOS)
import AppKit
#endif

@MainActor final class TunnelController: ObservableObject {
    @Published var stage: ConnectionStage = .disconnected
    @Published var evidence: [Evidence] = []
    @Published var history: [SessionRecord] = []
    @Published var checkingHealth = false
    private var statsRecordedAt: Date?
    @Published var autoReconnect = true
    @Published var notificationsEnabled = false
    private var notificationPermissionRequestID = UUID()
    @Published var usageBudgetMB = 0 { didSet { UserDefaults.standard.set(usageBudgetMB, forKey: "usage-budget-mb") } }
    private var usageAlerted = false
    @Published var allowLAN = false
    /// The backup encrypted resolver for the next connection, set by the store; nil means none.
    var fallbackDNS: (endpoint: String, bootstrap: [String])?
    @Published var retryAttempt = 0
    private let logger = Logger(subsystem: "app.vayusetu.ios.preview", category: "connection")
    private let pathMonitor = NWPathMonitor()
    private var wantedConnection = false
    private var retryTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?
    private var lifecycleID = UUID()
    private var sessionID: UUID?
    private var sessionStart: Date?
    private var sessionStartedAt: ContinuousClock.Instant?
    private var sessionElapsedOffset: Int64 = 0
    @Published var retryLimit = 3 { didSet { UserDefaults.standard.set(retryLimit, forKey: "retry-limit") } }
    @Published var connectionTimeout = 30 { didSet { UserDefaults.standard.set(connectionTimeout, forKey: "connection-timeout") } }
    private var retryPolicy: RetryPolicy { RetryPolicy(maximumAttempts: retryLimit) }
    private var pathAvailable = true
    private var pathSignature = ""
    @Published var statusObservedAt: Date?
    @Published var status: NEVPNStatus = .invalid
    @Published var busy = false
    @Published var ready = false
    @Published var message = ""
    @Published var stats: TunnelStats?
    @Published var configuredProfile: UUID?
    @Published var activeMode: RoutingMode?
    @Published var events: [String] = []
    @Published var structuredEvents: [ConnectionEvent] = []
    @Published var trafficPoints: [TrafficPoint] = []
    private var logWritable = true
    @Published private(set) var rateSampleAvailable = false
    /// Seconds since the tunnel last reported statistics, or nil when it has not.
    var statsAge: TimeInterval? { statsRecordedAt.map { Date().timeIntervalSince($0) } }
    var uptimeSeconds: Double? { sessionStartedAt.map { Double($0.duration(to: .now).components.seconds) } }
    var ratesAvailable: Bool { rateSampleAvailable && status == .connected && statsRecordedAt.map { Date().timeIntervalSince($0) < 10 } == true }
    @Published var receivedPerSecond: Double = 0
    @Published var sentPerSecond: Double = 0
    private var lastSample: (ContinuousClock.Instant, TunnelStats)?
    private var statusRevision: UInt64 = 0
    private var statsPending = false
    private var manager: NEVPNManager?
    @Published private(set) var protocolName = "WireGuard"
    private var observer: NSObjectProtocol?
    #if os(macOS)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var savedPreferencesSanitized = false
    #endif
    static var available: Bool {
        #if VPN_ENABLED
        #if os(macOS)
        // Unsigned host builds must not attempt activation or mutate VPN preferences.
        return EmbeddedMacProfile.present(in: Bundle.main.bundleURL)
        #else
        return true
        #endif
        #else
        return false
        #endif
    }
    var running: Bool { [.connected, .connecting, .reasserting, .disconnecting].contains(status) }
    var statusText: String {
        guard Self.available else { return "Preview build" }
        return stage.title
    }

    private var providerID: String { (Bundle.main.bundleIdentifier ?? "app.vayusetu.ios") + ".tunnel" }
    init() {
        restoreHistory()
        usageBudgetMB = max(0, min(100_000, UserDefaults.standard.integer(forKey: "usage-budget-mb")))
        retryLimit = max(1, min(10, UserDefaults.standard.object(forKey: "retry-limit") as? Int ?? 3))
        connectionTimeout = max(10, min(120, UserDefaults.standard.object(forKey: "connection-timeout") as? Int ?? 30))
        let logURL = LocalFiles.url("connection-events.json")
        if FileManager.default.fileExists(atPath: logURL.path) {
            do {
                structuredEvents = Array(try JSONDecoder().decode([ConnectionEvent].self, from: LocalFiles.read(logURL, maximum: 256_000)).prefix(500))
                events = Array(structuredEvents.prefix(100).map(\.display))
            } catch { logWritable = false; message = "Stored logs could not be read; the original file has been preserved." }
        }
        notificationsEnabled = UserDefaults.standard.bool(forKey: "connection-notifications")
        autoReconnect = UserDefaults.standard.object(forKey: "auto-reconnect") as? Bool ?? true
        allowLAN = UserDefaults.standard.bool(forKey: "allow-lan")
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let signature = "\(available)-\(path.usesInterfaceType(.wifi))-\(path.usesInterfaceType(.cellular))-\(path.usesInterfaceType(.wiredEthernet))-\(path.supportsIPv4)-\(path.supportsIPv6)"
            Task { @MainActor in
                guard let self else { return }
                // The first callback only establishes the baseline; it is not a network change.
                let changed = !self.pathSignature.isEmpty && self.pathSignature != signature; self.pathSignature = signature
                let wasAvailable = self.pathAvailable; self.pathAvailable = available
                if changed {
                    self.evidence = []; self.healthTask?.cancel(); self.checkingHealth = false
                    if self.status == .connected { self.stage = .tunnelEstablished }
                    if !available && self.wantedConnection { self.stage = .suspended }
                    else if available && self.wantedConnection && self.status == .disconnected { self.scheduleRetry() }
                    // Wi-Fi/cellular flaps change the path without losing the network; say what happened, and do not repeat it within 30 s.
                    let text = available == wasAvailable ? "Network path changed; verification reset" : available ? "Network availability restored; verification reset" : "Network unavailable; verification reset"
                    if !(self.structuredEvents.first.map { $0.message == text && Date().timeIntervalSince($0.timestamp) < 30 } ?? false) { self.record(text) }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "VayuSetu.ConnectionPath"))
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        #if os(macOS)
        let notifications = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.healthTask?.cancel(); self.checkingHealth = false; self.evidence = []
                    if self.wantedConnection { self.stage = .suspended }
                    self.record("System sleep; verification invalidated")
                }
            },
            notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.evidence = []; self.refreshStatus()
                    if self.wantedConnection && self.status == .disconnected { self.scheduleRetry() }
                    self.record("System wake; connection requires verification")
                }
            }
        ]
        #endif
        Task { await load() }
    }
    deinit {
        #if os(macOS)
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        #endif
        pathMonitor.cancel(); retryTask?.cancel(); watchdog?.cancel(); healthTask?.cancel(); sampleTask?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    func record(_ text: String, severity: ConnectionEvent.Severity = .info, category: String = "connection") {
        // Callers supply fixed, sanitized messages; raw errors and configuration text never enter this store.
        let event = ConnectionEvent(id: UUID(), timestamp: Date(), session: sessionID, severity: severity, category: category, message: text)
        structuredEvents.insert(event, at: 0); structuredEvents = Array(structuredEvents.prefix(500))
        events = Array(structuredEvents.prefix(100).map(\.display))
        if logWritable {
            do { try LocalFiles.write(JSONEncoder().encode(structuredEvents), to: LocalFiles.url("connection-events.json")) }
            catch { logWritable = false; message = "Local log storage is unavailable. Events remain in memory." }
        }
        switch severity {
        case .info: logger.info("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
    }
    func clearLogs() {
        do {
            let url = LocalFiles.url("connection-events.json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            events = []; structuredEvents = []; logWritable = true
        } catch { message = "Could not remove saved connection logs." }
    }
    var logReport: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(structuredEvents)).flatMap { String(data: $0, encoding: .utf8) } ?? "Report unavailable."
    }
    func load() async {
        defer { ready = true }
        guard Self.available else { return }
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            #if os(macOS)
            // Remove secrets written by older builds before an unattended restart can reuse them.
            for owned in all where (owned.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID {
                guard let saved = owned.protocolConfiguration as? NETunnelProviderProtocol else { continue }
                var configuration = saved.providerConfiguration ?? [:]
                let legacyValue = configuration.removeValue(forKey: "secret")
                let hadSecret = legacyValue != nil
                if hadSecret || owned.isOnDemandEnabled {
                    if let legacySecret = legacyValue as? String, try Vault.get("active-tunnel") == nil {
                        guard let data = Data(base64Encoded: legacySecret), data.count <= 128_000,
                              (try? JSONDecoder().decode(TunnelSecret.self, from: data)) != nil else {
                            throw AppIssue(message: "Saved VPN credentials could not be migrated.")
                        }
                        try Vault.put(data, account: "active-tunnel")
                    }
                    saved.providerConfiguration = configuration
                    owned.protocolConfiguration = saved
                    owned.isOnDemandEnabled = false
                    owned.onDemandRules = []
                    try await owned.saveToPreferences()
                    try await owned.loadFromPreferences()
                    guard (owned.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["secret"] == nil,
                          !owned.isOnDemandEnabled else { throw AppIssue(message: "Saved VPN credentials could not be removed.") }
                }
            }
            savedPreferencesSanitized = true
            #endif
            let wireguard = all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }
            let native = NEVPNManager.shared()
            try? await native.loadFromPreferences()
            let ownedNative = native.localizedDescription?.hasPrefix("VayuSetu IKEv2 · ") == true && native.protocolConfiguration is NEVPNProtocolIKEv2
            let nativeRunning = [.connected, .connecting, .reasserting, .disconnecting].contains(native.connection.status)
            let wireguardRunning = wireguard.map { [.connected, .connecting, .reasserting, .disconnecting].contains($0.connection.status) } ?? false
            manager = ownedNative && nativeRunning ? native : wireguardRunning ? wireguard : ownedNative && UserDefaults.standard.string(forKey: "last-vpn-adapter") == "IKEv2" ? native : wireguard
            protocolName = manager?.protocolConfiguration is NEVPNProtocolIKEv2 ? "IKEv2" : "WireGuard"
            if protocolName == "IKEv2" {
                configuredProfile = native.localizedDescription?.components(separatedBy: " · ").last.flatMap(UUID.init(uuidString:))
                activeMode = nil
            }
            if let config = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration {
                configuredProfile = (config["profileID"] as? String).flatMap(UUID.init(uuidString:))
                activeMode = (config["mode"] as? String).flatMap(RoutingMode.init(rawValue:))
                if config["runtime"] as? String == "dnsOnly" { protocolName = "Local DNS" }
            }
            if activeMode == .dnsFirst, let manager {
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
                manager.connection.stopVPNTunnel()
                message = RoutingMode.directDNSUnavailable
                record("Unsupported saved direct-DNS configuration disabled")
            }
            refreshStatus()
        } catch { message = "Could not load VPN preferences. Check Network Extension signing and try again." }
    }
    func refreshStatus() {
        if Self.available { statusObservedAt = Date() }
        let previous = status
        let finalCounters = stats ?? lastSample?.1
        let next = manager?.connection.status ?? .invalid
        if next == .disconnected, [.connecting, .connected, .reasserting].contains(previous) {
            manager?.connection.fetchLastDisconnectError { [weak self] error in
                guard let error else { return }
                TunnelStartupEvent.record(.systemDisconnect, error: error)
                let code = (error as NSError).code
                let domain = TunnelStartupEvent.sanitizedDomain((error as NSError).domain)
                Task { @MainActor in
                    self?.message = "The tunnel stopped (system error \(code)). Check the server profile, resolver, and extension signing, then reconnect."
                    self?.record("System VPN disconnect · " + domain + ":" + String(code), severity: .error)
                }
            }
        }
        if next != status { statusRevision &+= 1; status = next; lastSample = nil; rateSampleAvailable = false; receivedPerSecond = 0; sentPerSecond = 0 }
        if status != .connected { stats = nil; healthTask?.cancel(); checkingHealth = false; evidence = [] }
        if next != previous {
            switch next {
            case .connected:
                stage = .tunnelEstablished; retryAttempt = 0; watchdog?.cancel(); trafficPoints = []; usageAlerted = false
                if sessionID == nil { sessionID = UUID(); sessionStart = manager?.connection.connectedDate ?? Date(); sessionElapsedOffset = Int64(max(0, Date().timeIntervalSince(sessionStart!))); sessionStartedAt = .now }
                startSampling()
                if lookupsOn { Task { try? await Task.sleep(for: .seconds(2)); self.pushLookupSetting() } }
                #if os(macOS)
                reloadDNSRules()   // the root tunnel cannot read this user's App Group file, so hand it the rules
                Task { try? await Task.sleep(for: .seconds(3)); self.reloadDNSRules() }   // once more: the tunnel may not have been ready for the first message
                #endif
            case .connecting: stage = .connecting
            case .reasserting: stage = .reconnecting
            case .disconnecting: stage = .disconnecting
            case .disconnected, .invalid:
                finishSession(totals: finalCounters); sampleTask?.cancel()
                stage = .disconnected
                if wantedConnection { scheduleRetry() }
            default: break
            }
            // The first read after launch is the baseline, not a transition worth logging.
            if !(previous == .invalid && next == .disconnected) { record(statusText) }
            if next == .connected || next == .disconnected { notifyStatusChange() }
        }
    }
    func setNotifications(_ enabled: Bool) {
        let requestID = UUID()
        notificationPermissionRequestID = requestID
        if !enabled {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: "connection-notifications")
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ["connection-status"])
            center.removeDeliveredNotifications(withIdentifiers: ["connection-status"])
            return
        }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                // Disabling notifications while the OS prompt is open must win
                // over its delayed completion.
                guard notificationPermissionRequestID == requestID else { return }
                notificationsEnabled = granted
                UserDefaults.standard.set(notificationsEnabled, forKey: "connection-notifications")
                if !notificationsEnabled { message = "Connection notifications are disabled. Allow them in system notification settings." }
            } catch {
                guard notificationPermissionRequestID == requestID else { return }
                notificationsEnabled = false
                message = "Could not enable notifications. Check system notification settings."
            }
        }
    }
    private func notifyStatusChange() {
        guard notificationsEnabled else { return }
        // refreshStatus invokes this only on a state change. Throttling opposite
        // states leaves a stale disconnection warning after a successful reconnect.
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["connection-status"])
        center.removeDeliveredNotifications(withIdentifiers: ["connection-status"])
        let content = UNMutableNotificationContent()
        content.title = "VayuSetu"
        content.body = status == .connected ? "VPN tunnel established. Routing and DNS protection still need verification." : "VPN disconnected. Check the connection before continuing."
        let request = UNNotificationRequest(identifier: "connection-status", content: content, trigger: nil)
        center.add(request) { _ in }
    }
    func connect(profile: SavedProfile, configuration: Data, resolver: String, mode: RoutingMode, onDemand: Bool, strictRouting: Bool, requireNativeIPv6: Bool = false, bootstrapAddresses: [String] = [], filtering: Bool = false, dnsUpstreamDirect: Bool = false, applyResolver: Bool = true) async {
        #if os(macOS)
        guard savedPreferencesSanitized else { message = "Saved VPN preferences could not be secured. Reopen VayuSetu after unlocking this Mac."; return }
        #endif
        guard ready, !busy, !running else { return }
        guard mode.supported else { stage = .blocked; message = RoutingMode.directDNSUnavailable; return }
        guard Self.available else { message = "Use the VayuSetuVPN scheme with a developer team that supports Network Extensions. This preview build cannot create a VPN."; return }
        if requireNativeIPv6 {
            guard profile.fullTunnel, profile.addresses.contains(where: { ProfileParser.ipFamily(String($0.split(separator: "/")[0])) == 6 }) else { stage = .blocked; message = "This policy requires a native IPv6 interface and full IPv6 default route. Choose a dual-stack profile."; return }
        }
        busy = true; defer { busy = false }
        stage = .validating; lifecycleID = UUID(); evidence = []
        retryTask?.cancel(); retryTask = nil; watchdog?.cancel(); wantedConnection = true; retryAttempt = 0
        var oldSecret: Data?
        var secretRead = false
        var setupStep = "load-wireguard-preferences"
        let operationID = lifecycleID
        let mgr: NETunnelProviderManager
        do {
            let owned = try await NETunnelProviderManager.loadAllFromPreferences().filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }
            mgr = owned.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["profileID"] as? String == profile.id.uuidString }) ?? owned.first ?? NETunnelProviderManager()
        } catch { wantedConnection = false; stage = .failed; message = "Could not load the saved WireGuard configuration. Retry after unlocking the device."; return }
        let oldProtocol = mgr.protocolConfiguration?.copy() as? NEVPNProtocol
        let oldRules = mgr.onDemandRules; let oldOnDemand = mgr.isOnDemandEnabled; let oldEnabled = mgr.isEnabled
        do {
            oldSecret = try Vault.get("active-tunnel"); secretRead = true
            setupStep = "load-native-preferences"
            let native = NEVPNManager.shared(); try await native.loadFromPreferences()
            if native.localizedDescription?.hasPrefix("VayuSetu IKEv2 · ") == true {
                guard ![NEVPNStatus.connected, .connecting, .reasserting, .disconnecting].contains(native.connection.status) else { throw AppIssue(message: "The native VPN is still active. Disconnect it first.") }
                if native.isOnDemandEnabled || native.isEnabled {
                    setupStep = "disable-native-adapter"
                    native.isOnDemandEnabled = false; native.isEnabled = false
                    try await native.saveToPreferences()
                    try await native.loadFromPreferences()
                    guard !native.isOnDemandEnabled, !native.isEnabled else {
                        throw AppIssue(message: "The previous IKEv2 adapter could not be disabled. WireGuard was not started.")
                    }
                }
            }
            guard mode.supported else { throw AppIssue(message: RoutingMode.directDNSUnavailable) }
            guard let text = String(data: configuration, encoding: .utf8) else { throw AppIssue(message: "Invalid profile encoding.") }
            try ProfileParser.validateTunnel(ProfileParser.parse(text)); if applyResolver { _ = try DNSService.endpoint(resolver) }
            let secret = try JSONEncoder().encode(TunnelSecret(wireguard: text, resolver: resolver, mode: mode, requireNativeIPv6: requireNativeIPv6, resolverBootstrapAddresses: bootstrapAddresses.isEmpty ? nil : try ResolverBootstrap.validated(bootstrapAddresses), requireStrictRouting: strictRouting, filtering: filtering ? true : nil, dnsUpstreamDirect: dnsUpstreamDirect ? true : nil, applyResolver: applyResolver ? nil : false, fallbackResolver: fallbackDNS?.endpoint, fallbackBootstrapAddresses: (fallbackDNS?.bootstrap.isEmpty ?? true) ? nil : fallbackDNS?.bootstrap))
            stage = .preparing
            if mgr.isOnDemandEnabled {
                mgr.isOnDemandEnabled = false
                try await mgr.saveToPreferences()
                guard ![NEVPNStatus.connected, .connecting, .reasserting, .disconnecting].contains(mgr.connection.status) else { throw AppIssue(message: "Disconnect before changing the active configuration.") }
            }
            guard lifecycleID == operationID, wantedConnection else { throw CancellationError() }
            try Vault.put(secret, account: "active-tunnel")
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerID; proto.serverAddress = profile.endpoints.first ?? "WireGuard"
            proto.passwordReference = try Vault.reference("active-tunnel")
            proto.providerConfiguration = ["profileID": profile.id.uuidString, "mode": mode.rawValue]
            proto.disconnectOnSleep = false
            // Strict routing requests iOS capture during tunnel reassertion; documented OS exceptions remain.
            proto.includeAllNetworks = mode == .vpnFirst && strictRouting
            RoutingSecurityPolicy.apply(to: proto, strict: strictRouting, allowLAN: allowLAN)
            UserDefaults.standard.set(allowLAN, forKey: "allow-lan")
            UserDefaults.standard.set(autoReconnect, forKey: "auto-reconnect")
            mgr.protocolConfiguration = proto; mgr.localizedDescription = "VayuSetu · \(profile.name)"
            #if os(macOS)
            let effectiveOnDemand = false // On-demand starts have no in-memory secret.
            mgr.isEnabled = true; mgr.isOnDemandEnabled = false; mgr.onDemandRules = []
            #else
            let effectiveOnDemand = onDemand || strictRouting
            mgr.isEnabled = true; mgr.isOnDemandEnabled = effectiveOnDemand
            if effectiveOnDemand { mgr.onDemandRules = TrustedNetworks.rules(strict: strictRouting) }
            else { mgr.onDemandRules = [] }
            #endif
            setupStep = "save-wireguard-preferences"
            try await mgr.saveToPreferences()
            setupStep = "read-back-wireguard-preferences"
            try await mgr.loadFromPreferences()
            guard lifecycleID == operationID, wantedConnection else { throw CancellationError() }
            guard let saved = mgr.protocolConfiguration as? NETunnelProviderProtocol,
                  saved.includeAllNetworks == (mode == .vpnFirst && strictRouting),
                  RoutingSecurityPolicy.matches(saved, strict: strictRouting, allowLAN: allowLAN),
                  mgr.isEnabled, mgr.isOnDemandEnabled == effectiveOnDemand,
                  RoutingSecurityPolicy.matchesOnDemand(mgr.onDemandRules, enabled: effectiveOnDemand, trusted: TrustedNetworks.active(strict: strictRouting)) else {
                throw AppIssue(message: "Saved routing policy differs from the requested policy.")
            }
            manager = mgr; configuredProfile = profile.id; activeMode = mode; protocolName = "WireGuard"; UserDefaults.standard.set("WireGuard", forKey: "last-vpn-adapter")
            setupStep = "start-wireguard-tunnel"
            try await startRegisteredTunnel(mgr, operation: operationID, secret: secret) {
                guard let saved = mgr.protocolConfiguration as? NETunnelProviderProtocol else { return false }
                return saved.providerBundleIdentifier == self.providerID && saved.passwordReference == proto.passwordReference &&
                    saved.providerConfiguration?["profileID"] as? String == profile.id.uuidString &&
                    saved.providerConfiguration?["secret"] == nil &&
                    saved.includeAllNetworks == proto.includeAllNetworks &&
                    RoutingSecurityPolicy.matches(saved, strict: strictRouting, allowLAN: self.allowLAN) &&
                    mgr.isOnDemandEnabled == effectiveOnDemand &&
                    RoutingSecurityPolicy.matchesOnDemand(mgr.onDemandRules, enabled: effectiveOnDemand, trusted: TrustedNetworks.active(strict: strictRouting))
            }
            record("Connection requested · \(mode.title)")
            refreshStatus(); armWatchdog(); message = ""
        } catch {
            let ns = error as NSError
            let failure = (error as? AppIssue)?.message ?? TunnelStartupEvent.sanitizedDomain(ns.domain) + ":" + String(ns.code)
            record("WireGuard setup failed at " + setupStep + " · " + failure, severity: .error)
            wantedConnection = false; stage = .failed
            guard secretRead else { message = "Could not access active credentials. Unlock the device and retry."; return }
            mgr.protocolConfiguration = oldProtocol; mgr.onDemandRules = oldRules
            mgr.isOnDemandEnabled = oldOnDemand; mgr.isEnabled = oldEnabled
            do {
                if let oldSecret { try Vault.put(oldSecret, account: "active-tunnel") } else { try Vault.delete("active-tunnel") }
                if oldProtocol != nil { try await mgr.saveToPreferences() }
                else { try await mgr.removeFromPreferences() }
                record("Connection setup failed; previous configuration restored", severity: .error)
            } catch { let ns = error as NSError; record("Configuration rollback failed · " + TunnelStartupEvent.sanitizedDomain(ns.domain) + ":" + String(ns.code), severity: .error); message = "Rollback failed. Remove the saved VPN configuration in system VPN settings before retrying."; return }
            message = "VPN setup failed. Check provisioning, the VPN permission prompt, profile and resolver."
        }
    }
    var localDNSRunning: Bool { running && protocolName == "Local DNS" }

    // MARK: Recent lookups (local DNS tunnel only; kept in the tunnel's memory, never saved)
    @Published private(set) var lookups: [DNSQueryEntry] = []
    @Published private(set) var lookupsOn = UserDefaults.standard.bool(forKey: "dns-lookups-on")
    private var lookupTask: Task<Void, Never>?
    var lookupsAvailable: Bool { localDNSRunning && status == .connected }
    func setLookups(_ on: Bool) {
        lookupsOn = on; UserDefaults.standard.set(on, forKey: "dns-lookups-on")
        if !on { lookups = [] }
        pushLookupSetting()
    }
    /// Tells the tunnel whether to keep the list, and starts or stops asking for it.
    func pushLookupSetting() {
        lookupTask?.cancel(); lookupTask = nil
        guard lookupsAvailable, let session = manager?.connection as? NETunnelProviderSession else { return }
        try? session.sendProviderMessage(TunnelDiagnosticRequest.lookups(on: lookupsOn)) { _ in }
        guard lookupsOn else { return }
        lookupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.fetchLookups()
            }
        }
    }
    private func fetchLookups() async {
        guard lookupsAvailable, let session = manager?.connection as? NETunnelProviderSession else { return }
        let after = lookups.last?.id ?? 0
        let data: Data? = await withCheckedContinuation { continuation in
            do { try session.sendProviderMessage(TunnelDiagnosticRequest.lookupsAfter(after)) { continuation.resume(returning: $0) } } catch { continuation.resume(returning: nil) }
        }
        guard let data, let new = try? JSONDecoder().decode([DNSQueryEntry].self, from: data), !new.isEmpty else { return }
        lookups = Array((lookups + new).suffix(400))
    }
    /// ADR-011 spike: starts the local DNS-only tunnel. No WireGuard profile or remote server is involved,
    /// and only the virtual DNS address is routed into the tunnel. "Tunnel established" is not DNS evidence:
    /// the extension's query counters are the observation.
    /// Tells a running local DNS tunnel to reload the compiled filter snapshot.
    func reloadDNSRules() {
        // Any packet tunnel that hosts the filter (local DNS tunnel or WireGuard) reloads; others ignore the message.
        guard running, protocolName != "IKEv2", status == .connected, let session = manager?.connection as? NETunnelProviderSession else { return }
        #if os(macOS)
        // A root system extension has its own App Group container, so the snapshot travels in the message.
        try? session.sendProviderMessage(TunnelDiagnosticRequest.rulesMessage(DNSRuleStore.load())) { _ in }
        #else
        try? session.sendProviderMessage(TunnelDiagnosticRequest.reloadRules) { _ in }
        #endif
    }
    func connectDNSOnly(resolver: String, bootstrapAddresses: [String] = [], filtering: Bool = false) async {
        #if os(macOS)
        guard savedPreferencesSanitized else { message = "Saved VPN preferences could not be secured. Reopen VayuSetu after unlocking this Mac."; return }
        #endif
        guard ready, !busy, !running else { return }
        guard Self.available else { message = "Use the VayuSetuVPN scheme with a developer team that supports Network Extensions. This preview build cannot create a tunnel."; return }
        busy = true; defer { busy = false }
        stage = .validating; lifecycleID = UUID(); evidence = []
        retryTask?.cancel(); retryTask = nil; watchdog?.cancel(); wantedConnection = true; retryAttempt = 0
        let operationID = lifecycleID
        var oldSecret: Data?; var secretRead = false
        var setupStep = "load-preferences"
        let mgr: NETunnelProviderManager
        do {
            let owned = try await NETunnelProviderManager.loadAllFromPreferences().filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }
            mgr = owned.first ?? NETunnelProviderManager()
        } catch { wantedConnection = false; stage = .failed; message = "Could not load the saved tunnel configuration. Retry after unlocking the device."; return }
        let oldProtocol = mgr.protocolConfiguration?.copy() as? NEVPNProtocol
        let oldRules = mgr.onDemandRules; let oldOnDemand = mgr.isOnDemandEnabled; let oldEnabled = mgr.isEnabled
        do {
            oldSecret = try Vault.get("active-tunnel"); secretRead = true
            setupStep = "validate-resolver"
            let url = try DNSService.endpoint(resolver)
            let bootstrap = bootstrapAddresses.isEmpty ? nil : try ResolverBootstrap.validated(bootstrapAddresses)
            let secret = try JSONEncoder().encode(TunnelSecret(wireguard: "", resolver: url.absoluteString, mode: .vpnFirst, resolverBootstrapAddresses: bootstrap, runtime: "dnsOnly", filtering: filtering, fallbackResolver: fallbackDNS?.endpoint, fallbackBootstrapAddresses: (fallbackDNS?.bootstrap.isEmpty ?? true) ? nil : fallbackDNS?.bootstrap))
            let native = NEVPNManager.shared(); try await native.loadFromPreferences()
            guard ![NEVPNStatus.connected, .connecting, .reasserting, .disconnecting].contains(native.connection.status) else { throw AppIssue(message: "Another VPN is active. Disconnect it first; only one tunnel can run.") }
            stage = .preparing
            if mgr.isOnDemandEnabled { mgr.isOnDemandEnabled = false; try await mgr.saveToPreferences() }
            guard [NEVPNStatus.disconnected, .invalid].contains(mgr.connection.status) else { throw AppIssue(message: "Disconnect before changing the active configuration.") }
            guard lifecycleID == operationID, wantedConnection else { throw CancellationError() }
            setupStep = "save-preferences"
            try Vault.put(secret, account: "active-tunnel")
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = providerID; proto.serverAddress = "Local DNS tunnel"
            proto.passwordReference = try Vault.reference("active-tunnel")
            proto.providerConfiguration = ["profileID": "dns-only", "mode": RoutingMode.vpnFirst.rawValue, "runtime": "dnsOnly"]
            proto.disconnectOnSleep = false; proto.includeAllNetworks = false
            mgr.protocolConfiguration = proto; mgr.localizedDescription = "VayuSetu · Local DNS"
            mgr.isEnabled = true; mgr.isOnDemandEnabled = false; mgr.onDemandRules = []
            try await mgr.saveToPreferences()
            try await mgr.loadFromPreferences()
            guard lifecycleID == operationID, wantedConnection, mgr.isEnabled else { throw CancellationError() }
            manager = mgr; configuredProfile = nil; activeMode = .vpnFirst; protocolName = "Local DNS"
            setupStep = "start-tunnel"
            try await startRegisteredTunnel(mgr, operation: operationID, secret: secret) { mgr.isEnabled }
            record("Local DNS tunnel requested")
            refreshStatus(); armWatchdog(); message = ""
        } catch {
            let ns = error as NSError
            let failure = (error as? AppIssue)?.message ?? TunnelStartupEvent.sanitizedDomain(ns.domain) + ":" + String(ns.code)
            record("Local DNS tunnel setup failed at " + setupStep + " · " + failure, severity: .error)
            wantedConnection = false; stage = .failed
            guard secretRead else { message = "Could not access active credentials. Unlock the device and retry."; return }
            mgr.protocolConfiguration = oldProtocol; mgr.onDemandRules = oldRules
            mgr.isOnDemandEnabled = oldOnDemand; mgr.isEnabled = oldEnabled
            do {
                if let oldSecret { try Vault.put(oldSecret, account: "active-tunnel") } else { try Vault.delete("active-tunnel") }
                if oldProtocol != nil { try await mgr.saveToPreferences() } else { try await mgr.removeFromPreferences() }
                record("Local DNS tunnel setup failed; previous configuration restored", severity: .error)
            } catch { record("Configuration rollback failed", severity: .error); message = "Rollback failed. Remove the saved VPN configuration in system VPN settings before retrying."; return }
            message = (error as? AppIssue)?.message ?? "Local DNS tunnel setup failed. Check provisioning, the VPN permission prompt and the resolver."
        }
    }
    func connectIKEv2(_ draft: ManualVPNDraft, strict: Bool, allowLAN: Bool) async {
        guard Self.available, !busy, !running else { message = "Disconnect the current VPN before starting IKEv2."; return }
        busy = true; defer { busy = false }
        let native = NEVPNManager.shared()
        var previous: NEVPNProtocol?
        var previousRules: [NEOnDemandRule]?
        var previousDescription: String?
        let previousManager = manager; let previousProfileID = configuredProfile; let previousName = protocolName; let previousMode = activeMode
        var previousEnabled = false
        var previousOnDemand = false
        let account = "native-ike-password-" + draft.id.uuidString
        var previousSecret: Data?
        var secretChanged = false
        var loaded = false
        var setupStep = "validate-input"
        stage = .validating; lifecycleID = UUID(); let operation = lifecycleID
        do {
            try draft.validate()
            setupStep = "load-native-preferences"
            try await native.loadFromPreferences()
            guard native.protocolConfiguration == nil || native.localizedDescription?.hasPrefix("VayuSetu IKEv2 · ") == true else { throw AppIssue(message: "Another personal VPN configuration is present. It will not be overwritten.") }
            guard ![NEVPNStatus.connected, .connecting, .reasserting, .disconnecting].contains(native.connection.status) else { throw AppIssue(message: "The native VPN is still active. Disconnect it first.") }
            previous = native.protocolConfiguration?.copy() as? NEVPNProtocol; previousRules = native.onDemandRules
            previousEnabled = native.isEnabled; previousOnDemand = native.isOnDemandEnabled; previousDescription = native.localizedDescription; loaded = true
            setupStep = "prepare-keychain-reference"
            previousSecret = try Vault.get(account)
            let reference: Data?
            if draft.authentication == "Username & Password" {
                try Vault.put(Data(draft.password.utf8), account: account); secretChanged = true; reference = try Vault.reference(account)
            } else { reference = nil }
            setupStep = "build-native-policy"
            let proto = try NativeIKEProtocolBuilder.build(draft, passwordReference: reference, strict: strict, allowLAN: allowLAN)
            guard lifecycleID == operation else { throw CancellationError() }
            // Disable only this app's other adapters, preventing competing on-demand reconnects.
            setupStep = "disable-wireguard-on-demand"
            for other in try await NETunnelProviderManager.loadAllFromPreferences() where (other.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID {
                guard [.disconnected, .invalid].contains(other.connection.status) else {
                    throw AppIssue(message: "The WireGuard adapter has not finished stopping. IKEv2 was not started.")
                }
                if other.isOnDemandEnabled || other.isEnabled {
                    other.isOnDemandEnabled = false; other.isEnabled = false
                    try await other.saveToPreferences()
                    try await other.loadFromPreferences()
                    guard !other.isEnabled, !other.isOnDemandEnabled else {
                        throw AppIssue(message: "The previous WireGuard adapter could not be disabled. IKEv2 was not started.")
                    }
                }
            }
            // Enabling one VPN can change another registration in system preferences.
            // Refresh the native registration after the previous adapter's writes.
            try await native.loadFromPreferences()
            stage = .preparing
            native.protocolConfiguration = proto; native.localizedDescription = "VayuSetu IKEv2 · " + draft.id.uuidString
            native.isEnabled = true; native.isOnDemandEnabled = draft.onDemand || strict
            if native.isOnDemandEnabled { native.onDemandRules = TrustedNetworks.rules(strict: strict) } else { native.onDemandRules = [] }
            setupStep = "save-native-preferences"
            try await native.saveToPreferences()
            setupStep = "read-back-native-preferences"
            try await native.loadFromPreferences()
            setupStep = "verify-native-policy"
            guard lifecycleID == operation, let saved = native.protocolConfiguration as? NEVPNProtocolIKEv2,
                  saved.serverAddress == draft.server, saved.remoteIdentifier == draft.remoteIdentifier,
                  saved.includeAllNetworks == strict, RoutingSecurityPolicy.matches(saved, strict: strict, allowLAN: allowLAN), native.isEnabled else { throw AppIssue(message: "The saved IKEv2 policy differs from the requested configuration.") }
            manager = native; configuredProfile = draft.id; protocolName = "IKEv2"; activeMode = nil
            UserDefaults.standard.set("IKEv2", forKey: "last-vpn-adapter")
            wantedConnection = true; retryAttempt = 0; evidence = []
            setupStep = "start-native-tunnel"
            try await startRegisteredTunnel(native, operation: operation) {
                guard let saved = native.protocolConfiguration as? NEVPNProtocolIKEv2 else { return false }
                return saved.serverAddress == proto.serverAddress && saved.remoteIdentifier == proto.remoteIdentifier &&
                    saved.passwordReference == proto.passwordReference && saved.authenticationMethod == proto.authenticationMethod &&
                    saved.includeAllNetworks == strict && RoutingSecurityPolicy.matches(saved, strict: strict, allowLAN: allowLAN) &&
                    native.isOnDemandEnabled == (draft.onDemand || strict) &&
                    RoutingSecurityPolicy.matchesOnDemand(native.onDemandRules, enabled: draft.onDemand || strict, trusted: TrustedNetworks.active(strict: strict))
            }
            refreshStatus(); armWatchdog()
            message = "IKEv2 uses server-managed DNS. Exit identity, DNS behavior and routing isolation remain unverified."
            record("Native IKEv2 connection requested")
        } catch {
            wantedConnection = false; stage = .failed
            if loaded {
                native.protocolConfiguration = previous; native.onDemandRules = previousRules
                native.isEnabled = previousEnabled; native.isOnDemandEnabled = previousOnDemand; native.localizedDescription = previousDescription
                manager = previousManager; configuredProfile = previousProfileID; protocolName = previousName; activeMode = previousMode
                do {
                    if previous != nil { try await native.saveToPreferences() } else { try await native.removeFromPreferences() }
                    if secretChanged { if let previousSecret { try Vault.put(previousSecret, account: account) } else { try Vault.delete(account) } }
                } catch { message = "IKEv2 rollback could not be confirmed. Review VayuSetu in system VPN settings."; return }
            }
            message = (error as? AppIssue)?.message ?? "IKEv2 setup failed. Check permission, provisioning and server configuration."
            let ns = error as NSError
            let detail = (error as? AppIssue)?.message ?? "System error " + TunnelStartupEvent.sanitizedDomain(ns.domain) + ":" + String(ns.code)
            record("Native IKEv2 setup failed at " + setupStep + " · " + detail, severity: .error)
        }
    }
    private func startRegisteredTunnel(_ target: NEVPNManager, operation: UUID, secret: Data? = nil, validate: () -> Bool) async throws {
        for attempt in 0...2 {
            guard lifecycleID == operation, wantedConnection, !Task.isCancelled else { throw CancellationError() }
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(300))
                try await target.loadFromPreferences()
            }
            guard lifecycleID == operation, wantedConnection, !Task.isCancelled else { throw CancellationError() }
            guard target.isEnabled, validate() else {
                throw AppIssue(message: "The saved VPN policy changed during activation. Connection was stopped.")
            }
            if [.connecting, .connected, .reasserting].contains(target.connection.status) { return }
            guard [.disconnected, .invalid].contains(target.connection.status) else {
                throw AppIssue(message: "Wait for the previous VPN to finish stopping.")
            }
            do {
                #if os(macOS)
                if let secret { try target.connection.startVPNTunnel(options: ["vayuTunnelSecret": secret as NSData]) }
                else { try target.connection.startVPNTunnel() } // Native IKEv2 uses its own Keychain reference.
                #else
                try target.connection.startVPNTunnel()
                #endif
            }
            catch {
                guard VPNActivationRecovery.shouldReload(error as NSError, retries: attempt) else { throw error }
                record("VPN activation registration reload · attempt " + String(attempt + 1), severity: .warning)
                continue
            }
            // iOS can accept the request and still never launch the extension (seen right after another VPN type ran:
            // no startup breadcrumbs, status stays disconnected). Confirm the status moves; otherwise reload and retry.
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                guard lifecycleID == operation, wantedConnection, !Task.isCancelled else { throw CancellationError() }
                if ![.disconnected, .invalid].contains(target.connection.status) { return }
            }
            record("VPN start request was not acted on by iOS · retry " + String(attempt + 1), severity: .warning)
            // A competing configuration can switch ours off in the background; restore it before trying again.
            try await target.loadFromPreferences()
            if !target.isEnabled { target.isEnabled = true; try await target.saveToPreferences(); try await target.loadFromPreferences() }
        }
        throw AppIssue(message: "iOS did not start the tunnel. Turn protection off and on again; if it repeats, remove the VayuSetu VPN in Settings → VPN and retry.")
    }
    func disconnect() async {
        wantedConnection = false; lifecycleID = UUID()
        retryTask?.cancel(); retryTask = nil; watchdog?.cancel(); healthTask?.cancel(); checkingHealth = false
        guard !busy, let mgr = manager else { return }
        busy = true; defer { busy = false }
        do {
            mgr.isOnDemandEnabled = false
            try await mgr.saveToPreferences()
            mgr.connection.stopVPNTunnel(); refreshStatus(); record("Disconnect requested; on-demand disabled")
        } catch { message = "Could not disable on-demand. Stop the VPN from system VPN settings and retry." }
    }
    func repairWireGuardRegistration() async throws {
        guard !busy else { throw AppIssue(message: "Finish the current VPN operation before repair.") }
        if running { await disconnect() }
        wantedConnection = false; retryTask?.cancel(); watchdog?.cancel()
        let owned = try await NETunnelProviderManager.loadAllFromPreferences().filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }
        for item in owned {
            item.isOnDemandEnabled = false; item.isEnabled = false
            try await item.saveToPreferences(); item.connection.stopVPNTunnel()
            for _ in 0..<100 {
                if [.disconnected, .invalid].contains(item.connection.status) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard [.disconnected, .invalid].contains(item.connection.status) else { throw AppIssue(message: "The saved WireGuard VPN has not stopped. Repair was not completed.") }
            try await item.removeFromPreferences()
        }
        if manager is NETunnelProviderManager { manager = nil; configuredProfile = nil }
        await load()
        record("Owned WireGuard system registration rebuilt; saved profiles and credentials preserved")
    }
    func emergencyReset() async {
        wantedConnection = false; lifecycleID = UUID()
        retryTask?.cancel(); watchdog?.cancel(); healthTask?.cancel(); sampleTask?.cancel()
        for _ in 0..<100 { if !busy { break }; try? await Task.sleep(for: .milliseconds(100)) }
        guard !busy else { message = "VPN operation is still completing. Disable VayuSetu manually in system VPN settings."; return }
        busy = true; defer { busy = false }
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            for item in all where (item.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID {
                item.isOnDemandEnabled = false; item.isEnabled = false
                try await item.saveToPreferences(); item.connection.stopVPNTunnel()
                try await item.removeFromPreferences()
            }
            let native = NEVPNManager.shared(); try await native.loadFromPreferences()
            if native.localizedDescription?.hasPrefix("VayuSetu IKEv2 · ") == true { native.isOnDemandEnabled = false; native.isEnabled = false; try await native.saveToPreferences(); native.connection.stopVPNTunnel(); try await native.removeFromPreferences() }
            try Vault.delete("active-tunnel")
            manager = nil; configuredProfile = nil; activeMode = nil; status = .invalid; stats = nil; stage = .disconnected
            finishSession(totals: nil); record("Emergency reset removed managed VPN configurations")
            message = "VayuSetu VPN configuration removed."
        } catch { message = "VPN reset could not be confirmed. Disable VayuSetu manually in system VPN settings." }
    }
    func removeNativeConfiguration(for profileID: UUID) async throws {
        guard !busy, !running else { throw AppIssue(message: "Disconnect the active VPN before deleting native configuration.") }
        busy = true; defer { busy = false }
        let native = NEVPNManager.shared(); try await native.loadFromPreferences()
        guard native.localizedDescription == "VayuSetu IKEv2 · " + profileID.uuidString else { return }
        native.isOnDemandEnabled = false; native.isEnabled = false
        try await native.saveToPreferences(); native.connection.stopVPNTunnel()
        for _ in 0..<100 { if [.invalid, .disconnected].contains(native.connection.status) { break }; try? await Task.sleep(for: .milliseconds(100)) }
        guard [.invalid, .disconnected].contains(native.connection.status) else { throw AppIssue(message: "The native VPN has not stopped. The saved profile was preserved.") }
        try await native.removeFromPreferences()
        if configuredProfile == profileID { manager = nil; configuredProfile = nil; activeMode = nil; status = .invalid; stats = nil; wantedConnection = false; stage = .disconnected }
    }
    func removeConfiguration(for profileID: UUID? = nil) async throws {
        guard !busy else { throw AppIssue(message: "Wait for the current VPN operation to finish.") }
        if let profileID, configuredProfile != profileID { return }
        guard !running else { throw AppIssue(message: "Disconnect the VPN before removing its configuration.") }
        if let manager { try await manager.removeFromPreferences() }
        try Vault.delete("active-tunnel")
        manager = nil; configuredProfile = nil; activeMode = nil; status = .invalid; stats = nil; stage = .disconnected
        wantedConnection = false; retryTask?.cancel(); watchdog?.cancel(); finishSession()
        record("VPN configuration removed")
    }
    func refreshStats() {
        guard !statsPending, status == .connected, let session = manager?.connection as? NETunnelProviderSession else { return }
        let revision = statusRevision
        statsPending = true
        // Prevent a lost extension callback from permanently disabling the refresh control.
        let requestID = UUID(); statsRequestID = requestID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.statsRequestID == requestID else { return }
            self.statsPending = false; self.statsRequestID = nil
        }
        do {
            try session.sendProviderMessage(TunnelDiagnosticRequest.statistics) { [weak self] data in
                let decoded = data.flatMap { $0.count <= 16_384 ? try? JSONDecoder().decode(TunnelStats.self, from: $0) : nil }
                Task { @MainActor in
                    guard let self, self.statsRequestID == requestID else { return }
                    self.statsPending = false; self.statsRequestID = nil
                    // A late response from a disconnected/replaced tunnel must not revive stale evidence.
                    guard self.statusRevision == revision, self.status == .connected, let decoded, decoded.diagnosticVersion == nil || decoded.diagnosticVersion == 1 else { return }
                    let now = ContinuousClock.now
                    if let (previousTime, previous) = self.lastSample {
                        let elapsed = previousTime.duration(to: now).components
                        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                        if seconds > 0, decoded.received >= previous.received, decoded.sent >= previous.sent {
                            self.rateSampleAvailable = true
                            self.receivedPerSecond = Double(decoded.received - previous.received) / seconds
                            self.sentPerSecond = Double(decoded.sent - previous.sent) / seconds
                        } else { self.rateSampleAvailable = false; self.receivedPerSecond = 0; self.sentPerSecond = 0 }
                    }
                    self.lastSample = (now, decoded); self.stats = decoded; self.statsRecordedAt = Date()
                    self.trafficPoints.append(TrafficPoint(date: Date(), received: self.receivedPerSecond, sent: self.sentPerSecond))
                    self.trafficPoints = Array(self.trafficPoints.suffix(120))
                    self.checkUsage(decoded)
                }
            }
        } catch { statsPending = false; statsRequestID = nil; message = "Tunnel diagnostics are unavailable. Try again after reconnecting." }
    }
    private func checkUsage(_ stats: TunnelStats) {
        guard usageBudgetMB > 0, !usageAlerted, Double(stats.received) + Double(stats.sent) >= Double(usageBudgetMB) * 1_048_576 else { return }
        usageAlerted = true
        message = "Tunnel data alert: \(usageBudgetMB) MiB of combined upload and download reached."
        record("Configured tunnel data threshold reached", severity: .warning, category: "traffic")
        if notificationsEnabled {
            let content = UNMutableNotificationContent(); content.title = "VayuSetu data alert"; content.body = message
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "usage-alert", content: content, trigger: nil)) { _ in }
        }
    }
    private var statsRequestID: UUID?
    private var historyURL: URL { LocalFiles.url("session-history.json") }
    private var historyWritable = true
    private func restoreHistory() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyURL)
            guard data.count <= 512_000 else { throw AppIssue(message: "History too large") }
            let archive = try JSONDecoder().decode(HistoryArchive.self, from: data)
            guard archive.version == 1 else { throw AppIssue(message: "Unknown history version") }
            history = Array(archive.sessions.prefix(100))
        } catch { historyWritable = false }
    }
    private func persistHistory() {
        guard historyWritable else { return }
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(HistoryArchive(version: 1, sessions: history)).write(to: historyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch { record("Could not save session history") }
    }
    func clearHistory() {
        do { if FileManager.default.fileExists(atPath: historyURL.path) { try FileManager.default.removeItem(at: historyURL) }; history = []; historyWritable = true }
        catch { message = "Could not remove local history." }
    }
    private func finishSession(totals: TunnelStats? = nil) {
        guard let id = sessionID, let started = sessionStart else { return }
        let totals = totals ?? lastSample?.1
        history.insert(SessionRecord(id: id, started: started, ended: Date(), received: totals?.received ?? 0, sent: totals?.sent ?? 0, outcome: stage, profileID: configuredProfile), at: 0)
        history = Array(history.prefix(100)); sessionID = nil; sessionStart = nil; sessionStartedAt = nil; persistHistory()
    }
    var observedConnectedDate: Date? { sessionStart }
    var duration: String { guard let sessionStartedAt else { return "No active session" }; return SessionClock.format(seconds: sessionElapsedOffset + max(0, sessionStartedAt.duration(to: .now).components.seconds)) }
    private func startSampling() {
        sampleTask?.cancel()
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.status == .connected else { return }
                self.refreshStats()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private func armWatchdog() {
        watchdog?.cancel(); let id = lifecycleID; let timeout = max(10, min(120, connectionTimeout))
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard let self, self.lifecycleID == id, self.status != .connected, self.wantedConnection else { return }
            self.record("Connection deadline exceeded", severity: .warning)
            self.manager?.connection.stopVPNTunnel(); self.refreshStatus(); self.scheduleRetry()
            if !self.autoReconnect { self.wantedConnection = false; self.stage = .failed; self.message = "Connection deadline exceeded." }
        }
    }
    private func scheduleRetry() {
        guard !busy, wantedConnection, autoReconnect, pathAvailable, retryTask == nil else { return }
        guard let delay = retryPolicy.delay(after: retryAttempt) else {
            wantedConnection = false; stage = .failed; message = "Reconnect limit reached. Check your configuration and reconnect manually."
            // Exhausting app retries must not silently disable the user's OS on-demand policy.
            if manager?.isOnDemandEnabled == true { message += " System on-demand remains enabled; disconnect explicitly to disable it." }
            return
        }
        retryAttempt += 1; stage = .reconnecting; let id = lifecycleID
        record("Reconnect scheduled · attempt \(retryAttempt) of \(retryPolicy.maximumAttempts)")
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }; self.retryTask = nil
            guard self.lifecycleID == id, self.wantedConnection, self.pathAvailable, self.status == .disconnected else { return }
            do {
                #if os(macOS)
                if self.manager?.protocolConfiguration is NETunnelProviderProtocol {
                    guard let secret = try Vault.get("active-tunnel"), secret.count <= 128_000 else { throw AppIssue(message: "Saved tunnel credentials are unavailable.") }
                    try self.manager?.connection.startVPNTunnel(options: ["vayuTunnelSecret": secret as NSData])
                } else { try self.manager?.connection.startVPNTunnel() }
                #else
                try self.manager?.connection.startVPNTunnel()
                #endif
                self.refreshStatus(); self.armWatchdog()
            }
            catch { self.record("Reconnect request failed", severity: .error); self.scheduleRetry() }
        }
    }
    func observedCounters() -> TunnelCounterSample? {
        guard status == .connected, let stats, let date = statsRecordedAt, Date().timeIntervalSince(date) < 10 else { return nil }
        return TunnelCounterSample(date: date, received: stats.received, sent: stats.sent)
    }
    // Only fresh statistics from the established session may describe accepted extension settings.
    var currentAppliedPolicy: AppliedTunnelPolicy? { observedCounters() == nil ? nil : stats?.appliedPolicy }
    func acceptedResolverMatches(_ endpoint: String) -> Bool {
        guard protocolName == "WireGuard", status == .connected else { return false }
        return DNSConfigurationIdentity.matchesAccepted(currentAppliedPolicy, endpoint: endpoint)
    }
    var appliedDNSDescription: String {
        guard status == .connected else { return "No established session" }
        if protocolName == "IKEv2" { return "Server-managed · details unavailable" }
        guard let policy = currentAppliedPolicy else { return "Acceptance evidence unavailable" }
        return policy.encryptedDNS && policy.allDNSDomains ? "Encrypted settings accepted" : "Required settings not confirmed"
    }
    var appliedConfigurationDescription: String {
        guard status == .connected else { return "No established session" }
        if protocolName == "IKEv2" { return "OS reports connected; route details unavailable" }
        return currentAppliedPolicy == nil ? "Acceptance evidence unavailable" : "Tunnel settings accepted by iOS"
    }
    var configuredPolicySummary: String {
        guard let proto = manager?.protocolConfiguration else { return "No saved VPN policy." }
        return "Saved system configuration\nStrict capture: \(proto.includeAllNetworks) · enforce routes: \(proto.enforceRoutes)\nLocal network exception: \(proto.excludeLocalNetworks) · on-demand: \(manager?.isOnDemandEnabled == true)\n" + (currentAppliedPolicy?.summary ?? "No current accepted-settings evidence from this extension.") + "\nOS-required traffic exceptions may remain. This does not prove fail-closed behavior during crashes, network transitions or manual disconnect."
    }
    var trafficExceptionSummary: String {
        guard let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol else { return "No saved routing policy." }
        var lines = [
            "Full-network capture requested: \(proto.includeAllNetworks)",
            "Route enforcement: \(proto.enforceRoutes)",
            "Local-network traffic excluded: \(proto.excludeLocalNetworks)",
            "Connect on demand: \(manager?.isOnDemandEnabled == true)"
        ]
        if #available(iOS 16.4, macOS 13.3, *) {
            lines.append("Apple Push Notification traffic excluded: \(proto.excludeAPNs)")
            lines.append("Cellular service traffic excluded: \(proto.excludeCellularServices)")
        }
        if #available(iOS 17.4, macOS 14.4, *) {
            lines.append("Device communication excluded: \(proto.excludeDeviceCommunication)")
        }
        #if DEBUG
        lines.append("Debug build: device communication may bypass the tunnel for Xcode support")
        #endif
        return lines.joined(separator: "\n")
    }
    func verifyConnection(resolver: String, includeIPProbes: Bool = true) {
        guard status == .connected, !checkingHealth else { return }
        let id = lifecycleID; let revision = statusRevision
        checkingHealth = true; stage = .verifying; evidence = []
        healthTask = Task { [weak self] in
            guard let self else { return }
            var checks: [Evidence] = []
            let handshakeAge = self.stats?.latestHandshake.map { Date().timeIntervalSince($0) }
            checks.append(Evidence("Handshake", handshakeAge.map { $0 >= 0 && $0 < 180 ? .passed : .inconclusive } ?? .unverified, "Recent WireGuard handshake reported by extension; not full connectivity proof"))
            do { let url = try DNSService.endpoint(resolver); _ = try await DNSService.probe(url); checks.append(Evidence("Resolver response", .passed, "example.com A response via selected encrypted endpoint")) }
            catch { checks.append(Evidence("Resolver response", .failed, "Encrypted DNS request or DNS reply validation failed")) }
            for family in includeIPProbes ? [4, 6] : [] {
                do { _ = try await NetworkDiagnostics.probeIP(family: family); checks.append(Evidence("IPv\(family) public address", .passed, "HTTPS response from an IPv\(family) test destination; provider identity not independently proven")) }
                catch { checks.append(Evidence("IPv\(family) public address", .inconclusive, (error as? IPFailure)?.errorDescription ?? "Public-IP discovery failed; inspect Checks for request details")) }
            }
            checks.append(Evidence("IPv4 exit", .unverified, "Public address discovery does not independently attribute the VPN provider exit"))
            checks.append(Evidence("IPv6 policy", .unverified, "Route configuration needs independent bypass/negative-control evidence"))
            checks.append(Evidence("DNS transport", .unverified, "Successful DoH alone cannot prove the physical packet path"))
            checks.append(Evidence("Routing isolation", .unverified, "Requires controlled destinations and packet capture"))
            guard !Task.isCancelled, self.lifecycleID == id, self.statusRevision == revision, self.status == .connected else { return }
            self.evidence = checks; self.checkingHealth = false; self.stage = HealthPolicy.complete(checks) ? .connected : .degraded
            self.record("Connection checks completed; routing security remains unverified")
        }
    }

}
