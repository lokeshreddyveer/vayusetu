import Foundation

/// One step of getting VayuSetu ready. Each step's state comes from something observed, never from a click on "Done".
public struct SetupStep: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable { case done, todo, blocked, optionalTodo }
    public let id: String
    public let title: String
    /// What to do, in one sentence; or what was seen when it is done.
    public let detail: String
    public let state: State
    public init(id: String, title: String, detail: String, state: State) { self.id = id; self.title = title; self.detail = detail; self.state = state }
}

public struct SetupObservations: Sendable {
    public var tunnelInstalled = false
    public var tunnelNeedsApproval = false
    public var filterInstalled = false
    public var filterAvailable = true
    public var hasVPNProfile = false
    public var hasDNSChoice = false
    public var safariExtensionsOn: Int?          // nil: not read yet
    public var safariExtensionsNeeded = 0
    public var proofWorking = false
    public init() {}
}

public enum SetupGuide {
    public static func steps(_ o: SetupObservations) -> [SetupStep] {
        var steps: [SetupStep] = []
        steps.append(o.tunnelInstalled
            ? SetupStep(id: "tunnel", title: "Network extension approved", detail: "macOS has installed VayuSetu's tunnel.", state: .done)
            : SetupStep(id: "tunnel", title: "Approve the network extension", detail: o.tunnelNeedsApproval ? "Open System Settings, General, Login Items & Extensions, Network Extensions, and switch VayuSetu on." : "Turn on DNS or the VPN once; macOS then asks you to approve the extension.", state: o.tunnelNeedsApproval ? .blocked : .todo))
        steps.append(o.hasVPNProfile || o.hasDNSChoice
            ? SetupStep(id: "profile", title: "A VPN profile or DNS resolver is chosen", detail: o.hasVPNProfile ? "You have a VPN profile." : "DNS only is set up.", state: .done)
            : SetupStep(id: "profile", title: "Add a VPN profile or choose a DNS resolver", detail: "Import your WireGuard file, or pick the built-in VayuSetu DNS for DNS-only protection.", state: .todo))
        if let on = o.safariExtensionsOn {
            steps.append(o.safariExtensionsNeeded > 0 && on >= o.safariExtensionsNeeded
                ? SetupStep(id: "safari", title: "Safari ad blocking is on", detail: "\(on) of \(o.safariExtensionsNeeded) VayuSetu extensions are switched on in Safari.", state: .done)
                : SetupStep(id: "safari", title: "Turn the Safari extensions on", detail: "In Safari, Settings, Extensions, switch on the VayuSetu extensions (\(on) of \(max(o.safariExtensionsNeeded, 1)) are on).", state: .optionalTodo))
        }
        if o.filterAvailable {
            steps.append(o.filterInstalled
                ? SetupStep(id: "filter", title: "Network filter approved", detail: "You can see and control which apps connect.", state: .done)
                : SetupStep(id: "filter", title: "Optional: turn on the network filter", detail: "On the Network page, switch it on to see which apps connect where.", state: .optionalTodo))
        }
        steps.append(o.proofWorking
            ? SetupStep(id: "proof", title: "Protection has been seen working", detail: "The checks on Home passed.", state: .done)
            : SetupStep(id: "proof", title: "Check that it works", detail: "Turn protection on, then look at \"Is it working?\" on Home.", state: .todo))
        return steps
    }
    /// The first required step that is not done, or nil when everything required is done.
    public static func next(_ steps: [SetupStep]) -> SetupStep? { steps.first { $0.state == .todo || $0.state == .blocked } }
    public static func isComplete(_ steps: [SetupStep]) -> Bool { next(steps) == nil }
    public static func progress(_ steps: [SetupStep]) -> (done: Int, total: Int) { (steps.filter { $0.state == .done }.count, steps.count) }
}

/// Turns the app's own raw failure text into one plain sentence of what happened and one of what to do. Unknown text is shown as it is.
public enum FailureAdvice {
    public struct Advice: Equatable, Sendable { public let happened: String; public let todo: String }
    public static func plain(_ raw: String) -> Advice? {
        let t = raw.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        if has("app group access is unavailable") { return Advice(happened: "The tunnel could not find the folder it keeps its filter rules in.", todo: "Press Update now if the banner is showing, then try again.") }
        if has("keys for", "keys are missing", "no wireguard configuration", "no privatekey", "private key is not a valid", "valid private key") { return Advice(happened: "The saved keys for this VPN profile are missing or unreadable.", todo: "Edit the profile and import its configuration file again.") }
        if has("no [peer]", "no peer", "at least one peer") { return Advice(happened: "This VPN profile has no server in it.", todo: "Import the full configuration file from your VPN provider.") }
        if has("another vpn tunnel is active") { return Advice(happened: "Another VPN is already running on this Mac.", todo: "Turn the other VPN off, then start VayuSetu.") }
        if has("disconnect before changing") { return Advice(happened: "A tunnel is still running, so its settings cannot change yet.", todo: "Turn protection off, wait a few seconds, and try again.") }
        if has("did not finish starting", "deadline exceeded", "stopped before it became usable") { return Advice(happened: "The tunnel did not finish starting in time.", todo: "Turn protection off and on again. If it keeps happening, copy the details and send them to support.") }
        if has("resolver bootstrap timed out", "bootstrap resolution failed", "bootstrap is busy") { return Advice(happened: "VayuSetu could not look up the DNS provider's address.", todo: "Check your internet connection and try again.") }
        if has("tunnel setup failed") { return Advice(happened: "The tunnel stopped while it was starting.", todo: "Press Details to see where, and Update now if a component is out of date.") }
        if has("extension activation failed", "could not be activated") { return Advice(happened: "macOS did not install the VayuSetu extension.", todo: "Make sure VayuSetu is in the Applications folder, then try again.") }
        if has("approve vayusetu", "needs approval", "approval") { return Advice(happened: "macOS is waiting for you to approve the extension.", todo: "Open System Settings, General, Login Items & Extensions, and switch VayuSetu on.") }
        if has("secd", "keychain operation failed") { return Advice(happened: "macOS would not let VayuSetu read its saved keys.", todo: "Unlock your Mac and try again; if it keeps happening, re-import the profile.") }
        if has("safari did not answer", "probably switched off in safari") { return Advice(happened: "Safari did not answer, so its rules were not loaded.", todo: "Switch the VayuSetu extensions on in Safari, Settings, Extensions.") }
        return nil
    }
}
