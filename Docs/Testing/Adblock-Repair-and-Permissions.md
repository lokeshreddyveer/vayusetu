# Adblock repair and native permissions

The iPhone had Safari rule application off, zero custom or cached rules, and all catalog lists unchecked. Local Safari blocking was inactive. It also recorded repeated reload/rollback failures.

A real WebKit compiler test reproduced the defect: the empty JSON array is rejected with WKErrorDomain code 6. Older versions published it for disabled filtering and rollback. The compiler and extension now use a valid nonmatching rule, including normalization of legacy empty packages. The actual iPhone acknowledged repaired reload, OS Safari enablement and controlled reserved-domain compilation/restoration. This establishes readiness, not real ad-block effectiveness.

The old HaGeZi domains/light.txt URL returned HTTP 404. The published adblock/light.txt URL works: 55,349 entries, of which 55,346 were accepted and 3 explicitly rejected. The previous 50,000 app budget excluded both this list and the current OISD Small list. Complete individual-rule HaGeZi compilation passed the actual Mac WebKit compiler. The modern app now enforces a 150,000-rule and 25 MB package safety budget; no supported entries are silently truncated. An unsupported regex-alternation experiment was rejected by WebKit and removed.

## Setup and permissions

- Explicit “Set Up Basic Safari Protection” downloads the full HaGeZi Light list and requests application with opt-in confirmation.
- Configuration can be saved before OS Safari enablement; applied enforcement remains unchanged and the UI marks the configuration pending. It applies when enablement becomes observable.
- Adblock separately links to all-app provider filtering and DNS diagnostics. Safari lists do not claim to filter other applications.
- Settings → Permissions and onboarding provide native VPN configuration, encrypted DNS-only, notification and Safari settings actions. macOS also provides system-extension activation.
- Connecting to request VPN permission is explicitly labeled and requires a selected profile/resolver. DNS-only setup requires a disconnected VPN.
- Safari enablement remains under OS/user control. Opening settings is never reported as permission granted. Prior notification denial requires changing OS settings.
- Permission prompts run only for the chosen feature, not all at startup.

## Evidence and limits

18 portable tests and 295 regression assertions passed. The disabled package and complete individual-rule list passed actual Mac WebKit compilation. The repaired empty package reloaded on the real iPhone before its connection dropped.

The permissions build installed, but iOS denied launch due to a security/trust condition, then trusted connectivity became unavailable. Local signatures, entitlements, profile expiry and phone registration passed. Unlock/reconnection and app-open confirmation remain pending. A further uniquely versioned iOS 0.11.2 (18) release archive also passed signing checks; macOS 0.6.2 (10) includes the same repair.

Full-list Safari effectiveness, physical permission-prompt behavior and all-app DNS policy are not marked verified. A diagnostic hook is ready to compare representative public ad/tracker domains against the saved resolver and a reference on the current route; it did not run after the launch refusal. No measurement was fabricated.

DNS-domain filtering cannot guarantee removal of every first-party or embedded ad. No blanket “everything blocked” claim is made.

Sources: [Apple content blockers](https://developer.apple.com/documentation/SafariServices/creating-a-content-blocker), [Apple Safari settings API](https://developer.apple.com/documentation/safariservices/sfsafarisettings/openextensionssettings(foridentifiers:completionhandler:)), [HaGeZi official list](https://github.com/hagezi/dns-blocklists), [AdGuard Safari content-blocker limits](https://adguard.com/kb/adguard-for-safari/features/content-blockers/).
