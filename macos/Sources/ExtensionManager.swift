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
