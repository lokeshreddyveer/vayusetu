import Foundation
import SystemExtensions
import Combine

@MainActor final class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var message = ""
    @Published var requesting = false
    @Published var activated = false
    private var completion: (() -> Void)?
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
        components = [component(tunnelIdentifier, "VPN and DNS tunnel"), component(Self.filterIdentifier, "Network filter")].filter { $0.bundled != nil }
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
        filterCompletion = onReady; filterRequesting = true
        filterMessage = "Requesting the network filter. macOS may ask for approval in System Settings."
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.filterIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    func activate(onReady: (() -> Void)? = nil) {
        if activated { onReady?(); return }
        guard !requesting else { return }
        guard TunnelController.available else { message = "Sign the VPN build with your provisioned Developer ID team before activating the extension."; return }
        completion = onReady
        requesting = true
        message = "Requesting the VPN extension. macOS may ask for approval in System Settings."
        let id = (Bundle.main.bundleIdentifier ?? "app.vayusetu.macos") + ".tunnel"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: id, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        if request.identifier == Self.filterIdentifier { Task { @MainActor in self.filterMessage = "Approve VayuSetu's network filter in System Settings → General → Login Items & Extensions → Network Extensions." }; return }
        Task { @MainActor in self.message = "Approve VayuSetu’s network extension in System Settings → Privacy & Security (or Login Items & Extensions on newer macOS)." }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if request.identifier == Self.filterIdentifier {
            Task { @MainActor in
                self.filterRequesting = false; self.filterActivated = result == .completed
                if self.filterActivated { self.filterCompletion?() }; self.filterCompletion = nil
                self.filterMessage = result == .completed ? "" : "The network filter will finish after restarting this Mac."
            }
            return
        }
        Task { @MainActor in
            self.requesting = false
            self.activated = result == .completed
            if self.activated { self.completion?() }; self.completion = nil
            self.message = result == .completed ? "Extension activated. You can request a VPN connection." : "Extension activation will finish after restarting this Mac."
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        if request.identifier == Self.filterIdentifier {
            Task { @MainActor in self.filterRequesting = false; self.filterActivated = false; self.filterCompletion = nil; self.filterMessage = "The network filter could not be activated: " + error.localizedDescription }
            return
        }
        Task { @MainActor in self.requesting = false; self.activated = false; self.completion = nil; self.message = "Extension activation failed. Check signing, provisioning and installation in /Applications. Error: \(error.localizedDescription)" }
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
