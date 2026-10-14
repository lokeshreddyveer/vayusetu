# VayuSetu iOS design research

Reviewed 2026-10-10.

Sources:
- https://protonvpn.com/blog/new-windows-ios-apps — home-centered connection status, fast saved connection access, progressive details.
- https://developer.apple.com/videos/play/wwdc2025/219/ — glass as a navigation/control layer, quiet content beneath it.
- https://developer.apple.com/design/human-interface-guidelines/tab-bars — native persistent top-level navigation.

VayuSetu implementation: near-black opaque content surfaces, blue accents, native tab/navigation bars, unboxed connection hero with concentric power control, compact grouped profile/resolver rows, concise badges, hidden scroll indicators, consistent spacing and native sheets/confirmations. Do not invent server locations, protection scores, blocked tracker counts or IP values. Preview and unverified states remain explicit. Preserve bounded SwiftUI presentation types to prevent recursive metadata crashes on launch.
