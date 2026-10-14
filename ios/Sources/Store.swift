import Foundation
import Security
import Combine

import VayuSetuCore

@MainActor final class AppStore: ObservableObject {
    @Published var profiles: [SavedProfile] = []
    @Published private(set) var manualDrafts: [ManualVPNDraftSummary] = []
    @Published private(set) var manualDraftStorageError = ""
    private var manualDraftStorageWritable = true
    @Published private(set) var connectionOperation = false
    private var connectionTask: Task<Void, Never>?
    private var appOperationID = UUID()
    @Published private(set) var lastUsed: [String: Date] = (UserDefaults.standard.dictionary(forKey: "profile-last-used") as? [String: Date]) ?? [:]
    /// The user chose "No VPN profile": only the local DNS tunnel runs. Any profile selection clears it.
    @Published private(set) var dnsOnlyChosen = false { didSet { UserDefaults.standard.set(dnsOnlyChosen, forKey: "no-vpn-profile") } }
    @Published var selectedManualProfile: UUID? { didSet { UserDefaults.standard.set(selectedManualProfile?.uuidString, forKey: "selected-manual-profile"); if selectedManualProfile != nil { dnsOnlyChosen = false } } }
    @Published var selected: UUID? { didSet { UserDefaults.standard.set(selected?.uuidString, forKey: "selected-profile"); if selected != nil { dnsOnlyChosen = false } } }
    // Protection coordinator state (ADR-011). `selection` holds what the user asked for; what is actually running is
    // always derived from the tunnels, the OS and the extension, never from these requests.
    @Published var selection = ProtectionSelection()
    @Published private(set) var savedNetwork: SavedNetworkMode?
    @Published private(set) var protectionBusy = false
    /// The power button asks which mode to use until the user has picked one from its own selector.
    @Published private(set) var powerModeChosen = UserDefaults.standard.bool(forKey: "power-mode-chosen") { didSet { UserDefaults.standard.set(powerModeChosen, forKey: "power-mode-chosen") } }
    @Published var protectionNotice = "" { didSet { scheduleNoticeClear() } }
    private var noticeClear: Task<Void, Never>?
    /// The latest end-to-end DNS check through the device's own DNS path; the only thing besides observed query counts that turns the DNS pill green.
    @Published private(set) var dnsVerification: DNSVerification?
    @Published private(set) var dnsVerifying = false
    /// Lines from the last "Run Check": resolver reachability and, where it applies, the device DNS path. Never a verdict by itself.
    @Published private(set) var dnsCheckLines: [String] = []
    @Published private(set) var dnsCheckDate: Date?
    @Published private(set) var dnsChecking = false
    @Published var pendingDecision: ProtectionDecision?
    /// VayuSetu DNS over WireGuard: send the filter's upstream queries outside the VPN. Off by default (inside the VPN).
    @Published var dnsUpstreamDirect = UserDefaults.standard.bool(forKey: "dns-upstream-direct") { didSet { UserDefaults.standard.set(dnsUpstreamDirect, forKey: "dns-upstream-direct") } }
    @Published var mode: RoutingMode = .vpnFirst { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "routing-mode") } }
    @Published var onDemand = false { didSet { UserDefaults.standard.set(onDemand, forKey: "on-demand") } }
    @Published var strictRouting = true { didSet { UserDefaults.standard.set(strictRouting, forKey: "strict-routing") } }
    @Published var requireNativeIPv6 = false { didSet { UserDefaults.standard.set(requireNativeIPv6, forKey: "require-native-ipv6") } }
    let tunnel = TunnelController()
    let filtering = FilteringController()
    let systemDNS = SystemDNSController()
    /// Home reads the three protection pills from this store, but Safari and DNS state live in their own objects.
    /// Their changes must redraw every screen that derives a pill from them, wherever the change was made.
    private var forwarding: [AnyCancellable] = []
    @Published var dnsProfiles: [DNSProfile] = []
    @Published var selectedDNS: UUID?
    @Published var dnsName = ""
    /// Backups used only when the main choice fails: a second encrypted resolver and a second VPN profile.
    @Published var backupDNS: UUID? { didSet { UserDefaults.standard.set(backupDNS?.uuidString, forKey: "backup-dns") } }
    @Published var backupProfile: UUID? { didSet { UserDefaults.standard.set(backupProfile?.uuidString, forKey: "backup-profile") } }
    @Published var bootstrapAddresses: [String] = []
    @Published var endpoint = "" { didSet { if endpoint != oldValue { invalidateDNS() } } }
    @Published var notice = ""
    @Published var testing = false
    @Published var probeDomain = "example.com" { didSet { invalidateDNS() } }
    @Published var expectNXDOMAIN = false { didSet { invalidateDNS() } }
    @Published var probeRecordType: DNSRecordType = .a { didSet { invalidateDNS() } }
    @Published var connectOnLaunch = false { didSet { UserDefaults.standard.set(connectOnLaunch, forKey: "connect-on-launch") } }
    @Published var result = ""
    @Published var pendingDeletion: SavedProfile?
    private var dnsRevision = UUID()
    private var dnsTask: Task<Void, Never>?
    private var storageWritable = true
    private let location: URL
    init() {
        location = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent((Bundle.main.object(forInfoDictionaryKey: "VayuStorageDirectory") as? String) ?? "VayuSetu").appendingPathComponent("profiles.json")
        forwarding = [filtering.objectWillChange, systemDNS.objectWillChange].map { publisher in
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }
        }
        // Read before any selection assignment below can clear it through the observers.
        let wantsDNSOnly = UserDefaults.standard.bool(forKey: "no-vpn-profile")
        backupDNS = UserDefaults.standard.string(forKey: "backup-dns").flatMap(UUID.init)
        backupProfile = UserDefaults.standard.string(forKey: "backup-profile").flatMap(UUID.init)
        do {
            try recoverInterruptedRestore()
            loadManualDrafts()
            selectedManualProfile = UserDefaults.standard.string(forKey: "selected-manual-profile").flatMap(UUID.init(uuidString:))
            if !manualDrafts.contains(where: { $0.id == selectedManualProfile }) { selectedManualProfile = nil }
            if FileManager.default.fileExists(atPath: location.path) {
                let data = try Data(contentsOf: location)
                if let archive = try? JSONDecoder().decode(ProfileArchive.self, from: data) {
                    guard archive.version == 1 else { throw AppIssue(message: "Unsupported profile storage version. Your saved file has been preserved.") }
                    profiles = archive.profiles
                } else { profiles = try JSONDecoder().decode([SavedProfile].self, from: data) }
            }
            guard Set(profiles.map(\.id)).count == profiles.count else { throw AppIssue(message: "Duplicate stored profile identifiers. Saved data has been preserved.") }
            selected = UserDefaults.standard.string(forKey: "selected-profile").flatMap(UUID.init(uuidString:))
            if !profiles.contains(where: { $0.id == selected }) { selected = profiles.first?.id }
            if wantsDNSOnly { selected = nil; selectedManualProfile = nil; dnsOnlyChosen = true }
            mode = .vpnFirst
            if UserDefaults.standard.string(forKey: "routing-mode") == RoutingMode.dnsFirst.rawValue {
                notice = "Direct DNS is now unavailable pending DNS-only bypass verification. Remove any old on-demand VPN configuration before connecting."
            }
            requireNativeIPv6 = UserDefaults.standard.bool(forKey: "require-native-ipv6")
            connectOnLaunch = UserDefaults.standard.bool(forKey: "connect-on-launch")
            onDemand = UserDefaults.standard.bool(forKey: "on-demand")
            strictRouting = UserDefaults.standard.object(forKey: "strict-routing") as? Bool ?? true
            if FileManager.default.fileExists(atPath: dnsLocation.path) {
                let archive = try JSONDecoder().decode(DNSArchive.self, from: Data(contentsOf: dnsLocation))
                guard archive.version == 1, Set(archive.profiles.map(\.id)).count == archive.profiles.count else { throw AppIssue(message: "Unsupported or corrupt DNS profile storage. Saved data has been preserved.") }
                dnsProfiles = archive.profiles
            }
            try seedVayuSetuDNS()
            filtering.onDNSRulesPublished = { [weak self] in self?.tunnel.reloadDNSRules() }
            restoreSelection()
            selectedDNS = UserDefaults.standard.string(forKey: "selected-dns").flatMap(UUID.init(uuidString:))
            if let profile = dnsProfiles.first(where: { $0.id == selectedDNS }) ?? dnsProfiles.first {
                loadDNS(profile)
            } else if let data = try Vault.get("control-d-endpoint") {
                endpoint = String(decoding: data, as: UTF8.self); dnsName = "Control D"
            }
        } catch { storageWritable = false; notice = "Saved configuration could not be loaded. Changes are blocked to preserve the original files." }
    }
    /// The built-in provider exists on every install; its upstream resolver is stored like any other endpoint.
    private func seedVayuSetuDNS() throws {
        guard storageWritable, !dnsProfiles.contains(where: { $0.id == VayuSetuDNS.id }) else { return }
        try Vault.put(Data(VayuSetuDNS.upstreamEndpoint.utf8), account: "dns-" + VayuSetuDNS.id.uuidString)
        let items = [DNSProfile(id: VayuSetuDNS.id, name: VayuSetuDNS.name, bootstrapAddresses: VayuSetuDNS.bootstrapAddresses)] + dnsProfiles
        try saveDNS(items); dnsProfiles = items
    }
    /// Hands the tunnel the backup resolver for the next connection; nothing is sent if none is chosen or it cannot be read.
    private func prepareBackupResolver() {
        tunnel.fallbackDNS = nil
        guard let id = backupDNS, id != selectedDNS, let profile = dnsProfiles.first(where: { $0.id == id }),
              let data = try? Vault.get("dns-" + id.uuidString), let text = String(data: data, encoding: .utf8),
              let url = try? DNSService.endpoint(text) else { return }
        tunnel.fallbackDNS = (url.absoluteString, profile.bootstrapAddresses ?? [])
    }
    var isVayuSetuDNSSelected: Bool { selectedDNS == VayuSetuDNS.id }
    /// Starts the local DNS tunnel. VayuSetu DNS applies the built-in lists locally before any upstream query.
    func startLocalDNS() async {
        let useRules = isVayuSetuDNSSelected
        if useRules {
            await filtering.ensureStarterListForDNS()
            do { try filtering.publishDNSRules() } catch { notice = "VayuSetu DNS could not publish its filter rules. The tunnel was not started."; return }
        }
        prepareBackupResolver()
        await tunnel.connectDNSOnly(resolver: endpoint, bootstrapAddresses: bootstrapAddresses, filtering: useRules)
    }
    private var manualDraftURL: URL { location.deletingLastPathComponent().appendingPathComponent("manual-vpn-drafts.json") }
    private func loadManualDrafts() {
        do {
            guard FileManager.default.fileExists(atPath: manualDraftURL.path) else { return }
            guard (try manualDraftURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 128_000 else { throw AppIssue(message: "Draft metadata exceeds its limit.") }
            let archive = try JSONDecoder().decode(ManualVPNDraftArchive.self, from: Data(contentsOf: manualDraftURL))
            guard archive.version == 1, archive.drafts.count <= 100, Set(archive.drafts.map(\.id)).count == archive.drafts.count else { throw AppIssue(message: "Unsupported draft metadata.") }
            manualDrafts = archive.drafts
        } catch { manualDraftStorageWritable = false; manualDraftStorageError = "Protocol draft storage needs recovery. Existing files are preserved." }
    }
    func manualDraft(_ summary: ManualVPNDraftSummary) throws -> ManualVPNDraft {
        guard let data = try Vault.get("manual-vpn-" + summary.id.uuidString) else { return ManualVPNDraft(id: summary.id, protocolKind: summary.protocolKind, name: summary.name) }
        guard data.count <= 128_000 else { throw AppIssue(message: "Draft credentials exceed the size limit.") }
        let value = try JSONDecoder().decode(ManualVPNDraft.self, from: data)
        guard value.id == summary.id, value.protocolKind == summary.protocolKind else { throw AppIssue(message: "Draft metadata does not match its saved configuration.") }
        return value
    }
    func saveManualDraft(_ value: ManualVPNDraft) throws {
        guard manualDraftStorageWritable else { throw AppIssue(message: manualDraftStorageError) }
        try value.validate()
        var items = manualDrafts
        let summary = ManualVPNDraftSummary(id: value.id, name: value.name.trimmingCharacters(in: .whitespacesAndNewlines), protocolKind: value.protocolKind)
        if let index = items.firstIndex(where: { $0.id == value.id }) { items[index] = summary }
        else { guard items.count < 100 else { throw AppIssue(message: "The 100-draft limit has been reached.") }; items.append(summary) }
        let account = "manual-vpn-" + value.id.uuidString
        let previous = try Vault.get(account)
        try Vault.put(JSONEncoder().encode(value), account: account)
        do { try LocalFiles.write(JSONEncoder().encode(ManualVPNDraftArchive(version: 1, drafts: items)), to: manualDraftURL); manualDrafts = items }
        catch {
            do { if let previous { try Vault.put(previous, account: account) } else { try Vault.delete(account) } }
            catch { manualDraftStorageWritable = false; manualDraftStorageError = "Draft rollback needs recovery. Avoid further changes." }
            throw AppIssue(message: "Could not save the draft metadata. No VPN configuration was applied.")
        }
    }
    func deleteManualDraft(_ summary: ManualVPNDraftSummary) async throws {
        guard manualDrafts.contains(where: { $0.id == summary.id && $0.protocolKind == .ikev2 }), manualDraftStorageWritable, !tunnel.running, !tunnel.busy, !connectionOperation else { throw AppIssue(message: "Disconnect and finish pending operations before deleting this saved IKEv2 profile.") }
        connectionOperation = true; defer { connectionOperation = false }
        try await tunnel.removeNativeConfiguration(for: summary.id)
        let draftAccount = "manual-vpn-" + summary.id.uuidString
        let passwordAccount = "native-ike-password-" + summary.id.uuidString
        let draftData = try Vault.get(draftAccount); let passwordData = try Vault.get(passwordAccount)
        let remaining = manualDrafts.filter { $0.id != summary.id }
        do {
            try LocalFiles.write(JSONEncoder().encode(ManualVPNDraftArchive(version: 1, drafts: remaining)), to: manualDraftURL)
            try Vault.delete(draftAccount); try Vault.delete(passwordAccount)
            manualDrafts = remaining
            if selectedManualProfile == summary.id { selectedManualProfile = nil }
        } catch {
            do {
                if let draftData { try Vault.put(draftData, account: draftAccount) }
                if let passwordData { try Vault.put(passwordData, account: passwordAccount) }
                try LocalFiles.write(JSONEncoder().encode(ManualVPNDraftArchive(version: 1, drafts: manualDrafts)), to: manualDraftURL)
            } catch { manualDraftStorageWritable = false; manualDraftStorageError = "Profile deletion rollback needs recovery. Existing credentials were preserved where possible." }
            throw AppIssue(message: "Profile deletion could not be completed. Review saved configuration before retrying.")
        }
    }
    private var reconciliationTask: Task<Void, Never>?
    private var lastDNSRestorationAttempt: Date?
    /// Reconciles observations and an explicitly suspended independent DNS request.
    /// Never starts/stops VPN, changes DNS intent, or applies Safari rules.
    func reconcileNetworkState() async {
        if let reconciliationTask { await reconciliationTask.value; return }
        let task = Task { @MainActor in
            tunnel.refreshStatus()
            await systemDNS.refresh()
            await filtering.refresh()
            if lastDNSRestorationAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
               IndependentDNSResumePolicy.shouldRestore(desired: systemDNS.desiredEnabled,
                suspended: systemDNS.hasSuspendedConfiguration, saved: systemDNS.hasSavedConfiguration,
                foreign: systemDNS.hasForeignConfiguration, observationKnown: systemDNS.enabled != nil,
                vpnSettledOff: tunnel.ready && !tunnel.running && !tunnel.busy,
                operationPending: connectionOperation || systemDNS.busy) {
                lastDNSRestorationAttempt = Date()
                connectionOperation = true
                defer { connectionOperation = false }
                _ = await systemDNS.restoreSuspendedConfiguration()
                invalidateDNS()
            }
        }
        reconciliationTask = task
        await task.value
        reconciliationTask = nil
    }
    func protection(_ subsystem: ProtectionSubsystem, now: Date = .now) -> ProtectionSnapshot {
        switch subsystem {
        case .safari: return filtering.snapshot(now: now)
        case .adblock: return filtering.adblockSnapshot(now: now)
        case .dns:
            if tunnel.running || tunnel.busy {
                if tunnel.busy || tunnel.status == .connecting || tunnel.status == .reasserting || tunnel.status == .disconnecting {
                    return ProtectionSnapshot(.dns, desired: true, state: .starting, source: .osStatus, at: tunnel.statusObservedAt, reason: "VPN DNS is transitioning. Wait for the connection to settle before checking its behavior.")
                }
                if tunnel.localDNSRunning || (tunnel.protocolName == "WireGuard" && tunnel.stats?.dnsCounters != nil) {
                    return PrivacyIntegrityEngine.reconcile(localDNSSnapshot(now: now), now: now)
                }
                if tunnel.protocolName == "IKEv2" {
                    return ProtectionSnapshot(.dns, desired: true, state: .limited, source: .osStatus, at: tunnel.statusObservedAt, reason: "IKEv2 uses server-managed DNS. The selected encrypted resolver is not applied by this adapter.")
                }
                if selection.dnsEnabled, tunnel.status == .connected, tunnel.acceptedResolverMatches(endpoint),
                   tunnel.evidence.contains(where: { $0.name == "Resolver response" && $0.verdict == .passed }) {
                    return PrivacyIntegrityEngine.reconcile(ProtectionSnapshot(.dns, desired: true, state: .active, source: .resolverObservation, at: tunnel.evidence.first?.timestamp ?? tunnel.statusObservedAt, reason: "iOS accepted the selected encrypted resolver for this VPN and the resolver answered a test query. Apps with their own DNS are not covered."), now: now)
                }
                return ProtectionSnapshot(.dns, desired: true, state: .enabledNotVerified, source: .userPreference, reason: "VPN resolver configured. Waiting for the resolver check.")
            }
            return systemDNS.snapshot(now: now)
        case .vpn:
            let state: ObservedState = !TunnelController.available ? .unknown : tunnel.status == .connected ? .active : tunnel.busy || tunnel.status == .connecting || tunnel.status == .reasserting ? .starting : tunnel.stage == .failed ? .error : tunnel.ready ? .inactive : .unknown
            return PrivacyIntegrityEngine.reconcile(ProtectionSnapshot(.vpn, desired: tunnel.running, state: state, source: .osStatus, at: tunnel.statusObservedAt, reason: "System VPN state. A connected tunnel does not independently verify exit identity or leak isolation."), now: now)
        }
    }
    func stopPendingConnectionRequests() { appOperationID = UUID(); connectionTask?.cancel(); connectionTask = nil; connectionOperation = false }
    func emergencyReset() async {
        appOperationID = UUID(); connectionTask?.cancel(); connectionTask = nil; connectionOperation = false
        connectOnLaunch = false; onDemand = false
        await tunnel.emergencyReset()
        await systemDNS.disable()
        invalidateDNS()
        filtering.record("Emergency reset requested; managed VPN and DNS disabled")
        notice = "Imported profiles and filter rules preserved. " + tunnel.message + " " + systemDNS.message + " Safari rules remain separately controlled in Adblock."
    }
    var active: SavedProfile? { profiles.first { $0.id == selected } }
    /// Only the profile a running VPN is actually using is locked. The local DNS tunnel, or a VPN built from another profile,
    /// never stops you saving, adding or removing a different one.
    func profileInUse(_ profile: SavedProfile?) -> Bool {
        guard let profile, tunnel.running, !tunnel.localDNSRunning else { return false }
        return tunnel.configuredProfile == profile.id
    }
    func save(_ items: [SavedProfile]) throws {
        guard storageWritable else { throw AppIssue(message: "Saved storage needs recovery before changes can be made.") }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(ProfileArchive(version: 1, profiles: items)).write(to: location, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
    }
    private static func profileIdentity(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { line in
            String(line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).filter { !$0.isWhitespace }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    func importProfile(_ url: URL) {
        guard storageWritable else { notice = "Saved storage needs recovery before changes can be made."; return }
        guard !tunnel.busy else { notice = "Wait for the current connection operation before importing."; return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 128_000 else { throw AppIssue(message: "Choose a WireGuard .conf file smaller than 128 KB.") }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw AppIssue(message: "Profile must use UTF-8 text.") }
            let summary = try ProfileParser.parse(text)
            guard profiles.count < 50 else { throw AppIssue(message: "The app supports up to 50 saved profiles.") }
            let identity = Self.profileIdentity(text)
            for existing in profiles {
                if let saved = try Vault.get(existing.id.uuidString), Self.profileIdentity(String(decoding: saved, as: UTF8.self)) == identity {
                    throw AppIssue(message: "This configuration is already saved. Use its action menu to create an intentional duplicate.")
                }
            }
            let id = UUID()
            let profile = SavedProfile(id: id, name: url.deletingPathExtension().lastPathComponent, addresses: summary.addresses, dns: summary.dns, endpoints: summary.endpoints, peerCount: summary.peerCount, fullTunnel: summary.fullTunnel, created: Date())
            try Vault.put(data, account: id.uuidString)
            do { try save(profiles + [profile]) } catch { try? Vault.delete(id.uuidString); throw error }
            profiles.append(profile); if !tunnel.running { selected = id; selectedManualProfile = nil }
            notice = "Profile imported. Keys are stored in this device’s Keychain. The original file remains where you selected it."
        } catch { notice = error.localizedDescription }
    }
    func delete(_ profile: SavedProfile) {
        guard !profileInUse(profile), !tunnel.busy else { notice = "This profile is connected. Disconnect before removing it."; return }
        guard storageWritable else { notice = "Saved storage needs recovery before changes can be made."; return }
        Task {
            do {
                try await tunnel.removeConfiguration(for: profile.id)
                let old = try Vault.get(profile.id.uuidString)
                try Vault.delete(profile.id.uuidString)
                let remaining = profiles.filter { $0.id != profile.id }
                do { try save(remaining) } catch { if let old { try? Vault.put(old, account: profile.id.uuidString) }; throw error }
                profiles = remaining; if selected == profile.id { selected = remaining.first?.id }
                notice = "Profile and keys removed."
            } catch { notice = error.localizedDescription }
        }
    }
    func rename(_ profile: SavedProfile, to name: String) {
        guard !tunnel.busy else { notice = "Wait for the current operation before renaming."; return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 80 else { notice = "Use a name between 1 and 80 characters."; return }
        var items = profiles
        if let index = items.firstIndex(where: { $0.id == profile.id }) { items[index].name = cleaned }
        do { try save(items); profiles = items } catch { notice = "Could not save the profile name." }
    }
    /// The DNS Mode screen's three exclusive choices map onto the independent controls; the coordinator does the work.
    func changeDNSMode(_ target: DNSManagementMode) async -> String {
        var next = selection
        switch target {
        case .system: next.vpnEnabled = false; next.dnsEnabled = false
        case .encrypted: next.vpnEnabled = false; next.dnsEnabled = true
        case .vpn: next.vpnEnabled = true; next.dnsEnabled = true
        }
        return await applySelection(next, confirmed: true)
    }
    var selectedVPNRuntime: ProtectionRuntime {
        guard let id = selectedManualProfile else { return .wireGuard }
        return manualDrafts.first(where: { $0.id == id })?.protocolKind == .openVPN ? .openVPN : .ikev2
    }
    var observedVPNRuntime: ProtectionRuntime {
        tunnel.protocolName == "IKEv2" ? .ikev2 : .wireGuard
    }
    func validateSelectedDNSVPN() throws {
        if let reason = selectedVPNRuntime.capabilities.rejection(remoteVPN: true) { throw AppIssue(message: reason) }
        if let id = selectedManualProfile {
            guard let summary = manualDrafts.first(where: { $0.id == id }), summary.protocolKind == .ikev2 else { throw AppIssue(message: "Select a supported VPN profile in Profiles first.") }
            try manualDraft(summary).validate()
            guard !requireNativeIPv6 else { throw AppIssue(message: "The selected IKEv2 adapter cannot enforce the requested dual-stack policy.") }
        } else {
            guard mode.supported else { throw AppIssue(message: RoutingMode.directDNSUnavailable) }
            guard let profile = active, let data = try Vault.get(profile.id.uuidString) else { throw AppIssue(message: "Select a saved VPN profile with available credentials first.") }
            let parsed = try ProfileParser.parse(String(decoding: data, as: UTF8.self))
            try ProfileParser.validateTunnel(parsed)
            _ = try DNSService.endpoint(endpoint)
            if !bootstrapAddresses.isEmpty { _ = try ResolverBootstrap.validated(bootstrapAddresses) }
            if requireNativeIPv6 && (!parsed.fullTunnel || !parsed.addresses.contains(where: { ProfileParser.ipFamily(String($0.split(separator: "/")[0])) == 6 })) { throw AppIssue(message: "Select a full-tunnel dual-stack WireGuard profile for the requested IPv6 policy.") }
        }
    }

    private var applyGeneration = 0
    private var idleWork: (() -> Void)?
    private var idleWaiter: Task<Void, Never>?
    private var operationInFlight: Bool { connectionOperation || tunnel.busy || protectionBusy }
    /// A switch tapped while another one is still running waits for it and then runs, instead of being rejected. Only the latest request is kept.
    func deferUntilIdle(_ work: @escaping () -> Void) {
        idleWork = work
        guard idleWaiter == nil else { return }
        idleWaiter = Task { [self] in
            var waited = 0
            while operationInFlight && waited < 120 { try? await Task.sleep(for: .milliseconds(500)); waited += 1 }
            idleWaiter = nil
            let next = idleWork; idleWork = nil
            if operationInFlight { notice = "The previous change is taking long. Try again in a moment." } else { next?() }
        }
    }
    /// Connects the selected VPN through the coordinator, keeping the DNS and Safari choices as they are.
    func connect() {
        guard !operationInFlight else { deferUntilIdle { [self] in connect() }; return }
        var next = observedSelection; next.vpnEnabled = true
        connectionTask = Task { [self] in
            protectionNotice = await applySelection(next)
            // One automatic switch to the backup profile; it is never retried, so two bad profiles cannot loop.
            guard tunnel.stage == .failed, !Task.isCancelled, let backup = backupProfile, backup != selected, profiles.contains(where: { $0.id == backup }) else { return }
            let failed = active?.name ?? "The VPN"
            selected = backup
            var again = observedSelection; again.vpnEnabled = true
            protectionNotice = await applySelection(again)
            notice = "\(failed) did not connect, so VayuSetu tried \(active?.name ?? "the backup profile")."
        }
    }
    func selectAndConnectWireGuard(_ profile: SavedProfile) {
        guard !connectionOperation, !tunnel.busy else { deferUntilIdle { [self] in selectAndConnectWireGuard(profile) }; return }
        guard !(tunnel.running && tunnel.configuredProfile == profile.id) else { return }
        // Reject unusable targets before changing selection or stopping the existing VPN.
        do {
            guard mode.supported else { throw AppIssue(message: RoutingMode.directDNSUnavailable) }
            guard let data = try Vault.get(profile.id.uuidString), let configuration = String(data: data, encoding: .utf8) else { throw AppIssue(message: "Profile keys are missing. Import the original configuration again.") }
            let parsed = try ProfileParser.parse(configuration)
            try ProfileParser.validateTunnel(parsed)
            _ = try DNSService.endpoint(endpoint)
            if requireNativeIPv6 && (!parsed.fullTunnel || !parsed.addresses.contains(where: { ProfileParser.ipFamily(String($0.split(separator: "/")[0])) == 6 })) { throw AppIssue(message: "This policy requires a native IPv6 interface and full IPv6 default route. Choose a dual-stack profile.") }
        } catch { notice = (error as? AppIssue)?.message ?? "The target profile could not be validated. The current VPN was preserved."; return }
        if tunnel.running { selectProfile(profile) }
        else { selectedManualProfile = nil; selected = profile.id; connect() }
    }
    /// "No VPN profile": unselect every VPN profile so only DNS protection runs.
    /// A running VPN is stopped first; a running local DNS tunnel is left alone.
    func selectNoVPNProfile() {
        guard !operationInFlight else { deferUntilIdle { [self] in selectNoVPNProfile() }; return }
        selected = nil; selectedManualProfile = nil; dnsOnlyChosen = true
        // Turning the VPN off with DNS on becomes DNS Only; with DNS off everything network-side stops.
        var next = selection; next.vpnEnabled = false
        connectionTask = Task { [self] in protectionNotice = await applySelection(next, confirmed: true) }
    }
    func selectProfile(_ profile: SavedProfile) {
        guard !connectionOperation, !tunnel.busy else { deferUntilIdle { [self] in selectProfile(profile) }; return }
        guard selected != profile.id || selectedManualProfile != nil || (tunnel.running && tunnel.configuredProfile != profile.id) else { return }
        selectedManualProfile = nil
        guard tunnel.running else { selected = profile.id; return }
        connectionOperation = true; let id = UUID(); appOperationID = id
        connectionTask = Task {
            defer { if appOperationID == id { connectionOperation = false; connectionTask = nil } }
            await tunnel.disconnect()
            for _ in 0..<100 {
                guard !Task.isCancelled, appOperationID == id else { return }
                tunnel.refreshStatus()
                if !tunnel.running && !tunnel.busy { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, appOperationID == id else { return }
            guard !tunnel.running, !tunnel.busy else { notice = "Profile switch stopped because the previous tunnel is still active."; return }
            selected = profile.id; await connectSelected()
        }
    }
    private func connectSelected() async {
        if let id = selectedManualProfile {
            guard let summary = manualDrafts.first(where: { $0.id == id }) else { notice = "The selected native profile is missing."; return }
            await connectManual(summary); return
        }
        if dnsOnlyChosen {
            guard !endpoint.isEmpty else { notice = "No VPN profile is selected, so VayuSetu runs DNS only. Choose a DNS provider first."; return }
            await startLocalDNS()
            return
        }
        // Handoff: one tunnel owner. Stopping the local DNS tunnel leaves a short, visible protection gap.
        if tunnel.localDNSRunning {
            await tunnel.disconnect()
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                tunnel.refreshStatus()
                if !tunnel.running && !tunnel.busy { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !tunnel.running, !tunnel.busy else { notice = "The local DNS tunnel has not stopped. The VPN was not started."; return }
        }
        await systemDNS.refresh()
        guard !Task.isCancelled else { return }
        guard systemDNS.enabled != true else { notice = "Disable encrypted DNS-only in DNS before starting VPN + DNS. This avoids competing DNS configurations."; return }
        guard mode.supported else { notice = RoutingMode.directDNSUnavailable; return }
        guard let profile = active else { notice = "Import and select a WireGuard profile first."; return }
        do {
            guard let data = try Vault.get(profile.id.uuidString) else { throw AppIssue(message: "Profile keys are missing. Import the original file again.") }
            try ProfileParser.validateTunnel(ProfileParser.parse(String(decoding: data, as: UTF8.self)))
            // VPN Only (DNS off) applies no resolver: the imported profile's own DNS settings stay in force.
            let applyResolver = selection.dnsEnabled
            let resolver = applyResolver ? try DNSService.endpoint(endpoint).absoluteString : ""
            // VayuSetu DNS filters inside the WireGuard tunnel too: publish the rules before the tunnel reads them.
            let useRules = selection.dnsEnabled && isVayuSetuDNSSelected
            if useRules {
                await filtering.ensureStarterListForDNS()
                do { try filtering.publishDNSRules() } catch { notice = "VayuSetu DNS could not publish its filter rules. The VPN was not started."; return }
            }
            prepareBackupResolver()
            await tunnel.connect(profile: profile, configuration: data, resolver: resolver, mode: mode, onDemand: onDemand || strictRouting, strictRouting: strictRouting, requireNativeIPv6: requireNativeIPv6, bootstrapAddresses: bootstrapAddresses, filtering: useRules, dnsUpstreamDirect: dnsUpstreamDirect, applyResolver: applyResolver)
            if tunnel.status == .connected || tunnel.status == .connecting { lastUsed[profile.id.uuidString] = Date(); UserDefaults.standard.set(lastUsed, forKey: "profile-last-used") }
        } catch { notice = error.localizedDescription }
    }
    /// Selecting is a preference; it never starts or stops a tunnel.
    func selectManual(_ summary: ManualVPNDraftSummary) {
        guard !operationInFlight else { deferUntilIdle { [self] in selectManual(summary) }; return }
        selectedManualProfile = summary.id
    }
    func selectAndConnectManual(_ summary: ManualVPNDraftSummary) {
        guard summary.protocolKind == .ikev2, !connectionOperation, !tunnel.busy else { notice = "This protocol cannot connect yet, or another operation is pending."; return }
        selectedManualProfile = summary.id; connect()
    }
    private func connectManual(_ summary: ManualVPNDraftSummary) async {
        do {
            let draft = try manualDraft(summary)
            guard draft.protocolKind == .ikev2 else { throw AppIssue(message: "The OpenVPN adapter is pending engine licensing.") }
            try draft.validate()
            guard !requireNativeIPv6 else { throw AppIssue(message: "Native IPv6 policy cannot be guaranteed by this IKEv2 adapter. Use a verified dual-stack WireGuard profile.") }
            await systemDNS.refresh()
            guard systemDNS.enabled != true else { throw AppIssue(message: "Disable DNS-only before connecting IKEv2 to avoid competing DNS configurations.") }
            if tunnel.running {
                await tunnel.disconnect()
                for _ in 0..<100 { guard !Task.isCancelled else { return }; tunnel.refreshStatus(); if !tunnel.running && !tunnel.busy { break }; try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard !Task.isCancelled, !tunnel.running, !tunnel.busy else { throw AppIssue(message: "The previous VPN has not stopped. IKEv2 was not started.") }
            await tunnel.connectIKEv2(draft, strict: strictRouting, allowLAN: tunnel.allowLAN)
            if tunnel.status == .connected || tunnel.status == .connecting { lastUsed[summary.id.uuidString] = Date(); UserDefaults.standard.set(lastUsed, forKey: "profile-last-used") }
        } catch { notice = (error as? AppIssue)?.message ?? "Could not prepare the native IKEv2 configuration." }
    }
    var connectionProtocol: String { tunnel.running ? tunnel.protocolName : dnsOnlyChosen ? "Local DNS" : selectedManualProfile == nil ? "WireGuard" : "IKEv2" }
    var connectionName: String? {
        if tunnel.localDNSRunning || (!tunnel.running && dnsOnlyChosen) { return "DNS only · no VPN" }
        if tunnel.running {
            if tunnel.protocolName == "IKEv2" { return manualDrafts.first { $0.id == tunnel.configuredProfile }?.name }
            return profiles.first { $0.id == tunnel.configuredProfile }?.name
        }
        if let id = selectedManualProfile { return manualDrafts.first { $0.id == id }?.name }
        return active?.name
    }
    func invalidateDNS() { dnsRevision = UUID(); dnsTask?.cancel(); result = "" }
    func testDNS() {
        do {
            let url = try DNSService.endpoint(endpoint)
            guard !testing else { return }
            let name = try DNSService.domain(probeDomain); let blocked = expectNXDOMAIN
            testing = true; result = "Testing \(name) through your selected resolver…"
            let started = Date(); let tunnelStatus = tunnel.statusText; let recordType = probeRecordType
            let revision = dnsRevision
            dnsTask = Task {
                defer { testing = false; dnsTask = nil }
                do {
                    let response = try await DNSService.probe(url, recordType: recordType, domain: name, expectNXDOMAIN: blocked)
                    guard !Task.isCancelled, revision == dnsRevision else { return }
                    result = "Probe passed · \(started.formatted())\n" + response + "\nStarted while: \(tunnelStatus). Resolver filtering and packet path remain unverified."
                } catch {
                    guard !Task.isCancelled, revision == dnsRevision else { return }
                    result = "Probe failed · \(started.formatted()). " + (IPFailure.classify(error).errorDescription ?? "DNS check unavailable.")
                }
            }
        } catch { notice = error.localizedDescription }
    }
    private var dnsLocation: URL { location.deletingLastPathComponent().appendingPathComponent("dns-profiles.json") }
    private func saveDNS(_ items: [DNSProfile]) throws {
        guard storageWritable else { throw AppIssue(message: "Saved storage needs recovery before changes can be made.") }
        try FileManager.default.createDirectory(at: dnsLocation.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(DNSArchive(version: 1, profiles: items)).write(to: dnsLocation, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dnsLocation.path)
    }
    func loadDNS(_ profile: DNSProfile) {
        guard !testing, !tunnel.running, !tunnel.busy else { return }
        do {
            guard let data = try Vault.get("dns-" + profile.id.uuidString), let value = String(data: data, encoding: .utf8) else { throw AppIssue(message: "Resolver credential is missing. Save the endpoint again.") }
            endpoint = try DNSService.endpoint(value).absoluteString; dnsName = profile.name
            bootstrapAddresses = profile.bootstrapAddresses ?? []
            selectedDNS = profile.id; result = ""
            UserDefaults.standard.set(profile.id.uuidString, forKey: "selected-dns")
        } catch { notice = "Could not load the selected resolver. Its endpoint may be missing from Keychain." }
    }
    func newDNS() {
        guard !testing, !tunnel.running, !tunnel.busy else { return }
        selectedDNS = nil; dnsName = ""; endpoint = ""; bootstrapAddresses = []; result = ""
    }
    @discardableResult
    func forgetEndpoint() async -> Bool {
        guard storageWritable else { notice = "Saved storage needs recovery before changes can be made."; return false }
        guard selectedDNS != VayuSetuDNS.id else { notice = "VayuSetu DNS is built in and cannot be removed."; return false }
        guard !testing, !tunnel.running, !tunnel.busy, !connectionOperation, !systemDNS.busy else {
            notice = "Disconnect and finish pending operations before removing the resolver."
            return false
        }
        // Keep other screens from starting a connection while preferences and
        // Keychain are being changed. The editor dismisses only after success.
        connectionOperation = true; defer { connectionOperation = false }
        do {
            try await tunnel.removeConfiguration()
            if let id = selectedDNS {
                let account = "dns-" + id.uuidString
                let old = try Vault.get(account)
                try Vault.delete(account)
                let items = dnsProfiles.filter { $0.id != id }
                do { try saveDNS(items) } catch { if let old { try? Vault.put(old, account: account) }; throw error }
                dnsProfiles = items
            }
            try Vault.delete("control-d-endpoint")
            newDNS(); UserDefaults.standard.removeObject(forKey: "selected-dns")
            notice = "Selected resolver and saved VPN configuration removed. Other profiles remain available."
            return true
        } catch { notice = "Could not remove the resolver and saved VPN configuration."; return false }
    }
    func saveEndpoint() {
        guard storageWritable else { notice = "Saved storage needs recovery before changes can be made."; return }
        guard !testing, !tunnel.running, !tunnel.busy else { return }
        do {
            let url = try DNSService.endpoint(endpoint)
            let bootstrap = bootstrapAddresses.isEmpty ? [] : try ResolverBootstrap.validated(bootstrapAddresses)
            let name = dnsName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else { throw AppIssue(message: "Use a resolver name between 1 and 80 characters.") }
            let id = selectedDNS ?? UUID(); let account = "dns-" + id.uuidString
            let old = try Vault.get(account)
            try Vault.put(Data(url.absoluteString.utf8), account: account)
            var items = dnsProfiles
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].name = name; items[index].bootstrapAddresses = bootstrap }
            else { items.append(DNSProfile(id: id, name: name, bootstrapAddresses: bootstrap)) }
            do { try saveDNS(items) } catch { if let old { try? Vault.put(old, account: account) } else { try? Vault.delete(account) }; throw error }
            dnsProfiles = items; selectedDNS = id; endpoint = url.absoluteString
            UserDefaults.standard.set(id.uuidString, forKey: "selected-dns")
            notice = "Resolver profile saved. Endpoint is stored in Keychain."
        } catch { notice = error is AppIssue ? error.localizedDescription : "Could not save resolver profile." }
    }
    func configuration(for profile: SavedProfile) throws -> String {
        guard let data = try Vault.get(profile.id.uuidString), let value = String(data: data, encoding: .utf8) else { throw AppIssue(message: "Profile keys are missing from Keychain.") }
        return value
    }
    func saveConfiguration(_ text: String, name: String, replacing profile: SavedProfile? = nil) -> Bool {
        guard storageWritable else { notice = "Saved storage needs recovery before changes can be made."; return false }
        guard !profileInUse(profile), !tunnel.busy else { notice = "This profile is connected. Disconnect it first, or save a copy under a new name."; return false }
        do {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else { throw AppIssue(message: "Use a name between 1 and 80 characters.") }
            guard text.utf8.count <= 128_000 else { throw AppIssue(message: "Configuration must be smaller than 128 KB.") }
            let summary = try ProfileParser.parse(text)
            let id = profile?.id ?? UUID()
            let item = SavedProfile(id: id, name: name, addresses: summary.addresses, dns: summary.dns, endpoints: summary.endpoints, peerCount: summary.peerCount, fullTunnel: summary.fullTunnel, created: profile?.created ?? Date())
            var items = profiles
            if let index = items.firstIndex(where: { $0.id == id }) { items[index] = item } else { items.append(item) }
            let old = try Vault.get(id.uuidString)
            try Vault.put(Data(text.utf8), account: id.uuidString)
            do { try save(items) } catch { if let old { try? Vault.put(old, account: id.uuidString) } else { try? Vault.delete(id.uuidString) }; throw error }
            profiles = items; selected = id; selectedManualProfile = nil
            notice = "Profile saved in Keychain. Reconnect to apply changes."; return true
        } catch { notice = error is AppIssue ? error.localizedDescription : "Could not save the configuration."; return false }
    }
    func duplicate(_ profile: SavedProfile) {
        do { _ = saveConfiguration(try configuration(for: profile), name: String(profile.name.prefix(70)) + " copy") }
        catch { notice = "Could not duplicate this profile." }
    }
    func redactedConfiguration(_ profile: SavedProfile) -> String {
        do {
            return ProfileExport.redacted(try configuration(for: profile))
        } catch { return "Configuration unavailable." }
    }
}


extension AppStore {
    private var restoreJournalURL: URL { location.deletingLastPathComponent().appendingPathComponent("restore-journal.json") }
    private func recoverInterruptedRestore() throws {
        try RestoreRecovery.rollback(journalURL: restoreJournalURL, profilesURL: location, dnsURL: dnsLocation, nativeURL: manualDraftURL, deleteAccount: Vault.delete)
    }
    func backupSnapshot(includeCredentials: Bool = false) throws -> ConfigurationBackup {
        if !includeCredentials {
            var backup = ConfigurationBackup(version: 2, created: Date(), vpn: [], dns: [])
            backup.includesCredentials = false
            backup.metadata = profiles.map { .init(name: $0.name, kind: "vpn") } + dnsProfiles.filter { $0.id != VayuSetuDNS.id }.map { .init(name: $0.name, kind: "dns") } + manualDrafts.filter { $0.protocolKind == .ikev2 }.map { .init(name: $0.name, kind: "ikev2") }
            backup.rules = filtering.configuration.rules.map { .init(domain: $0.domain, action: $0.action.rawValue, scope: $0.scope.rawValue, enabled: $0.enabled != false) }
            backup.lists = filtering.configuration.subscriptions.map { .init(name: $0.name, url: nil) }
            return backup
        }
        let vpn = try profiles.map { ConfigurationBackup.VPN(name: $0.name, configuration: try configuration(for: $0)) }
        let dns = try dnsProfiles.filter { $0.id != VayuSetuDNS.id }.map { profile -> ConfigurationBackup.DNS in
            guard let data = try Vault.get("dns-" + profile.id.uuidString), let value = String(data: data, encoding: .utf8) else { throw AppIssue(message: "A resolver endpoint is missing from Keychain.") }
            return ConfigurationBackup.DNS(name: profile.name, endpoint: value, bootstrapAddresses: profile.bootstrapAddresses)
        }
        var backup = ConfigurationBackup(version: 2, created: Date(), vpn: vpn, dns: dns)
        backup.nativeIKEv2 = try manualDrafts.filter { $0.protocolKind == .ikev2 }.map { try manualDraft($0) }
        backup.includesCredentials = true
        backup.rules = filtering.configuration.rules.map { .init(domain: $0.domain, action: $0.action.rawValue, scope: $0.scope.rawValue, enabled: $0.enabled != false) }
        backup.lists = filtering.configuration.subscriptions.map { .init(name: $0.name, url: $0.url == "Local file" ? nil : $0.url) }
        return backup
    }
    func restoreBackup(_ backup: ConfigurationBackup) throws {
        guard storageWritable, !testing, !tunnel.running, !tunnel.busy else { throw AppIssue(message: "Disconnect and finish testing before restoring.") }
        try backup.validate()
        guard profiles.count + backup.vpn.count + (backup.metadata ?? []).filter({ $0.kind == "vpn" }).count <= 50, dnsProfiles.count + backup.dns.count + (backup.metadata ?? []).filter({ $0.kind == "dns" }).count <= 50 else { throw AppIssue(message: "Restore would exceed 50 VPN or DNS profiles.") }
        guard manualDraftStorageWritable, manualDrafts.count + (backup.nativeIKEv2?.count ?? 0) + (backup.metadata ?? []).filter({ $0.kind == "ikev2" }).count <= 100 else { throw AppIssue(message: "Restore exceeds the native profile limit or its storage needs recovery.") }
        let nativeIDs = (backup.nativeIKEv2 ?? []).map { _ in UUID() }
        let vpnIDs = backup.vpn.map { _ in UUID() }; let dnsIDs = backup.dns.map { _ in UUID() }
        let accounts = vpnIDs.map(\.uuidString) + dnsIDs.map { "dns-" + $0.uuidString } + nativeIDs.map { "manual-vpn-" + $0.uuidString }
        let journal = RestoreJournal(version: 2,
            profiles: FileManager.default.fileExists(atPath: location.path) ? try LocalFiles.read(location, maximum: 2_000_000) : nil,
            dns: FileManager.default.fileExists(atPath: dnsLocation.path) ? try LocalFiles.read(dnsLocation, maximum: 256_000) : nil,
            nativeProfiles: FileManager.default.fileExists(atPath: manualDraftURL.path) ? try LocalFiles.read(manualDraftURL, maximum: 128_000) : nil,
            accounts: accounts)
        try LocalFiles.write(JSONEncoder().encode(journal), to: restoreJournalURL)
        var addedVPN: [SavedProfile] = []; var addedDNS: [DNSProfile] = []; var addedNative: [ManualVPNDraftSummary] = []
        do {
            // New IDs make restore additive: existing profile credentials are never overwritten.
            for (item, id) in zip(backup.vpn, vpnIDs) {
                let summary = try ProfileParser.parse(item.configuration)
                try Vault.put(Data(item.configuration.utf8), account: id.uuidString)
                addedVPN.append(SavedProfile(id: id, name: item.name, addresses: summary.addresses, dns: summary.dns, endpoints: summary.endpoints, peerCount: summary.peerCount, fullTunnel: summary.fullTunnel, created: Date()))
            }
            for (item, id) in zip(backup.dns, dnsIDs) {
                try Vault.put(Data(item.endpoint.utf8), account: "dns-" + id.uuidString)
                addedDNS.append(DNSProfile(id: id, name: item.name, bootstrapAddresses: item.bootstrapAddresses))
            }
            for (value, id) in zip(backup.nativeIKEv2 ?? [], nativeIDs) {
                var imported = value; imported.id = id
                try Vault.put(JSONEncoder().encode(imported), account: "manual-vpn-" + id.uuidString)
                addedNative.append(ManualVPNDraftSummary(id: id, name: imported.name, protocolKind: .ikev2))
            }
            for metadata in backup.metadata ?? [] {
                // Fresh identities cannot accidentally resolve to any existing Keychain credentials.
                if metadata.kind == "vpn" { addedVPN.append(SavedProfile(id: UUID(), name: metadata.name, addresses: [], dns: [], endpoints: [], peerCount: 0, fullTunnel: false, created: Date())) }
                else if metadata.kind == "ikev2" { addedNative.append(ManualVPNDraftSummary(id: UUID(), name: metadata.name, protocolKind: .ikev2)) }
                else { addedDNS.append(DNSProfile(id: UUID(), name: metadata.name)) }
            }
            try save(profiles + addedVPN); try saveDNS(dnsProfiles + addedDNS)
            try LocalFiles.write(JSONEncoder().encode(ManualVPNDraftArchive(version: 1, drafts: manualDrafts + addedNative)), to: manualDraftURL)
            // Removing the journal commits both metadata files. Startup rolls back any interrupted transaction.
            try FileManager.default.removeItem(at: restoreJournalURL)
            profiles += addedVPN; dnsProfiles += addedDNS; manualDrafts += addedNative
            notice = "Backup restored. Existing profiles were preserved. Select a profile and resolver to connect."
        } catch {
            do { try recoverInterruptedRestore() }
            catch { storageWritable = false; throw AppIssue(message: "Restore rollback failed. Saved files and credentials have been preserved; restart before editing.") }
            throw AppIssue(message: "Restore failed. Existing profiles were preserved.")
        }
    }
}

// MARK: - Protection coordinator (ADR-011)

/// What the user switched on. These are requests; observed state is derived from the tunnels and the OS.
struct ProtectionSelection: Codable, Equatable { var vpnEnabled = false; var dnsEnabled = false; var safariAdblockEnabled = false }
/// The last network combination that was running, restored by one tap of the master power button.
struct SavedNetworkMode: Codable, Equatable { var vpn: Bool; var dns: Bool }
struct DNSVerification: Equatable { let date: Date; let passed: Bool; let blockedChecked: Bool; let detail: String }
enum ProtectionPill { case vpn, dns, adblock }
enum PillState: Equatable { case off, active, pending, limited, failed }
enum PowerTone { case off, dnsOnly, vpnOnly, vpnWithDNS, busy, error }
/// A switch that would weaken protection that is running now. Nothing changes until the user confirms.
struct ProtectionDecision: Identifiable {
    let id = UUID(); let target: ProtectionSelection; let message: String
    var title = "Change protection?"; var confirmTitle = "Continue"
    /// When set, the user may choose to stop being asked again for this profile.
    var ackKey: String? = nil
}

extension AppStore {
    /// Status notices are momentary: they clear after a while unless something newer replaced them.
    func scheduleNoticeClear() {
        noticeClear?.cancel()
        guard !protectionNotice.isEmpty else { return }
        let shown = protectionNotice
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.protectionNotice == shown else { return }
            self.protectionNotice = ""
        }
    }
    func persistSelection() {
        if let data = try? JSONEncoder().encode(selection) { UserDefaults.standard.set(data, forKey: "protection-selection") }
        if let saved = savedNetwork, let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: "protection-last-network") }
    }
    func restoreSelection() {
        if let data = UserDefaults.standard.data(forKey: "protection-selection"), let value = try? JSONDecoder().decode(ProtectionSelection.self, from: data) { selection = value }
        if let data = UserDefaults.standard.data(forKey: "protection-last-network"), let value = try? JSONDecoder().decode(SavedNetworkMode.self, from: data) { savedNetwork = value }
        selection.safariAdblockEnabled = filtering.configuration.safariDesired
    }

    // MARK: Observed state. Requests never produce a green pill by themselves.
    var currentOwner: TunnelOwner {
        guard tunnel.running else { return .idle }
        if tunnel.localDNSRunning { return .localDNS }
        return .vpn(tunnel.protocolName == "IKEv2" ? .ikev2 : .wireGuard)
    }
    var selectedVPNKind: VPNKind? {
        if let id = selectedManualProfile { return manualDrafts.first { $0.id == id }.map { $0.protocolKind == .ikev2 ? VPNKind.ikev2 : VPNKind.openVPN } }
        return active == nil ? nil : .wireGuard
    }
    func request(for target: ProtectionSelection) -> ProtectionRequest {
        ProtectionRequest(vpn: target.vpnEnabled ? selectedVPNKind : nil, dns: target.dnsEnabled, dnsFiltering: target.dnsEnabled && isVayuSetuDNSSelected,
                          safari: target.safariAdblockEnabled, strictDNS: true, resolverConfigured: !endpoint.isEmpty)
    }
    var networkActive: Bool { tunnel.running || tunnel.busy || protectionBusy }
    var vpnPill: PillState {
        if tunnel.running && !tunnel.localDNSRunning { return tunnel.status == .connected ? .active : .pending }
        if protectionBusy && selection.vpnEnabled { return .pending }
        if selection.vpnEnabled && tunnel.stage == .failed { return .failed }
        return .off
    }
    var dnsPill: PillState {
        let requested = selection.dnsEnabled || tunnel.localDNSRunning
        if tunnel.running && requested {
            if tunnel.status != .connected { return .pending }
            switch protection(.dns).observed {
            case .active: return .active
            case .limited: return .limited
            case .error, .needsAttention: return .failed
            default: return .pending     // configured, not yet confirmed by observed queries
            }
        }
        if requested && protectionBusy { return .pending }
        if requested && tunnel.stage == .failed { return .failed }
        return .off
    }
    var adblockPill: PillState {
        guard selection.safariAdblockEnabled || filtering.configuration.safariDesired else { return .off }
        if filtering.busy { return .pending }
        switch filtering.snapshot().observed {
        case .active: return .active
        case .limited: return .limited
        case .error: return .failed
        default: return .pending         // requested, but Safari's own switch is not confirmed on
        }
    }
    var observedMode: OperatingMode { .resolve(vpn: vpnPill != .off, dns: dnsPill != .off, safari: adblockPill != .off) }
    var powerTone: PowerTone {
        if protectionBusy || tunnel.busy || [.connecting, .reasserting, .disconnecting].contains(tunnel.status) { return .busy }
        if tunnel.stage == .failed && (selection.vpnEnabled || selection.dnsEnabled) { return .error }
        guard tunnel.running else { return .off }
        if tunnel.localDNSRunning { return .dnsOnly }
        return dnsPill != .off ? .vpnWithDNS : .vpnOnly
    }
    /// "Encrypted DNS" is shown only once the DNS path has produced evidence; otherwise the state is spelled out.
    var protectionSubtitle: String {
        var parts: [String] = []
        if tunnel.running && !tunnel.localDNSRunning { parts.append(connectionName ?? "VPN"); parts.append(tunnel.protocolName) }
        let resolver = dnsName.isEmpty ? "DNS" : dnsName
        switch dnsPill {
        case .active: parts.append(tunnel.localDNSRunning ? resolver + " · verified" : "Encrypted DNS")
        case .pending: parts.append(tunnel.localDNSRunning ? resolver + " · not yet verified" : "DNS not yet verified")
        case .limited: parts.append("DNS limited")
        case .failed: parts.append("DNS failed")
        case .off: break
        }
        if parts.isEmpty { return adblockPill != .off ? "Safari adblocking" : "Choose a mode or tap power to connect." }
        return parts.joined(separator: " · ")
    }
    /// Stores the next start-up mode without starting anything.
    /// The network mode the power button starts next, for display in Settings and DNS.
    var savedModeTitle: String { savedNetwork.map { OperatingMode.resolve(vpn: $0.vpn, dns: $0.dns, safari: false).title } ?? "Not chosen yet" }
    func saveMode(vpn: Bool, dns: Bool) {
        powerModeChosen = true
        savedNetwork = SavedNetworkMode(vpn: vpn, dns: dns); persistSelection()
    }

    /// Green needs evidence: queries answered by our own runtime, or a passed end-to-end check. A failed check says so.
    fileprivate func localDNSSnapshot(now: Date) -> ProtectionSnapshot {
        let sample = tunnel.observedCounters()
        let answered = (tunnel.stats?.dnsCounters?.answered ?? 0) > 0 && sample != nil
        var observedAt = sample?.date ?? tunnel.statusObservedAt
        var state: ObservedState = .enabledNotVerified
        var reason = "The DNS tunnel is running. No query has been answered yet."
        if answered { state = .active; reason = "The DNS tunnel answered queries from this device. Apps with their own DNS bypass it." }
        if let check = dnsVerification, now.timeIntervalSince(check.date) < 600 {
            if check.passed { state = .active; observedAt = max(observedAt ?? check.date, check.date); reason = check.detail }
            else if !answered { state = .needsAttention; observedAt = check.date; reason = check.detail }
        }
        return ProtectionSnapshot(.dns, desired: true, state: state, source: .extensionAcknowledgement, at: observedAt, reason: reason)
    }
    /// A well-known ad/tracker name that the enabled lists really cover, so the blocked-name check is meaningful.
    fileprivate func blockedSampleName() -> String? {
        let rules = filtering.configuration.effective
        for name in ["pagead2.googlesyndication.com", "doubleclick.net", "www.google-analytics.com", "googleadservices.com"] {
            if let match = try? RuleEngine.match(name, rules: rules), match.rule.action == .block { return name }
        }
        return rules.first(where: { $0.action == .block && $0.scope == .domainAndSubdomains })?.domain
    }
    /// End-to-end check through the device's own DNS path: a normal name must resolve, and (with VayuSetu lists) a listed name must not exist.
    /// It sends at most three small queries, on connect and when the user asks; it never changes any setting.
    func verifyLocalDNS() async {
        let hostsFilter = tunnel.localDNSRunning || (tunnel.protocolName == "WireGuard" && tunnel.stats?.dnsCounters != nil)
        guard hostsFilter, tunnel.status == .connected, !dnsVerifying else { return }
        dnsVerifying = true; defer { dnsVerifying = false }
        var passed = true; var notes: [String] = []; var blockedChecked = false
        do {
            let (id, reply) = try await LocalDNSProbe.exchange(domain: "example.com")
            _ = try DNSService.validateReply(reply, id: id, domain: "example.com")
            notes.append("A normal name resolved through the tunnel.")
        } catch { passed = false; notes.append("A normal name did not resolve through the tunnel.") }
        if isVayuSetuDNSSelected, let sample = blockedSampleName() {
            do {
                let (_, reply) = try await LocalDNSProbe.exchange(domain: sample)
                if reply.count >= 12, reply[3] & 0x0f == 3 { blockedChecked = true; notes.append("A listed ad/tracker name was blocked by the VayuSetu lists.") }
                else { passed = false; notes.append("A listed ad/tracker name was not blocked. The lists may not have reached the tunnel.") }
            } catch { passed = false; notes.append("The blocked-name check got no answer.") }
        }
        dnsVerification = DNSVerification(date: Date(), passed: passed, blockedChecked: blockedChecked, detail: notes.joined(separator: " "))
        filtering.record(passed ? "DNS verification passed" : "DNS verification failed")
    }
    /// "Run Check": reports reachability of the selected resolver and, where VayuSetu hosts the DNS path, the end-to-end result.
    func runDNSCheck() async {
        guard !dnsChecking else { return }
        dnsChecking = true; defer { dnsChecking = false }
        var lines: [String] = []
        if let url = try? DNSService.endpoint(endpoint) {
            do {
                let started = ContinuousClock.now
                _ = try await DNSService.probe(url)
                let elapsed = started.duration(to: .now).components
                lines.append("Resolver reachable over \(DNSService.transport(endpoint)) · \(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000) ms.")
            } catch { lines.append("Resolver not reachable: " + (IPFailure.classify(error).errorDescription ?? "request failed") + ".") }
        } else { lines.append("No resolver is selected.") }
        // WireGuard with a plain selected resolver has no local runtime to ask; the existing resolver check supplies the evidence.
        if tunnel.running, tunnel.status == .connected, tunnel.protocolName == "WireGuard", tunnel.stats?.dnsCounters == nil, selection.dnsEnabled, !endpoint.isEmpty {
            tunnel.verifyConnection(resolver: endpoint, includeIPProbes: false)
            for _ in 0..<60 where tunnel.checkingHealth || tunnel.evidence.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            if let evidence = tunnel.evidence.first(where: { $0.name == "Resolver response" }) {
                lines.append(evidence.verdict == .passed ? "The selected resolver answered through the VPN." : "The selected resolver did not answer through the VPN.")
            }
        }
        await verifyLocalDNS()
        if tunnel.running && tunnel.protocolName == "IKEv2" {
            lines.append("This is an IKEv2 connection: its DNS comes from the VPN server, so use of your resolver cannot be verified from here.")
        } else if !tunnel.running {
            lines.append("No tunnel is running, so the device DNS path was not tested.")
        } else if let check = dnsVerification {
            lines.append(check.detail)
        } else if tunnel.protocolName == "WireGuard", tunnel.stats?.dnsCounters == nil {
            lines.append("This VPN uses your resolver without VayuSetu’s local runtime, so only resolver reachability is checked.")
        } else {
            lines.append("The device DNS path could not be tested for this connection.")
        }
        dnsCheckLines = lines; dnsCheckDate = Date()
    }
    /// After a start request: wait for the tunnel, then verify (a few spaced tries while the path settles).
    fileprivate func verifyAfterStart() async {
        for _ in 0..<40 { if tunnel.status == .connected { break }; try? await Task.sleep(for: .milliseconds(500)) }
        guard tunnel.status == .connected else { return }
        if tunnel.protocolName == "WireGuard", tunnel.stats?.dnsCounters == nil, selection.dnsEnabled, !endpoint.isEmpty {
            // Resolver-only VPN + DNS: the existing resolver check supplies the evidence; no public-IP probes.
            tunnel.verifyConnection(resolver: endpoint, includeIPProbes: false); return
        }
        for attempt in 0..<3 {
            try? await Task.sleep(for: .seconds(attempt == 0 ? 2 : 3))
            tunnel.refreshStats()
            await verifyLocalDNS()
            if dnsVerification?.passed == true { return }
        }
    }

    // MARK: Actions
    private func stopCurrentTunnel() async -> Bool {
        guard tunnel.running || tunnel.busy else { return true }
        await tunnel.disconnect()
        for _ in 0..<150 {
            tunnel.refreshStatus()
            if !tunnel.running && !tunnel.busy { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// The single path every control uses. It plans first, executes the plan's steps in order, and reports honest limits.
    @discardableResult
    func applySelection(_ requested: ProtectionSelection, confirmed: Bool = false) async -> String {
        // Wait for a change that is still running (latest tap wins) rather than rejecting the new one.
        applyGeneration &+= 1; let generation = applyGeneration
        var waited = 0
        while operationInFlight && waited < 120 { try? await Task.sleep(for: .milliseconds(500)); waited += 1; if generation != applyGeneration { return "" } }
        guard !operationInFlight else { return "The previous change is taking long. Try again in a moment." }
        let previous = selection
        // A VPN needs an explicit profile; with exactly one saved profile it is chosen for the user.
        if requested.vpnEnabled && selectedVPNKind == nil {
            if profiles.count == 1, manualDrafts.isEmpty, let only = profiles.first { selected = only.id; selectedManualProfile = nil }
            else { return profiles.isEmpty && manualDrafts.isEmpty ? "Add a VPN profile first." : "Choose a VPN profile in Profiles first." }
        }
        // WireGuard hosts the DNS filter at start-up, so changing the DNS control while it runs needs a reconnect.
        let integratedDNSChanged = currentOwner == .vpn(.wireGuard) && previous.dnsEnabled != requested.dnsEnabled
        var safariGuidance = ""
        let plan: ProtectionPlan
        switch ProtectionPlanner.plan(request(for: requested), current: currentOwner, safariOn: filtering.configuration.safariDesired, resolverChanged: integratedDNSChanged) {
        case .failure(let issue): return issue.message
        case .success(let value): plan = value
        }
        // Heads-up before connecting IKEv2 when the user would expect DNS filtering: iOS runs IKEv2 and VayuSetu cannot filter it.
        if !confirmed, plan.owner == .vpn(.ikev2), plan.steps.contains(where: { if case .startVPN = $0 { return true }; return false }) {
            let key = "ikev2-headsup-" + (selectedManualProfile?.uuidString ?? "profile")
            let expectsDNS = requested.dnsEnabled || filtering.configuration.subscriptions.contains { $0.enabled }
            if expectsDNS && !UserDefaults.standard.bool(forKey: key) {
                let resolver = dnsName.isEmpty ? "your DNS resolver" : dnsName
                pendingDecision = ProtectionDecision(target: requested,
                    message: "iOS runs IKEv2 itself, so VayuSetu cannot apply \(resolver) or its filter lists on this connection. DNS comes from the VPN server, and ads are only blocked if that server uses a filtering DNS. For local filtering, use a WireGuard profile, or run DNS Only without the VPN. Safari adblocking still works.",
                    title: "IKEv2 and DNS filtering", confirmTitle: "Connect Anyway", ackKey: key)
                return ""
            }
        }
        // Never silently trade away DNS protection that is running now.
        var weakensDNS = plan.dnsPath == .vpnServerDNS
        if case .unavailable = plan.filtering, plan.request.dnsFiltering { weakensDNS = true }
        if !confirmed, dnsPill != .off, plan.request.dns, weakensDNS {
            pendingDecision = ProtectionDecision(target: requested, message: plan.limitations.joined(separator: " ") + " Your current DNS protection will stop working as it does now.")
            return ""
        }
        protectionBusy = true; connectionOperation = true
        defer { protectionBusy = false; connectionOperation = false; Task { await reconcileNetworkState() } }
        selection = requested; persistSelection()
        // The old iOS DNS profile never coexists with the local tunnel; remove it quietly if an earlier version saved one.
        if systemDNS.hasSavedConfiguration { _ = await systemDNS.disable() }
        for step in plan.steps {
            switch step {
            case .stopTunnel:
                guard await stopCurrentTunnel() else { return "The current tunnel did not stop. Nothing was changed." }
            case .startLocalDNS: await startLocalDNS()
            case .startVPN: await connectSelected()
            case .restartForResolverChange:
                guard await stopCurrentTunnel() else { return "The current tunnel did not stop. Nothing was changed." }
                if plan.owner == .localDNS { await startLocalDNS() } else { await connectSelected() }
            case .enableSafari:
                await filtering.setSafari(true)
                // Reloading rules never switches Safari's own setting on; say so instead of implying it did.
                await filtering.refresh()
                if filtering.enabled != true { safariGuidance = "Safari adblocking needs one more step: open Settings → Apps → Safari → Extensions and allow VayuSetu." }
            case .disableSafari: await filtering.setSafari(false)
            }
        }
        if requested.vpnEnabled || requested.dnsEnabled { savedNetwork = SavedNetworkMode(vpn: requested.vpnEnabled, dns: requested.dnsEnabled); persistSelection() }
        if requested.dnsEnabled, plan.owner != .idle { dnsVerification = nil; Task { [self] in await verifyAfterStart() } }
        var parts: [String] = []
        if !safariGuidance.isEmpty { parts.append(safariGuidance); safariGuidance = "" }
        if plan.protectionGap { parts.append("Switching briefly interrupted protection.") }
        parts.append(contentsOf: plan.limitations)
        if tunnel.stage == .failed, !tunnel.message.isEmpty { parts.append(tunnel.message) }
        return parts.joined(separator: " ")
    }
    /// What is really running, expressed as a selection. A control changes only its own part of this; the others are never
    /// taken from an old saved preference, which could start or stop a tunnel the user did not touch.
    var observedSelection: ProtectionSelection {
        var observed = selection
        observed.vpnEnabled = tunnel.running && !tunnel.localDNSRunning
        observed.dnsEnabled = tunnel.localDNSRunning || (observed.vpnEnabled && selection.dnsEnabled)
        observed.safariAdblockEnabled = filtering.configuration.safariDesired
        return observed
    }
    func confirmPendingDecision(remember: Bool = false) {
        guard let decision = pendingDecision else { return }
        pendingDecision = nil
        if remember, let key = decision.ackKey { UserDefaults.standard.set(true, forKey: key) }
        Task { [self] in protectionNotice = await applySelection(decision.target, confirmed: true) }
    }
    /// Master power. Returns true when the mode selector must be shown (no network mode has been used yet).
    func powerTapped() async -> Bool {
        if networkActive {
            var off = observedSelection; off.vpnEnabled = false; off.dnsEnabled = false
            protectionNotice = "Turning network protection off…"
            protectionNotice = await applySelection(off, confirmed: true)
            return false
        }
        guard powerModeChosen, let saved = savedNetwork else { return true }
        var on = observedSelection; on.vpnEnabled = saved.vpn; on.dnsEnabled = saved.dns
        protectionNotice = "Starting " + OperatingMode.resolve(vpn: saved.vpn, dns: saved.dns, safari: false).title + "… Touch and hold the button to change mode."
        protectionNotice = await applySelection(on)
        return false
    }
    /// Turns the VPN and DNS protection off together (Safari adblocking is separate). Used by Disconnect buttons.
    func powerOffNetwork() async {
        guard networkActive else { return }
        var off = observedSelection; off.vpnEnabled = false; off.dnsEnabled = false
        protectionNotice = await applySelection(off, confirmed: true)
    }
    func chooseMode(vpn: Bool, dns: Bool, safari: Bool? = nil) async {
        powerModeChosen = true
        var next = observedSelection; next.vpnEnabled = vpn; next.dnsEnabled = dns
        if let safari { next.safariAdblockEnabled = safari }
        protectionNotice = await applySelection(next)
    }
    func togglePill(_ pill: ProtectionPill) async {
        var next = observedSelection
        switch pill {
        case .vpn: next.vpnEnabled = vpnPill == .off
        case .dns: next.dnsEnabled = dnsPill == .off
        case .adblock: next.safariAdblockEnabled = adblockPill == .off
        }
        protectionNotice = await applySelection(next)
    }
}

extension AppStore {
    func recoverSavedConfiguration() {
        guard storageWritable, !testing, !tunnel.running, !tunnel.busy else { notice = "Disconnect before recovering this app's saved configuration."; return }
        do {
            // Never overwrite readable metadata, even if it is intentionally empty.
            let recoverVPN = !FileManager.default.fileExists(atPath: location.path)
            let recoverDNS = !FileManager.default.fileExists(atPath: dnsLocation.path)
            guard recoverVPN || recoverDNS else { notice = "Saved metadata is already present; no changes made."; return }
            var vpn = profiles; var dns = dnsProfiles
            for (account, data) in try Vault.recoverableConfigurations() {
                guard let text = String(data: data, encoding: .utf8) else { continue }
                if account.hasPrefix("dns-"), recoverDNS, let id = UUID(uuidString: String(account.dropFirst(4))),
                   !dns.contains(where: { $0.id == id }), (try? DNSService.endpoint(text)) != nil {
                    let provider = DNSProviderSite.selected(endpoint: text)?.rawValue ?? "resolver"
                    dns.append(DNSProfile(id: id, name: "Recovered " + provider))
                } else if recoverVPN, let id = UUID(uuidString: account), !vpn.contains(where: { $0.id == id }),
                          let summary = try? ProfileParser.parse(text) {
                    vpn.append(SavedProfile(id: id, name: "Recovered WireGuard " + String(vpn.count + 1), addresses: summary.addresses, dns: summary.dns, endpoints: summary.endpoints, peerCount: summary.peerCount, fullTunnel: summary.fullTunnel, created: Date()))
                }
            }
            guard vpn.count <= 50, dns.count <= 50 else { throw AppIssue(message: "Recovered configuration exceeds the profile limit.") }
            guard vpn.count > profiles.count || dns.count > dnsProfiles.count else { notice = "No recoverable profile credentials were found. Reimport your VPN configuration and resolver endpoint."; return }
            let journal = RestoreJournal(version: 1,
                profiles: FileManager.default.fileExists(atPath: location.path) ? try LocalFiles.read(location, maximum: 2_000_000) : nil,
                dns: FileManager.default.fileExists(atPath: dnsLocation.path) ? try LocalFiles.read(dnsLocation, maximum: 256_000) : nil,
                accounts: [])
            try LocalFiles.write(JSONEncoder().encode(journal), to: restoreJournalURL)
            do { if recoverVPN { try save(vpn) }; if recoverDNS { try saveDNS(dns) }; try FileManager.default.removeItem(at: restoreJournalURL) }
            catch { try recoverInterruptedRestore(); throw error }
            profiles = vpn; dnsProfiles = dns
            if !profiles.contains(where: { $0.id == selected }) { selected = profiles.first?.id }
            if let resolver = dnsProfiles.first(where: { $0.id == selectedDNS }) ?? dnsProfiles.first { loadDNS(resolver) }
            notice = "Recovered saved metadata from this app's Keychain. No connection started. Original names may be unavailable."
            filtering.record("Owned Keychain configuration metadata recovered; no connection started")
        } catch { notice = "Saved configuration could not be recovered. Existing credentials were preserved." }
    }
}

