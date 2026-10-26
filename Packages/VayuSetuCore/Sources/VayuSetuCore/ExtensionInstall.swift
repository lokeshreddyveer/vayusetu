import Foundation

/// What went wrong when macOS was asked to install or replace one of VayuSetu's system extensions, in words a person can act on.
/// The codes are `OSSystemExtensionError.Code` raw values; keeping the mapping here lets it be tested without the framework.
public enum ExtensionFailure: Equatable, Sendable {
    case validation, signature, missingEntitlement, location, notFound, policy, authorization, cancelled, superseded, duplicate, other(Int)

    public init(code: Int) {
        switch code {
        case 2: self = .missingEntitlement
        case 3: self = .location
        case 4: self = .notFound
        case 6: self = .duplicate
        case 8: self = .signature
        case 9: self = .validation
        case 10: self = .policy
        case 11: self = .cancelled
        case 12: self = .superseded
        case 13: self = .authorization
        default: self = .other(code)
        }
    }
    public var explanation: String {
        switch self {
        case .validation, .signature: return "macOS rejected the extension's signature. A build that is not notarized cannot replace an installed extension. Install the notarized download, or notarize this build."
        case .missingEntitlement: return "The app is missing the entitlement that lets it install a system extension. Reinstall the signed VayuSetu download."
        case .location: return "VayuSetu must be in the Applications folder to install its extension. Move it there and open it again."
        case .notFound: return "This build does not contain the extension. Reinstall the VayuSetu download."
        case .policy: return "A security policy on this Mac blocks the extension. Allow it in System Settings, or ask whoever manages the Mac."
        case .authorization: return "The extension needs your approval in System Settings → Login Items & Extensions → Network Extensions."
        case .cancelled: return "The install request was cancelled."
        case .superseded: return "A newer install request replaced this one."
        case .duplicate: return "Two extensions use the same identifier. Reinstall the VayuSetu download."
        case .other(let code): return "macOS could not install the extension (error \(code))."
        }
    }
}

/// Watches one install or replace request for the case where macOS never answers. Such a request used to leave the app waiting with nothing logged:
/// after `noAnswer` seconds without a reply it is reported as timed out, and a request that is waiting for the person's approval gets a longer limit.
public struct InstallWatch: Equatable, Sendable {
    public static let noAnswer: TimeInterval = 60
    public static let approvalLimit: TimeInterval = 15 * 60
    public enum Verdict: Equatable, Sendable { case waiting, timedOut(after: TimeInterval), approvalTimedOut(after: TimeInterval) }
    private var startedAt: Date?
    private var approvalAt: Date?
    public init() {}
    public var active: Bool { startedAt != nil }
    public var awaitingApproval: Bool { approvalAt != nil }
    public mutating func begin(at now: Date) { startedAt = now; approvalAt = nil }
    public mutating func needsApproval(at now: Date) { if startedAt != nil, approvalAt == nil { approvalAt = now } }
    public mutating func finish() { startedAt = nil; approvalAt = nil }
    public func verdict(at now: Date) -> Verdict {
        guard let startedAt else { return .waiting }
        if let approvalAt {
            let waited = now.timeIntervalSince(approvalAt)
            return waited >= Self.approvalLimit ? .approvalTimedOut(after: waited) : .waiting
        }
        let waited = now.timeIntervalSince(startedAt)
        return waited >= Self.noAnswer ? .timedOut(after: waited) : .waiting
    }
}

/// Whether a component that was installed has gone: the system removed it (a failed validation uninstalls it) or it is being removed.
public enum ExtensionPresence {
    public static func removalNote(previouslyInstalled: String?, nowInstalled: String?, uninstalling: Bool) -> String? {
        guard previouslyInstalled != nil else { return nil }
        if nowInstalled == nil { return "The extension that was installed is no longer installed." }
        if uninstalling { return "macOS is removing the installed extension." }
        return nil
    }
}
