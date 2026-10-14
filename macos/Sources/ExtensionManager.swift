import Foundation
import SystemExtensions
import Combine

@MainActor final class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var message = ""
    @Published var requesting = false
    @Published var activated = false
    private var completion: (() -> Void)?
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
        Task { @MainActor in self.message = "Approve VayuSetu’s network extension in System Settings → Privacy & Security (or Login Items & Extensions on newer macOS)." }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.requesting = false
            self.activated = result == .completed
            if self.activated { self.completion?() }; self.completion = nil
            self.message = result == .completed ? "Extension activated. You can request a VPN connection." : "Extension activation will finish after restarting this Mac."
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.requesting = false; self.activated = false; self.completion = nil; self.message = "Extension activation failed. Check signing, provisioning and installation in /Applications. Error: \(error.localizedDescription)" }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}
