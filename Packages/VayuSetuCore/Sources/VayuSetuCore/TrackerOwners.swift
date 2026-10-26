import Foundation

/// Who is behind a tracker or ad domain, for the people who want to see "Google: 412 blocked" instead of a list of unfamiliar names.
/// The table is written by hand from public knowledge of who runs each service. It is short on purpose and does not claim to be complete:
/// a domain that is not in it simply has no company shown. Ownership changes (companies are bought and sold); entries are the owner at the time
/// of writing, and a wrong or missing entry only affects a label, never what is blocked.
public enum TrackerOwners {
    static let table: [String: String] = [
        "doubleclick.net": "Google",
        "googlesyndication.com": "Google",
        "googleadservices.com": "Google",
        "google-analytics.com": "Google",
        "googletagmanager.com": "Google",
        "googletagservices.com": "Google",
        "admob.com": "Google",
        "2mdn.net": "Google",
        "app-measurement.com": "Google",
        "crashlytics.com": "Google",
        "firebaselogging-pa.googleapis.com": "Google",
        "facebook.net": "Meta",
        "an.facebook.com": "Meta",
        "pixel.facebook.com": "Meta",
        "clarity.ms": "Microsoft",
        "bat.bing.com": "Microsoft",
        "ads.msn.com": "Microsoft",
        "adnxs.com": "Xandr (Microsoft)",
        "amazon-adsystem.com": "Amazon",
        "demdex.net": "Adobe",
        "omtrdc.net": "Adobe",
        "2o7.net": "Adobe",
        "everesttech.net": "Adobe",
        "adobedtm.com": "Adobe",
        "bluekai.com": "Oracle",
        "addthis.com": "Oracle",
        "eloqua.com": "Oracle",
        "ads-twitter.com": "X (Twitter)",
        "analytics.twitter.com": "X (Twitter)",
        "ads-api.twitter.com": "X (Twitter)",
        "analytics.tiktok.com": "TikTok / ByteDance",
        "byteoversea.com": "TikTok / ByteDance",
        "ads.tiktok.com": "TikTok / ByteDance",
        "tr.snapchat.com": "Snap",
        "sc-static.net": "Snap",
        "ads.snapchat.com": "Snap",
        "ct.pinterest.com": "Pinterest",
        "ads.pinterest.com": "Pinterest",
        "px.ads.linkedin.com": "LinkedIn (Microsoft)",
        "snap.licdn.com": "LinkedIn (Microsoft)",
        "criteo.com": "Criteo",
        "criteo.net": "Criteo",
        "taboola.com": "Taboola",
        "taboolasyndication.com": "Taboola",
        "outbrain.com": "Outbrain",
        "hotjar.com": "Hotjar",
        "hotjar.io": "Hotjar",
        "mixpanel.com": "Mixpanel",
        "segment.io": "Segment (Twilio)",
        "segment.com": "Segment (Twilio)",
        "amplitude.com": "Amplitude",
        "appsflyer.com": "AppsFlyer",
        "adjust.com": "Adjust",
        "branch.io": "Branch",
        "app.link": "Branch",
        "unityads.unity3d.com": "Unity",
        "applovin.com": "AppLovin",
        "applvn.com": "AppLovin",
        "ironsrc.com": "ironSource",
        "supersonicads.com": "ironSource",
        "advertising.com": "Yahoo",
        "flurry.com": "Yahoo",
        "quantserve.com": "Quantcast",
        "quantcount.com": "Quantcast",
        "scorecardresearch.com": "Comscore",
        "imrworldwide.com": "Nielsen",
        "rlcdn.com": "LiveRamp",
        "pippio.com": "LiveRamp",
        "adsrvr.org": "The Trade Desk",
        "pubmatic.com": "PubMatic",
        "rubiconproject.com": "Magnite",
        "magnite.com": "Magnite",
        "openx.net": "OpenX",
        "casalemedia.com": "Index Exchange",
        "indexww.com": "Index Exchange",
        "krxd.net": "Salesforce",
        "braze.com": "Braze",
        "appboy.com": "Braze",
        "onesignal.com": "OneSignal",
        "nr-data.net": "New Relic",
        "optimizely.com": "Optimizely",
        "fullstory.com": "FullStory",
        "heapanalytics.com": "Heap",
        "mc.yandex.ru": "Yandex",
        "an.yandex.ru": "Yandex",
        "hm.baidu.com": "Baidu",
    ]

    /// The company behind a domain, matching the most specific entry (an exact name or a parent domain), or nil.
    public static func owner(of domain: String) -> String? {
        var name = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        while !name.isEmpty {
            if let owner = table[name] { return owner }
            guard let dot = name.firstIndex(of: ".") else { return nil }
            name = String(name[name.index(after: dot)...])
        }
        return nil
    }

    public struct Group: Equatable, Identifiable, Sendable {
        public let company: String
        public let blocked: Int
        public let domains: [String]
        public var id: String { company }
    }

    /// Blocked counts grouped by company, largest first. Domains with no known company are returned apart, as a total, so nothing is hidden.
    public static func group(blocked counts: [(name: String, blocked: Int)]) -> (groups: [Group], unattributed: Int) {
        var byCompany: [String: (Int, [(String, Int)])] = [:]; var unknown = 0
        for c in counts where c.blocked > 0 {
            if let company = owner(of: c.name) { var e = byCompany[company] ?? (0, []); e.0 += c.blocked; e.1.append((c.name, c.blocked)); byCompany[company] = e }
            else { unknown += c.blocked }
        }
        let groups = byCompany.map { Group(company: $0.key, blocked: $0.value.0, domains: $0.value.1.sorted { ($0.1, $1.0) > ($1.1, $0.0) }.map(\.0)) }
            .sorted { ($0.blocked, $1.company) > ($1.blocked, $0.company) }
        return (groups, unknown)
    }
}
