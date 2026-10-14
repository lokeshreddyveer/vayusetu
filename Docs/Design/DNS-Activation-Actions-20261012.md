# DNS activation action correction — 2026-10-12

The previous UI replaced the activation action with Refresh Status after native installation. The configuration was saved but not enabled by iOS. The UI therefore offered no primary action explaining the required next step.

Changes: DNSViews.swift provides Enable Encrypted DNS before installation, Finish Activation in iOS Settings for the matching installed-but-disabled configuration, a setup guide with explicit public Settings navigation, secondary refresh/provider actions, refreshed observations on foreground return, and Verify DNS after matching enabled configuration. No private Settings URL or fabricated activation is used. Legacy Recovered prefix is hidden in the overview only; persisted names are preserved. App.swift routes nested DNS entries to the canonical DNS tab. LaunchTests.swift covers actual native save/remove/readback, pending setup, and Home-to-DNS selection.

Validation: signed iPhone build succeeded. Two physical-device tests passed, zero failures, 32.597 seconds. Result: ios/build/dns-activation-actions-final-20261012.xcresult. Earlier starting-state failure was caused by a preexisting installed-but-disabled configuration; the test now explicitly handles that actual state. No independent live DNS traffic or filtering result was established by these tests. The install/remove regression leaves standalone DNS uninstalled, with the preferred resolver preserved. User must enable and select it in iOS Settings, then run independent verification. All configuration operations continue to use NEDNSSettingsManager and the existing serialized store operation.

Apple documentation: https://developer.apple.com/documentation/networkextension/nednssettingsmanager
