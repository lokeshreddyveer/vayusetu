import ActivityKit
import Foundation

/// A short event shown in the Dynamic Island and on the Lock Screen, such as "VPN connected". It appears for a few seconds and goes away.
struct ConnectionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Tone: String, Codable, Hashable { case on, off, info }
        var title: String
        var detail: String
        /// A few characters for the compact island, such as "On" or "Off".
        var short: String
        var symbol: String
        var tone: Tone
    }
    var sessionID: String
}
