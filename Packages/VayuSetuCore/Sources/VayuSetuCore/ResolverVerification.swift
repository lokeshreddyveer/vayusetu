import Foundation

/// How DNS protection is judged when the VPN carries an external encrypted resolver (Control D, Quad9 and the like) and there is no VayuSetu
/// filter running to ask. Four honest outcomes, never one catch-all "not verified":
///   - verified: the system accepted that resolver's settings, and names resolve the way applications resolve them;
///   - failed: the settings were accepted but names do not resolve;
///   - unavailable: the system has not confirmed that it applied the resolver, so the result cannot be attributed to it (this is not a failure);
///   - notChecked: no check has run yet.
public enum ExternalResolverVerdict: Equatable, Sendable {
    case verified, failed, unavailable, notChecked

    public static func decide(accepted: Bool?, resolved: Bool?) -> ExternalResolverVerdict {
        guard let resolved else { return .notChecked }
        guard accepted == true else { return .unavailable }
        return resolved ? .verified : .failed
    }

    /// What to tell the person, in the app's plain words.
    public var detail: String {
        switch self {
        case .verified: return "The VPN applied your encrypted resolver and names resolve through it. Filtering is the resolver's own; VayuSetu's lists are not applied here."
        case .failed: return "The VPN applied your encrypted resolver, but names did not resolve through it."
        case .unavailable: return "Names resolve, but the system has not confirmed that it applied your resolver, so this cannot be checked for this setup."
        case .notChecked: return "VPN resolver configured. The check has not run yet."
        }
    }
}
