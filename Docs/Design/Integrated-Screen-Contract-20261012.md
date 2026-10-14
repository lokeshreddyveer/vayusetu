# Integrated screen contract — first implementation step

Source: user specification “How Every Screen Should Work Together”, 2026-10-12.

Implemented: AppStore.reconcileNetworkState is a shared, coalesced observation path. iOS and macOS request it on foreground, periodically, on VPN transitions, and on network route changes. Network/VPN transitions invalidate existing DNS results and cancel network-quality measurements. SystemDNSController coalesces OS reads, prevents a read from overwriting staged manager settings during a write, and waits for pending reads before enable/remove. Writer-owned readback remains inside the writer. Refresh does not disconnect VPN, remove independent DNS, change DNS intent, or apply Safari rules.

Files: ios/Sources/Store.swift, ios/Sources/PrivacyFeatures.swift, ios/Sources/App.swift, macos/Sources/App.swift. Shared store/controllers are used by both platforms.

Validation: signed iOS device build and two physical iPhone tests passed, zero failures, 33.123 seconds. Tests cover native DNS installation/readback/removal, pending activation guide, and Home-to-DNS tab routing. Result bundle ios/build/shared-reconciliation-20261012.xcresult. macOS Debug unsigned compile succeeded; no macOS runtime or VPN test performed. The tests do not prove all concurrent timing permutations or device-wide DNS security.

Remaining contract gaps, ordered:
1. Preserve independent DNS intent while explicitly suspending it for a supported VPN DNS policy, then reconcile restoration on disconnect. Existing confirmed VPN-managed mode calls disable, which clears intent; do not call this complete automatic coordination.
2. Move remaining direct UI network mutation entry points behind one serialized policy coordinator, with rollback and cancellation semantics. Shared observation is not a complete mutation coordinator.
3. Provider-neutral catalog, validated profiles, modular integrations and explicit capability matrix. OpenVPN remains unavailable by user choice pending licensing.
4. Unify diagnostic evidence storage/freshness across network, resolver, tunnel and filtering policy changes. Existing DNS result invalidation is only one part.
5. Independently validate effective DNS routing/filtering, VPN-failure policy, reconnection and Wi-Fi/cellular transitions. Configuration acceptance cannot be a verification pass.
6. Continue Safari/adblock integration only when the explicitly paused work is resumed; this change only reads its existing shared manager.

This step changes reconciliation behavior only. It does not implement or claim the complete integration specification.
