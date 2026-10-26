import Foundation
import SystemExtensions
import Combine
import VayuSetuCore

@MainActor final class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var message = ""
    @Published var requesting = false
    @Published var activated = false
    /// Everything waiting for the extension to be ready. A tap that arrives while a request is already pending is kept, not dropped.
    private var completions: [() -> Void] = []
    /// Called with the reason when the request ends without the extension becoming ready, so whatever was waiting on it can stop waiting and say why.
    private var failureHandlers: [(String) -> Void] = []
    /// Durable record of what happened to an install request: set by the app to write into the connection log.
    var report: ((String, ConnectionEvent.Severity) -> Void)?
    private var watch = InstallWatch()
    private var filterWatch = InstallWatch()
    private var watcher: Task<Void, Never>?
    // The network filter is a second system extension, activated on its own.
    @Published var filterRequesting = false
    @Published var filterActivated = false
    @Published var filterMessage = ""
    private var filterCompletion: (() -> Void)?
    /// What macOS has installed against what this app carries, so an out-of-date component is seen and repaired, not guessed at.
    struct Component: Identifiable, Equatable {
        var id: String
        var name: String
        var installed: String?       // nil: not installed
        var bundled: String?
        var enabled: Bool
        var waitingForApproval: Bool
        var outdated: Bool { guard let installed, let bundled else { return false }; return (Int(installed) ?? 0) < (Int(bundled) ?? 0) }
        var summary: String {
            if waitingForApproval { return "Waiting for your approval in System Settings" }
            guard let installed else { return bundled == nil ? "Not part of this build" : "Not installed yet" }
            if outdated { return "Version \(installed) is installed; this app carries \(bundled ?? "?")" }
            return enabled ? "Installed and running (version \(installed))" : "Installed but switched off in System Settings"
        }
    }
    @Published var components: [Component] = []
    @Published var updating = false
    private var found: [String: [OSSystemExtensionProperties]] = [:]
    private var pendingChecks = 0
    var needsAttention: Bool { components.contains { $0.outdated || $0.waitingForApproval || ($0.installed != nil && !$0.enabled) } }
    private var tunnelIdentifier: String { (Bundle.main.bundleIdentifier ?? "app.vayusetu.macos") + ".tunnel" }
    private func bundledVersion(_ identifier: String) -> String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(identifier).systemextension/Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleVersion"] as? String)
    }
    /// Asks macOS which versions of the VPN extension and the network filter are installed. Safe to call at any time; it changes nothing.
    func checkComponents() {
        guard pendingChecks == 0 else { return }
        found = [:]
        let ids = [tunnelIdentifier, Self.filterIdentifier]
        pendingChecks = ids.count
        for id in ids {
            let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: id, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }
    private func finishCheck(_ id: String, _ properties: [OSSystemExtensionProperties]) {
        found[id] = properties; pendingChecks = max(0, pendingChecks - 1)
        guard pendingChecks == 0 else { return }
        func component(_ id: String, _ name: String) -> Component {
            let live = (found[id] ?? []).filter { !$0.isUninstalling }
            let best = live.max { (Int($0.bundleVersion) ?? 0) < (Int($1.bundleVersion) ?? 0) }
            return Component(id: id, name: name, installed: best?.bundleVersion, bundled: bundledVersion(id), enabled: best?.isEnabled ?? false, waitingForApproval: live.contains { $0.isAwaitingUserApproval })
        }
        let all = [component(tunnelIdentifier, "VPN and DNS tunnel"), component(Self.filterIdentifier, "Network filter")]
        // An extension that was there and is not any more (macOS removes one that fails validation) is a failure to report, not a silent change.
        for now in all {
            guard let before = components.first(where: { $0.id == now.id }) else { continue }
            let uninstalling = (found[now.id] ?? []).contains { $0.isUninstalling } && now.installed == nil
            if let note = ExtensionPresence.removalNote(previouslyInstalled: before.installed, nowInstalled: now.installed, uninstalling: uninstalling) {
                report?(now.name + ": " + note, .error)
            }
        }
        components = all.filter { $0.bundled != nil }
        // A launch can find an extension that was activated by a previous
        // process. Reconcile that system state into the published flags so
        // Home does not submit a redundant activation request and exhaust the
        // reconnect budget.
        if let tunnel = all.first(where: { $0.id == tunnelIdentifier }) {
            activated = tunnel.installed != nil && tunnel.enabled && !tunnel.outdated && !tunnel.waitingForApproval
            if activated { message = "" }
        }
        if let filter = all.first(where: { $0.id == Self.filterIdentifier }) {
            filterActivated = filter.installed != nil && filter.enabled && !filter.outdated && !filter.waitingForApproval
            if filterActivated { filterMessage = "" }
        }
    }
    /// One button: installs the newer version of whatever is out of date, and asks again for anything waiting on approval. Replacing the tunnel disconnects it for a moment.
    func updateComponents() {
        updating = true
        for component in components where component.outdated || component.waitingForApproval || component.installed == nil {
            if component.id == Self.filterIdentifier { filterActivated = false; activateFilter() } else { activated = false; activate() }
        }
        Task { try? await Task.sleep(for: .seconds(6)); self.updating = false; self.checkComponents() }
    }
    static let filterIdentifier = "app.vayusetu.macos.filter"
    static var filterBundled: Bool { FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/" + filterIdentifier + ".systemextension").path) }
    func activateFilter(onReady: (() -> Void)? = nil) {
        if filterActivated { onReady?(); return }
        guard !filterRequesting else { return }
        guard Self.filterBundled else { filterMessage = "This build does not include the network filter. Install the VayuSetu download from GitHub."; return }
        filterCompletion = onReady; filterRequesting = true; filterWatch.begin(at: Date()); startWatching()
        filterMessage = "Requesting the network filter. macOS may ask for approval in System Settings."
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.filterIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    func activate(onReady: (() -> Void)? = nil, onFailure: ((String) -> Void)? = nil) {
        if activated { onReady?(); return }
        if let onReady { completions.append(onReady) }
        if let onFailure { failureHandlers.append(onFailure) }
        guard !requesting else { return }
        guard TunnelController.available else {
            message = "Sign the VPN build with your provisioned Developer ID team before activating the extension."
            failActivation(message, event: "VPN extension cannot be requested: this build is not signed for system extensions")
            return
        }
        requesting = true; watch.begin(at: Date()); startWatching()
        report?("VPN extension install requested", .info)
        message = "Requesting the VPN extension. macOS may ask for approval in System Settings."
        let id = (Bundle.main.bundleIdentifier ?? "app.vayusetu.macos") + ".tunnel"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: id, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    /// Ends a pending tunnel request that did not succeed: everything waiting on it is told why, and the reason is written to the log.
    private func failActivation(_ reason: String, event: String) {
        requesting = false; activated = false; watch.finish(); completions = []
        let waiting = failureHandlers; failureHandlers = []
        report?(event, .error)
        waiting.forEach { $0(reason) }
    }
    /// macOS can leave a request unanswered. Every few seconds while one is pending this checks the clock; a silent request is reported, not waited on.
    private func startWatching() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.checkWatches(now: Date())
                if !self.watch.active && !self.filterWatch.active { self.watcher = nil; return }
            }
        }
    }
    func checkWatches(now: Date) {
        switch watch.verdict(at: now) {
        case .timedOut(let seconds):
            message = "macOS did not answer the request to install the VPN extension within \(Int(seconds)) seconds. Quit and reopen VayuSetu, or open System Settings → Login Items & Extensions."
            failActivation(message, event: "VPN extension install timed out: no answer from macOS after \(Int(seconds)) s")
        case .approvalTimedOut(let seconds):
            message = "The VPN extension has been waiting for your approval for \(Int(seconds / 60)) minutes. Approve it in System Settings → Login Items & Extensions."
            failActivation(message, event: "VPN extension approval not given after \(Int(seconds / 60)) min")
        case .waiting: break
        }
        switch filterWatch.verdict(at: now) {
        case .timedOut(let seconds), .approvalTimedOut(let seconds):
            filterRequesting = false; filterActivated = false; filterCompletion = nil; filterWatch.finish()
            filterMessage = "macOS did not finish installing the network filter within \(Int(seconds)) seconds."
            report?("Network filter install timed out after \(Int(seconds)) s", .error)
        case .waiting: break
        }
    }
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        let isFilter = request.identifier == Self.filterIdentifier
        Task { @MainActor in
            if isFilter { self.filterWatch.needsApproval(at: Date()) } else { self.watch.needsApproval(at: Date()) }
            self.report?((isFilter ? "Network filter" : "VPN extension") + " is waiting for approval in System Settings", .warning)
        }
        if request.identifier == Self.filterIdentifier { Task { @MainActor in self.filterMessage = "Approve VayuSetu's network filter in System Settings → General → Login Items & Extensions → Network Extensions." }; return }
        Task { @MainActor in self.message = "Approve VayuSetu’s network extension in System Settings → Privacy & Security (or Login Items & Extensions on newer macOS)." }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if request.identifier == Self.filterIdentifier {
            Task { @MainActor in
                self.filterWatch.finish()
                if result != .completed { self.report?("Network filter install will finish after a restart of this Mac", .warning) }
                self.filterRequesting = false; self.filterActivated = result == .completed
                if self.filterActivated { self.filterCompletion?() }; self.filterCompletion = nil
                self.filterMessage = result == .completed ? "" : "The network filter will finish after restarting this Mac."
            }
            return
        }
        Task { @MainActor in
            self.requesting = false; self.watch.finish()
            self.activated = result == .completed
            let waiting = self.completions; self.completions = []
            let failures = self.failureHandlers; self.failureHandlers = []
            if self.activated { waiting.forEach { $0() }; self.report?("VPN extension installed", .info) }
            else {
                let reason = "Extension activation will finish after restarting this Mac."
                self.message = reason
                self.report?("VPN extension install will finish after a restart of this Mac", .warning)
                failures.forEach { $0(reason) }
            }
            if self.activated { self.message = "" }
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        if request.identifier == Self.filterIdentifier {
            Task { @MainActor in
                self.filterWatch.finish()
                self.filterRequesting = false; self.filterActivated = false; self.filterCompletion = nil
                let why = Self.reason(for: error)
                self.filterMessage = "The network filter could not be activated: " + why
                self.report?("Network filter install failed: " + why, .error)
            }
            return
        }
        Task { @MainActor in
            let why = Self.reason(for: error)
            self.message = "The VPN extension could not be installed. " + why
            self.failActivation(self.message, event: "VPN extension install failed: " + why)
        }
    }
    /// The plain-language cause of a failed request, from the system's own error code.
    nonisolated static func reason(for error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == OSSystemExtensionErrorDomain else { return "macOS reported: " + ns.localizedDescription }
        return ExtensionFailure(code: ns.code).explanation
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let id = request.identifier
        Task { @MainActor in self.finishCheck(id, properties) }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}

import SwiftUI
private struct ExtensionManagerKey: EnvironmentKey { static let defaultValue: ExtensionManager? = nil }
extension EnvironmentValues { var extensionManager: ExtensionManager? { get { self[ExtensionManagerKey.self] } set { self[ExtensionManagerKey.self] = newValue } } }
/// Shows what the system said about installing VayuSetu's extensions, so a request that is waiting for approval or that failed is never silent.
struct ExtensionBanner: View {
    @ObservedObject var extensions: ExtensionManager
    var body: some View {
        if extensions.needsAttention && extensions.message.isEmpty && !extensions.requesting {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("VayuSetu's system components need attention").font(.system(size: 13, weight: .semibold))
                    ForEach(extensions.components.filter { $0.outdated || $0.waitingForApproval || ($0.installed != nil && !$0.enabled) }) { Text($0.name + ": " + $0.summary).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Text("Updating the tunnel disconnects it for a moment. macOS may ask you to approve.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if extensions.updating { ProgressView().controlSize(.small) } else { Button("Update now") { extensions.updateComponents() }.buttonStyle(MacHoverButtonStyle(prominent: true)) }
            }.padding(14).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        if !extensions.message.isEmpty || extensions.requesting {
            HStack(alignment: .top, spacing: 10) {
                if extensions.requesting { ProgressView().controlSize(.small) } else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(extensions.requesting ? "Waiting for macOS to install the VayuSetu extension" : "The VayuSetu extension is not ready").font(.system(size: 13, weight: .semibold))
                    Text(extensions.message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }.buttonStyle(MacHoverButtonStyle())
            }.padding(14).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
