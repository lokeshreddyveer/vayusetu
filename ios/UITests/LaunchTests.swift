import XCTest
final class LaunchTests: XCTestCase {
    func testTabNavigationAndCancellationAudit() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15))
        for tab in ["Home", "Profiles", "DNS", "Adblock", "Settings"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected)
            XCTAssertEqual(app.tabBars.buttons.count, 5)
            XCTAssertEqual(app.state, .runningForeground)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Audit-" + tab; shot.lifetime = .keepAlways; add(shot)
        }
        app.tabBars.buttons["Home"].tap()
        app.buttons["Open Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.isHittable)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Profiles"].tap()
        app.buttons["Add profile"].tap()
        app.buttons["WireGuard"].tap()
        XCTAssertTrue(app.navigationBars["New Profile"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Add profile"].waitForExistence(timeout: 5))

        app.tabBars.buttons["DNS"].tap()
        app.buttons["Advanced DNS Settings"].tap()
        XCTAssertTrue(app.navigationBars["Advanced DNS Settings"].waitForExistence(timeout: 5))
        app.staticTexts["DNS Diagnostics"].tap()
        XCTAssertTrue(app.navigationBars["DNS Diagnostics"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Advanced DNS Settings"].waitForExistence(timeout: 5))
        app.buttons["DNSChangeResolver"].tap()
        XCTAssertTrue(app.navigationBars["DNS Resolvers"].waitForExistence(timeout: 5))
        let addResolver = app.buttons["Add resolver"]
        for _ in 0..<5 { if addResolver.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(addResolver.isHittable)
        if addResolver.isEnabled {
            addResolver.tap()
            XCTAssertTrue(app.navigationBars["New Resolver"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Save"].isEnabled)
            app.buttons["Cancel"].tap()
        }
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testSettingsDestinationsAudit() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "4"]; app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let destinations = [
            ("Permissions", "Permissions"), ("Recovery preferences", "Recovery"),
            ("Privacy Lock & Connection Rules", "Privacy Lock"), ("Security Center", "Security Center"),
            ("Appearance & Accessibility", "Appearance"), ("Checks", "Checks"),
            ("Privacy Activity", "Privacy Activity"), ("Data & Logging", "Privacy"),
            ("Protection Conflicts & Compatibility", "Compatibility"), ("Extension Status", "Extension Status"),
            ("Emergency Reset", "Emergency Reset"), ("Encrypted backups", "Encrypted Backups"),
            ("Connection logs", "Logs"), ("Traffic & sessions", "Traffic"), ("Acknowledgements", "Acknowledgements")
        ]
        for (label, title) in destinations {
            let row = app.staticTexts[label].firstMatch
            for _ in 0..<8 { if row.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(row.isHittable, "Settings destination is reachable: " + label)
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.isHittable)
            app.navigationBars.buttons.firstMatch.tap()
            if !app.navigationBars["Settings"].waitForExistence(timeout: 5), app.navigationBars[title].exists {
                // An OS notification may consume the back tap. Retry only while
                // still on this destination, so this cannot accidentally pop twice.
                app.navigationBars[title].buttons.firstMatch.tap()
            }
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Returned from " + title)
        }
    }

    func testRepeatedLaunchTabsAndEditor() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]
        for _ in 0..<3 {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.state, .runningForeground)
        }
        for tab in ["Profiles", "DNS", "Adblock", "Settings", "Home"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertEqual(app.state, .runningForeground)
        }
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        app.tabBars.buttons["Profiles"].tap()
        app.buttons["Add profile"].tap()
        app.buttons["WireGuard"].tap()
        XCTAssertTrue(app.navigationBars["New Profile"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.tabBars.buttons["DNS"].tap()
        XCTAssertTrue(app.staticTexts["OS encrypted DNS-only"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(app.state, .runningForeground)
    }
    func testDiagnosticScreensRemainScrollable() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "4"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let checks = app.staticTexts["Checks"]
        for _ in 0..<5 { if checks.isHittable { break }; app.swipeUp() }
        checks.tap()
        XCTAssertTrue(app.navigationBars["Checks"].waitForExistence(timeout: 5))
        app.staticTexts["Public IPv4 / IPv6"].tap()
        XCTAssertTrue(app.navigationBars["Public IP Discovery"].waitForExistence(timeout: 5))
        let measure = app.buttons["Measure IPv4 & IPv6"]
        for _ in 0..<5 { if measure.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(measure.isHittable, "The IP action must scroll above the tab bar")
        let ip = XCTAttachment(screenshot: app.screenshot()); ip.name = "Public-IP-scrolling"; ip.lifetime = .keepAlways; add(ip)
        app.navigationBars.buttons.firstMatch.tap()
        let filtering = app.staticTexts["Ad & tracker protection"]
        for _ in 0..<5 { if filtering.isHittable { break }; app.swipeUp() }
        filtering.tap()
        XCTAssertTrue(app.navigationBars["DNS Filtering"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Required to confirm DNS filtering: choose a trusted, unfiltered reference that resolves the controlled test names."].exists)
        let run = app.buttons["Run DNS Filtering Checks"]
        for _ in 0..<5 { if run.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(run.exists)
        XCTAssertFalse(run.isEnabled, "No valid reference must never appear ready to verify blocking")
        let dns = XCTAttachment(screenshot: app.screenshot()); dns.name = "DNS-filtering-reference"; dns.lifetime = .keepAlways; add(dns)
    }
    func testResolverBootstrapValidationAndPolicyControls() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["DNS"].waitForExistence(timeout: 10))
        app.tabBars.buttons["DNS"].tap()
        app.buttons["DNSChangeResolver"].tap()
        XCTAssertTrue(app.navigationBars["DNS Resolvers"].waitForExistence(timeout: 5))
        app.buttons["Add resolver"].tap()
        XCTAssertTrue(app.navigationBars["New Resolver"].waitForExistence(timeout: 5))
        let name = app.textFields["Name"]; name.tap(); name.typeText("Bootstrap validation")
        let endpoint = app.secureTextFields["HTTPS endpoint"]; endpoint.tap(); endpoint.typeText("https://dns.example.com/query")
        let addresses = app.textFields["Provider bootstrap IPs (optional)"]
        for _ in 0..<4 { if addresses.isHittable { break }; app.swipeUp() }
        addresses.tap(); addresses.typeText("127.0.0.1")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Resolver bootstrap requires usable, unscoped IPv4 or IPv6 addresses."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["New Resolver"].exists, "Rejected input must not dismiss or save the resolver")
        let editor = XCTAttachment(screenshot: app.screenshot()); editor.name = "Bootstrap-validation"; editor.lifetime = .keepAlways; add(editor)
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Settings"].tap()
        let privacy = app.staticTexts["Privacy Lock & Connection Rules"]
        for _ in 0..<5 { if privacy.isHittable { break }; app.swipeUp() }
        privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy Lock"].waitForExistence(timeout: 5))
        let strict = app.switches["Privacy Lock"]
        for _ in 0..<5 { if strict.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(strict.exists)
        XCTAssertEqual(strict.value as? String, "1")
        XCTAssertFalse(app.switches["Connect on demand"].isEnabled)
        XCTAssertFalse(app.switches["Allow local network"].isEnabled)
        let policy = XCTAttachment(screenshot: app.screenshot()); policy.name = "Strict-policy-controls"; policy.lifetime = .keepAlways; add(policy)
    }
    func testAdblockAndSafariEvidenceSurfaces() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "3"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Adblock"].waitForExistence(timeout: 10))
        let match = app.staticTexts["Test Rule Match"].firstMatch
        for _ in 0..<5 { if match.exists { break }; app.swipeUp() }
        XCTAssertTrue(match.exists)
        for _ in 0..<5 { if app.staticTexts["Safari"].firstMatch.isHittable { break }; app.swipeDown() }
        app.staticTexts["Safari"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Safari"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Safari enabled state"].exists)
        XCTAssertTrue(app.staticTexts["Rule readiness"].exists)
        XCTAssertTrue(app.staticTexts["Rule effectiveness"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Safari-evidence-separation"; shot.lifetime = .keepAlways; add(shot)
    }

    func testDedicatedFilterAndBackupScreens() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "3"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Adblock"].waitForExistence(timeout: 10))
        for title in ["Filter Lists", "Custom Rules", "Filter Health"] {
            let row = app.staticTexts[title].firstMatch
            for _ in 0..<4 { if row.isHittable { break }; app.swipeUp() }
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = title; shot.lifetime = .keepAlways; add(shot)
            app.navigationBars.buttons.firstMatch.tap()
        }
        app.tabBars.buttons["Settings"].tap()
        // A system call can interrupt a synthesized tap; require the destination
        // before scrolling rather than mistaking the old tab for missing content.
        if !app.navigationBars["Settings"].waitForExistence(timeout: 5) {
            app.activate(); app.tabBars.buttons["Settings"].tap()
        }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let backup = app.staticTexts["Encrypted backups"]
        for _ in 0..<8 { if backup.isHittable { break }; app.swipeUp() }
        backup.tap()
        XCTAssertTrue(app.navigationBars["Encrypted Backups"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Include Credentials & Endpoints"].value as? String, "0")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Credential-free-backup-default"; shot.lifetime = .keepAlways; add(shot)
    }

    func testDNSWebsiteVerificationNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "2"]
        app.launch()
        XCTAssertTrue(app.buttons["DNSEnableProtection"].waitForExistence(timeout: 10))
        let diagnostics = app.staticTexts["DNS Diagnostics"]
        for _ in 0..<6 { if diagnostics.isHittable { break }; app.swipeUp() }
        diagnostics.tap()
        XCTAssertTrue(app.navigationBars["DNS Diagnostics"].waitForExistence(timeout: 5))
        app.staticTexts["DNS Provider & Website Checks"].tap()
        XCTAssertTrue(app.navigationBars["DNS Provider Checks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Check All DNS Providers"].exists)
        let browserLeaks = app.staticTexts["BrowserLeaks"].firstMatch
        for _ in 0..<5 { if browserLeaks.isHittable { break }; app.swipeUp() }
        browserLeaks.tap()
        XCTAssertTrue(app.navigationBars["BrowserLeaks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Website results describe this embedded browser's DNS path. They do not prove device-wide protection. No resolver or VPN route is changed."].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Embedded-BrowserLeaks-DNS-test"; shot.lifetime = .keepAlways; add(shot)
    }

    func testNativePermissionsScreen() {
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "4"]; app.launch()
        XCTAssertTrue(app.staticTexts["Permissions"].waitForExistence(timeout: 10))
        app.staticTexts["Permissions"].tap()
        XCTAssertTrue(app.navigationBars["Permissions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Connect & Request VPN Permission"].exists)
        XCTAssertTrue(app.buttons["Open Safari Extension Settings"].exists)
        let notification = app.buttons["Request Notification Permission"]
        for _ in 0..<5 { if notification.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(notification.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Native-Permissions"; shot.lifetime = .keepAlways; add(shot)
    }

    func testBasicSafariProtectionSetup() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "3"]; app.launch()
        XCTAssertTrue(app.navigationBars["Adblock"].waitForExistence(timeout: 10))
        let setup = app.buttons["Set Up Basic Safari Protection"]
        if setup.exists {
            setup.tap()
            XCTAssertTrue(app.buttons["Download & Set Up"].waitForExistence(timeout: 5))
            app.buttons["Download & Set Up"].tap()
            let gone = NSPredicate(format: "exists == false")
            expectation(for: gone, evaluatedWith: setup)
            waitForExpectations(timeout: 90)
        }
        app.staticTexts["Safari"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Safari"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Reload acknowledged"].waitForExistence(timeout: 45))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Full-Safari-List-Applied"; shot.lifetime = .keepAlways; add(shot)
    }

    func testHomeHeaderStepOne() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        let settings = app.buttons["Open Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(settings.frame.height, 44)
        XCTAssertGreaterThanOrEqual(settings.frame.width, 44)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Home-Header-Step-1"; shot.lifetime = .keepAlways; add(shot)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.isHittable)
    }

    func testHomeConnectionCardStepTwo() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        let power = app.buttons["HomeVPNPower"]
        XCTAssertTrue(power.waitForExistence(timeout: 5))
        XCTAssertEqual(power.frame.width, 120, accuracy: 1)
        XCTAssertEqual(power.frame.height, 120, accuracy: 1)
        let profile = app.buttons["HomeProfileSelector"]
        XCTAssertTrue(profile.exists)
        XCTAssertGreaterThanOrEqual(profile.frame.height, 44)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Home-Connection-Card-Step-2"; shot.lifetime = .keepAlways; add(shot)
        profile.tap()
        XCTAssertTrue(app.navigationBars["Profiles"].waitForExistence(timeout: 5))
    }

    func testProfilesHeaderStepOne() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Profiles"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Profiles"].tap()
        XCTAssertTrue(app.staticTexts["Manage your VPN connections"].waitForExistence(timeout: 5))
        let addButton = app.buttons["Add profile"]
        XCTAssertGreaterThanOrEqual(addButton.frame.height, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(addButton.frame.width, 44 - 0.01)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Profiles-Header-Step-1"; shot.lifetime = .keepAlways; add(shot)
        addButton.tap()
        app.buttons["WireGuard"].tap()
        XCTAssertTrue(app.navigationBars["New Profile"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Manage your VPN connections"].exists)
    }

    func testDNSHeaderStepOne() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["DNS"].waitForExistence(timeout: 10))
        app.tabBars.buttons["DNS"].tap()
        XCTAssertTrue(app.staticTexts["Private. Encrypted. Under your control."].waitForExistence(timeout: 5))
        let settings = app.buttons["Advanced DNS Settings"]
        XCTAssertGreaterThanOrEqual(settings.frame.width, 43.99)
        XCTAssertGreaterThanOrEqual(settings.frame.height, 43.99)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DNS-Header-Step-1"; shot.lifetime = .keepAlways; add(shot)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Advanced DNS Settings"].waitForExistence(timeout: 5))
        app.buttons["DNS Security"].tap()
        XCTAssertTrue(app.navigationBars["DNS Security"].waitForExistence(timeout: 5))
    }

    func testHomeSessionTrafficStepThree() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        let timer = app.descendants(matching: .any)["HomeSessionTimer"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["DOWNLOAD"].exists)
        XCTAssertTrue(app.staticTexts["UPLOAD"].exists)
        XCTAssertTrue(app.staticTexts["VPN session traffic"].exists)
        if app.staticTexts["DISCONNECTED"].exists {
            XCTAssertEqual(timer.value as? String, "No active session")
            XCTAssertEqual(app.staticTexts.matching(identifier: "Unavailable").count, 2)
            XCTAssertEqual(app.staticTexts.matching(identifier: "Total unavailable").count, 2)
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Home-Session-Traffic-Step-3"; shot.lifetime = .keepAlways; add(shot)
    }

    func testHomeProtectionGridStepFour() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        for _ in 0..<3 {
            if app.buttons["HomeProtection-adblock"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["PROTECTION STATUS"].exists)
        for key in ["vpn", "dns", "safari", "adblock"] {
            let tile = app.buttons["HomeProtection-" + key]
            XCTAssertTrue(tile.exists)
            XCTAssertGreaterThanOrEqual(tile.frame.height, 111.99)
            XCTAssertFalse(tile.label.contains("Protecting"))
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Home-Protection-Step-4"; shot.lifetime = .keepAlways; add(shot)
        for (key, title) in [("vpn", "Connection Details"), ("dns", "Encrypted DNS"), ("safari", "Safari"), ("adblock", "Adblock")] {
            let tile = app.buttons["HomeProtection-" + key]
            for _ in 0..<3 { if tile.isHittable { break }; app.swipeUp() }
            tile.tap()
            if key == "dns" {
                XCTAssertTrue(app.buttons["DNSEnableProtection"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.tabBars.buttons["DNS"].isSelected)
                app.tabBars.buttons["Home"].tap()
            } else {
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
                app.navigationBars.buttons.firstMatch.tap()
            }
        }
    }

    func testHomeActionsActivityStepFive() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        for _ in 0..<4 { if app.buttons["HomeAllActivity"].isHittable { break }; app.swipeUp() }
        XCTAssertEqual(app.buttons.matching(identifier: "HomePrivacyChecks").count, 1)
        XCTAssertFalse(app.buttons["Switch Profile"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Home-Actions-Activity-Step-5"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["HomeAllActivity"].tap()
        XCTAssertTrue(app.navigationBars["Privacy Activity"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["HomePrivacyChecks"].tap()
        XCTAssertTrue(app.navigationBars["Checks"].waitForExistence(timeout: 5))
    }

    func testProfilesConnectionCardStepTwo() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Profiles"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Profiles"].tap()
        let details = app.buttons["ProfilesConnectionDetails"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(details.frame.height, 43.99)
        if app.staticTexts["No active VPN session"].exists {
            XCTAssertFalse(app.buttons["Disconnect"].exists)
            XCTAssertTrue(app.staticTexts["Selected profile"].exists)
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Profiles-Connection-Step-2"; shot.lifetime = .keepAlways; add(shot)
        details.tap()
        XCTAssertTrue(app.navigationBars["Connection Details"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Manage your VPN connections"].waitForExistence(timeout: 5))
    }

    func testProfilesListStepThree() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Profiles"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Profiles"].tap()
        let rows = app.buttons.matching(identifier: "ProfileListRow")
        for _ in 0..<3 { if rows.firstMatch.isHittable { break }; app.swipeUp() }
        XCTAssertGreaterThan(rows.count, 0)
        let count = rows.count
        let search = app.textFields["Search profiles"]
        search.tap(); search.typeText("zz-no-saved-profile-zz")
        XCTAssertTrue(app.staticTexts["No matching profiles"].waitForExistence(timeout: 5))
        app.buttons["Clear profile search"].tap()
        XCTAssertEqual(rows.count, count)
        app.buttons["Sort profiles"].tap()
        app.buttons["Name A–Z"].tap()
        XCTAssertTrue(rows.firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Profiles-List-Step-3"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Actions for us-den"].tap(); app.buttons["View Details"].tap()
        XCTAssertTrue(app.navigationBars["Profile Details"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
    }

    func testProfilesAddFlowStepFour() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Profiles"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Profiles"].tap()
        app.swipeDown()
        app.buttons["Add profile"].tap()
        XCTAssertTrue(app.navigationBars["Add Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import Configuration File"].exists)
        XCTAssertTrue(app.buttons["Import from Clipboard"].exists)
        XCTAssertTrue(app.buttons["Scan QR Code"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Profiles-Add-Step-4"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["WireGuard"].tap()
        XCTAssertTrue(app.navigationBars["New Profile"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.swipeDown()
        app.buttons["Add profile"].tap()
        XCTAssertTrue(app.navigationBars["Add Profile"].waitForExistence(timeout: 5))
        app.buttons["Import Configuration File"].tap()
        XCTAssertTrue(app.otherElements["Document Browser"].waitForExistence(timeout: 5) || app.buttons["Browse"].exists)
    }

    func testAllManualProtocolEditors() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "1"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Profiles"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Add profile"].waitForExistence(timeout: 5)); app.swipeDown()
        for (button, title) in [("IKEv2 / IPsec", "IKEv2 Profile"), ("WireGuard", "New Profile")] {
            app.buttons["Add profile"].tap()
            XCTAssertTrue(app.navigationBars["Add Profile"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["OpenVPN"].exists)
            app.buttons[button].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = title; shot.lifetime = .keepAlways; add(shot)
            app.buttons["Cancel"].tap()
        }
    }




    func testQRActualCameraStart() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Profiles"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Profiles"].tap(); app.swipeDown()
        app.buttons["Add profile"].tap(); app.buttons["Scan QR Code"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.alerts.firstMatch.waitForExistence(timeout: 3) {
            if system.alerts.buttons["Allow"].exists { system.alerts.buttons["Allow"].tap() }
            else if system.alerts.buttons["OK"].exists { system.alerts.buttons["OK"].tap() }
        }
        XCTAssertTrue(app.buttons["Stop Camera"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Continue to Camera"].exists)
        app.buttons["Stop Camera"].tap()
        XCTAssertTrue(app.buttons["Start Camera"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
    }

    func testCompactProfileDetailsAndEditor() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Profiles"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Profiles"].tap()
        let row = app.buttons.matching(identifier: "ProfileListRow").firstMatch
        for _ in 0..<3 { if row.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(row.exists)
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "Compact-Profiles"; list.lifetime = .keepAlways; add(list)
        app.buttons["Actions for us-den"].tap(); app.buttons["View Details"].tap()
        XCTAssertTrue(app.navigationBars["Profile Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Configuration"].exists)
        let details = XCTAttachment(screenshot: app.screenshot()); details.name = "Compact-Profile-Details"; details.lifetime = .keepAlways; add(details)
        for _ in 0..<4 { if app.buttons["Edit / Rename"].isHittable { break }; app.swipeUp() }
        app.buttons["Edit / Rename"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        let editor = XCTAttachment(screenshot: app.screenshot()); editor.name = "Compact-WireGuard-Editor"; editor.lifetime = .keepAlways; add(editor)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Profile Details"].waitForExistence(timeout: 5))
    }

    func testSavedIKEv2ConnectionAttempt() throws {
        guard ProcessInfo.processInfo.environment["VAYU_LIVE_IKE_TEST"] == "1" else { throw XCTSkip("Live VPN connection test requires explicit device-test opt-in.") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "1"]; app.launch()
        let profile = app.buttons["NativeProfileRow"]
        for _ in 0..<5 { if profile.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(profile.waitForExistence(timeout: 5)); profile.tap()
        XCTAssertFalse(app.navigationBars["IKEv2 Profile"].exists)
        sleep(15)
        app.tabBars.buttons["Home"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "IKEv2-Attempt-Result"; shot.lifetime = .keepAlways; add(shot)
    }

    func testUnifiedSavedProfiles() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "1"]; app.launch()
        let native = app.buttons["NativeProfileRow"], wg = app.buttons["ProfileListRow"]
        XCTAssertTrue(native.waitForExistence(timeout: 10)); XCTAssertTrue(wg.exists)
        XCTAssertFalse(app.staticTexts["PROTOCOL DRAFTS"].exists)
        let search = app.textFields["Search profiles"]
        search.tap(); search.typeText("IKEv2")
        XCTAssertTrue(native.exists); XCTAssertFalse(wg.exists)
        app.buttons["Clear profile search"].tap()
        XCTAssertTrue(native.exists); XCTAssertTrue(wg.exists)
        if wg.isHittable { wg.tap() }
        else { app.swipeUp(); wg.tap() }
        XCTAssertFalse(app.navigationBars["Profile Details"].exists)
        if app.buttons["Switch Profile"].waitForExistence(timeout: 2) {
            if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
            else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.12)).tap() }
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Unified-Profiles"; shot.lifetime = .keepAlways; add(shot)
    }

    func testConfirmedSwitchConnectsWireGuard() throws {
        guard ProcessInfo.processInfo.environment["VAYU_LIVE_IKE_TEST"] == "1" else { throw XCTSkip("Explicit live VPN test opt-in required.") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "1"]; app.launch()
        let wg = app.buttons["ProfileListRow"]
        for _ in 0..<4 { if wg.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(wg.waitForExistence(timeout: 5)); wg.tap()
        if app.buttons["Switch Profile"].waitForExistence(timeout: 2) { app.buttons["Switch Profile"].tap() }
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.alerts.firstMatch.waitForExistence(timeout: 2), system.alerts.buttons["Allow"].exists { system.alerts.buttons["Allow"].tap() }
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["Tunnel established"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["WireGuard"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "WireGuard-Confirmed-Switch"; shot.lifetime = .keepAlways; add(shot)
    }

    func testBidirectionalProfileSwitch() throws {
        guard ProcessInfo.processInfo.environment["VAYU_LIVE_IKE_TEST"] == "1" else { throw XCTSkip("Explicit live VPN test opt-in required.") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "1"]; app.launch()
        let cycles = min(2, max(1, Int(ProcessInfo.processInfo.environment["VAYU_SWITCH_CYCLES"] ?? "1") ?? 1))
        let transitions = (0..<cycles).flatMap { _ in [("ProfileListRow", "WireGuard"), ("NativeProfileRow", "IKEv2"), ("ProfileListRow", "WireGuard")] }
        for (identifier, proto) in transitions {
            app.tabBars.buttons["Profiles"].tap()
            let row = app.buttons[identifier]
            for _ in 0..<4 { if row.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(row.exists); row.tap()
            if app.buttons["Switch Profile"].waitForExistence(timeout: 3) { app.buttons["Switch Profile"].tap() }
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let permission = system.alerts.firstMatch
            if permission.waitForExistence(timeout: 2),
               permission.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "VPN")).firstMatch.exists,
               permission.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "VayuSetu")).firstMatch.exists,
               permission.buttons["Allow"].exists {
                permission.buttons["Allow"].tap()
            }
            app.tabBars.buttons["Home"].tap()
            XCTAssertTrue(app.staticTexts[proto].waitForExistence(timeout: 30))
            XCTAssertTrue(app.staticTexts["Tunnel established"].waitForExistence(timeout: 45), "Failed to establish " + proto)
            sleep(5)
            XCTAssertTrue(app.staticTexts["Tunnel established"].exists)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Switch-To-" + proto; shot.lifetime = .keepAlways; add(shot)
        }
    }

    func testLiveExitAndDNSEvidence() throws {
        guard ProcessInfo.processInfo.environment["VAYU_LIVE_IKE_TEST"] == "1" else { throw XCTSkip("Explicit live VPN test opt-in required.") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "1", "--connection-audit"]; app.launch()
        for (identifier, proto) in [("ProfileListRow", "WireGuard"), ("NativeProfileRow", "IKEv2")] {
            app.tabBars.buttons["Profiles"].tap()
            let row = app.buttons[identifier]
            for _ in 0..<4 { if row.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(row.exists); row.tap()
            if app.buttons["Switch Profile"].waitForExistence(timeout: 3) { app.buttons["Switch Profile"].tap() }
            app.tabBars.buttons["Home"].tap()
            XCTAssertTrue(app.staticTexts["Tunnel established"].waitForExistence(timeout: 45), "Start " + proto)
            let completion = app.alerts.staticTexts["Connection audit complete · " + proto]
            XCTAssertTrue(completion.waitForExistence(timeout: 180), "Measurement completion " + proto)
            app.alerts.buttons["OK"].tap()
            XCTAssertTrue(app.staticTexts[proto].exists)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Measured-" + proto; shot.lifetime = .keepAlways; add(shot)
        }
        // Restore the profile that was active before the audit.
        app.tabBars.buttons["Profiles"].tap(); app.buttons["ProfileListRow"].tap()
        if app.buttons["Switch Profile"].waitForExistence(timeout: 3) { app.buttons["Switch Profile"].tap() }
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["WireGuard"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Tunnel established"].waitForExistence(timeout: 45))
    }

    func testDNSStatusCardStepTwo() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "2"]; app.launch()
        XCTAssertTrue(app.staticTexts["Private. Encrypted. Under your control."].waitForExistence(timeout: 10))
        let change = app.buttons["DNSChangeResolver"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(change.frame.height, 44)
        XCTAssertTrue(app.staticTexts["DNSObservedMode"].exists)
        XCTAssertTrue(app.staticTexts["DNSObservedResolver"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DNS-Status-Card-Step-2"; shot.lifetime = .keepAlways; add(shot)
        change.tap()
        XCTAssertTrue(app.navigationBars["DNS Resolvers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Search resolvers"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["DNSChangeResolver"].waitForExistence(timeout: 5))
        app.buttons["Advanced DNS Settings"].tap()
        XCTAssertTrue(app.navigationBars["Advanced DNS Settings"].waitForExistence(timeout: 5))
    }

    func testDNSModeSelectionStepThree() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "2"]; app.launch()
        let mode = app.buttons["DNSModeSelection"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10)); mode.tap()
        XCTAssertTrue(app.navigationBars["DNS Mode"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["DNSMode-Local DNS Filtering"].exists, "Filtering must not be a transport radio option")
        XCTAssertFalse(app.buttons["DNSModeApply"].isEnabled, "Unchanged System DNS must be disabled when no saved OS configuration exists")
        app.buttons["DNSMode-VPN-Managed DNS"].tap()
        XCTAssertTrue(app.buttons["DNSModeApply"].isEnabled, "A valid selected VPN should have an actionable Apply")
        app.buttons["DNSModeApply"].tap()
        XCTAssertTrue(app.alerts["Change DNS Mode?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "then connect")).firstMatch.exists)
        app.alerts.buttons["Cancel"].tap()
        app.buttons["DNSMode-Encrypted DNS"].tap()
        XCTAssertTrue(app.buttons["DNSModeApply"].isEnabled, "VPN must be off and a valid resolver selected for this test")
        let current = app.descendants(matching: .any)["DNSModeCurrent"].firstMatch.label
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DNS-Mode-Step-3"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["DNSModeApply"].tap()
        XCTAssertTrue(app.alerts["Change DNS Mode?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["DNSModeCurrent"].firstMatch.label, current)
        XCTAssertFalse(app.staticTexts["DNSModeOutcome"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["DNSChangeResolver"].waitForExistence(timeout: 5))
    }

    func testDNSModeConfigurationRoundTrip() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "2"]; app.launch()
        XCTAssertTrue(app.buttons["DNSModeSelection"].waitForExistence(timeout: 10)); app.buttons["DNSModeSelection"].tap()
        XCTAssertTrue(app.navigationBars["DNS Mode"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["DNSModeApply"].isEnabled, "Requires VPN off and no prior independent DNS config; never overwrite an existing setup")
        if app.buttons["DNSModeRemoveSaved"].exists {
            app.buttons["DNSModeRemoveSaved"].tap(); app.alerts["Change DNS Mode?"].buttons["Apply"].tap()
            let cleared = NSPredicate(format: "exists == false")
            expectation(for: cleared, evaluatedWith: app.buttons["DNSModeRemoveSaved"]); waitForExpectations(timeout: 20)
        }
        app.buttons["DNSMode-Encrypted DNS"].tap()
        XCTAssertTrue(app.buttons["DNSModeResolver"].exists)
        app.buttons["DNSModeResolver"].tap()
        XCTAssertTrue(app.navigationBars["DNS Resolvers"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["DNSModeSelected"].firstMatch.label.contains("Encrypted DNS"), "Resolver navigation must preserve the draft mode")
        XCTAssertTrue(app.buttons["DNSModeApply"].isEnabled)
        app.buttons["DNSModeApply"].tap()
        XCTAssertTrue(app.alerts["Change DNS Mode?"].waitForExistence(timeout: 3))
        app.alerts["Change DNS Mode?"].buttons["Apply"].tap()
        let activation = app.staticTexts["DNSModeActivation"]
        XCTAssertTrue(activation.waitForExistence(timeout: 20), "Must disclose saved-but-disabled iOS configuration")
        XCTAssertFalse(app.buttons["DNSModeApply"].isEnabled, "Repeated saving cannot activate the same resolver")
        XCTAssertTrue(app.descendants(matching: .any)["DNSModeCurrent"].firstMatch.label.contains("System DNS"), "Saving alone must not claim encrypted DNS active")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DNS-Mode-Activation-Required"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["DNSMode-System DNS"].tap()
        XCTAssertFalse(app.buttons["DNSModeApply"].isEnabled)
        app.buttons["DNSModeRemoveSaved"].tap(); app.alerts["Change DNS Mode?"].buttons["Apply"].tap()
        let removed = NSPredicate(format: "label CONTAINS %@", "configuration removed")
        XCTAssertTrue(app.staticTexts["DNSModeOutcome"].waitForExistence(timeout: 20))
        expectation(for: removed, evaluatedWith: app.staticTexts["DNSModeOutcome"])
        waitForExpectations(timeout: 20)
        XCTAssertFalse(app.staticTexts["DNSModeActivation"].exists)
        XCTAssertFalse(app.buttons["DNSModeApply"].isEnabled)
    }

    func testDNSModeVPNConnectionRoundTrip() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "2"]; app.launch()
        XCTAssertTrue(app.buttons["DNSModeSelection"].waitForExistence(timeout: 10)); app.buttons["DNSModeSelection"].tap()
        XCTAssertTrue(app.navigationBars["DNS Mode"].waitForExistence(timeout: 5))
        app.buttons["DNSMode-VPN-Managed DNS"].tap()
        XCTAssertTrue(app.buttons["DNSModeApply"].isEnabled, "A usable selected profile is required")
        app.buttons["DNSModeApply"].tap()
        XCTAssertTrue(app.alerts["Change DNS Mode?"].waitForExistence(timeout: 3)); app.alerts.buttons["Apply"].tap()
        let current = app.descendants(matching: .any)["DNSModeCurrent"].firstMatch
        let connected = NSPredicate(format: "label CONTAINS %@", "VPN-Managed DNS")
        expectation(for: connected, evaluatedWith: current); waitForExpectations(timeout: 60)
        XCTAssertFalse(app.buttons["DNSModeApply"].isEnabled, "An already connected VPN must not reconnect")
        XCTAssertFalse(app.staticTexts["DNSModeOutcome"].label.contains("did not connect"), "A late connected notification must supersede stale failure text")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DNS-Mode-VPN-Connected"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["DNSMode-System DNS"].tap(); app.buttons["DNSModeApply"].tap()
        XCTAssertTrue(app.alerts["Change DNS Mode?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Disconnect the VPN first")).firstMatch.exists)
        app.alerts.buttons["Apply"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "System DNS"), evaluatedWith: current); waitForExpectations(timeout: 20)
        XCTAssertFalse(app.buttons["DNSModeApply"].isEnabled)
    }

    func testHomeDNSOpensCanonicalTab() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing"]; app.launch()
        let tile = app.buttons["HomeProtection-dns"]
        for _ in 0..<5 { if tile.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(tile.waitForExistence(timeout: 5)); tile.tap()
        XCTAssertTrue(app.buttons["DNSEnableProtection"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["DNS"].isSelected)
        XCTAssertFalse(app.tabBars.buttons["Home"].isSelected)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DNS-Canonical-Tab"; shot.lifetime = .keepAlways; add(shot)
    }

    func testDNSProtectionNativeSetupFlow() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "2"]; app.launch()
        let enable = app.buttons["DNSEnableProtection"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        if enable.label == "Finish Activation in iOS Settings" {
            // A real user may have left our own saved configuration awaiting activation.
            app.buttons["DNSModeSelection"].tap()
            app.buttons["DNSModeRemoveSaved"].tap()
            XCTAssertTrue(app.alerts["Change DNS Mode?"].waitForExistence(timeout: 3)); app.alerts.buttons["Apply"].tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["DNSModeRemoveSaved"]); waitForExpectations(timeout: 20)
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertEqual(enable.label, "Enable Encrypted DNS", "Requires VPN off and no pending DNS activation")
        XCTAssertFalse(app.staticTexts["DNSActivationHandoff"].exists, "Do not send user to Settings before attempting native configuration")
        app.buttons["DNSChangeResolver"].tap()
        XCTAssertTrue(app.navigationBars["DNS Resolvers"].waitForExistence(timeout: 5)); app.navigationBars.buttons.firstMatch.tap()
        enable.tap()
        XCTAssertTrue(app.navigationBars["Activate Encrypted DNS"].waitForExistence(timeout: 20))
        app.buttons["DNSActivationCheck"].tap()
        XCTAssertEqual(enable.label, "Finish Activation in iOS Settings")
        enable.tap()
        XCTAssertTrue(app.navigationBars["Activate Encrypted DNS"].waitForExistence(timeout: 5))
        app.buttons["DNSActivationCheck"].tap()
        XCTAssertTrue(app.buttons["DNSRefreshStatus"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["DNSObservedMode"].firstMatch.label.contains("System DNS"), "Saved configuration must not become an active protection claim")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DNS-Protection-Native-Setup"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["DNSModeSelection"].tap()
        XCTAssertTrue(app.buttons["DNSModeRemoveSaved"].waitForExistence(timeout: 5)); app.buttons["DNSModeRemoveSaved"].tap()
        XCTAssertTrue(app.alerts["Change DNS Mode?"].waitForExistence(timeout: 3)); app.alerts.buttons["Apply"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["DNSModeRemoveSaved"]); waitForExpectations(timeout: 20)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertEqual(enable.label, "Enable Encrypted DNS")
        XCTAssertFalse(app.staticTexts["DNSActivationHandoff"].exists)
    }

    func testDNSSuspensionRestoresAfterHomeDisconnect() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "2"]; app.launch()
        let enable = app.buttons["DNSEnableProtection"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        XCTAssertEqual(enable.label, "Enable Encrypted DNS", "Run after native setup cleanup, with VPN off")
        enable.tap()
        XCTAssertTrue(app.navigationBars["Activate Encrypted DNS"].waitForExistence(timeout: 20)); app.buttons["DNSActivationCheck"].tap()
        app.buttons["DNSModeSelection"].tap()
        app.buttons["DNSMode-VPN-Managed DNS"].tap(); app.buttons["DNSModeApply"].tap()
        XCTAssertTrue(app.alerts["Change DNS Mode?"].waitForExistence(timeout: 3)); app.alerts.buttons["Apply"].tap()
        let current = app.descendants(matching: .any)["DNSModeCurrent"].firstMatch
        expectation(for: NSPredicate(format: "label CONTAINS %@", "VPN-Managed DNS"), evaluatedWith: current); waitForExpectations(timeout: 60)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["DNSSuspendedPreference"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["HomeVPNPower"].waitForExistence(timeout: 5)); app.buttons["HomeVPNPower"].tap()
        app.tabBars.buttons["DNS"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Finish Activation in iOS Settings"), evaluatedWith: enable); waitForExpectations(timeout: 40)
        XCTAssertTrue(app.descendants(matching: .any)["DNSObservedMode"].firstMatch.label.contains("System DNS"), "Restoration must not fabricate OS activation")
        XCTAssertFalse(app.staticTexts["DNSSuspendedPreference"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DNS-Restored-After-VPN"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["DNSModeSelection"].tap()
        XCTAssertTrue(app.buttons["DNSModeRemoveSaved"].waitForExistence(timeout: 10))
        app.buttons["DNSModeRemoveSaved"].tap()
        XCTAssertTrue(app.alerts["Change DNS Mode?"].waitForExistence(timeout: 3)); app.alerts.buttons["Apply"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["DNSModeRemoveSaved"]); waitForExpectations(timeout: 20)
    }

    func testProfileProtectionPresentation() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "1"]; app.launch()
        XCTAssertTrue(app.buttons["ProfilesConnectionDetails"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["ProfilesBottomAdd"].exists)
        app.buttons["ProfilesConnectionDetails"].tap()
        XCTAssertTrue(app.navigationBars["Connection Details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Profiles"].isHittable)
        let connectionShot = XCTAttachment(screenshot: app.screenshot()); connectionShot.name = "Connection-Details-Refined"; connectionShot.lifetime = .keepAlways; add(connectionShot)
        let privacy = app.buttons["ConnectionPrivacyLock"]
        for _ in 0..<5 { if privacy.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(privacy.exists); privacy.tap()
        XCTAssertTrue(app.navigationBars["Privacy Lock"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Require dual-stack WireGuard profile"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Strict capture:")).firstMatch.exists)
        let privacyShot = XCTAttachment(screenshot: app.screenshot()); privacyShot.name = "Privacy-Lock-Refined"; privacyShot.lifetime = .keepAlways; add(privacyShot)
        let technical = app.buttons["PrivacyTechnicalDetails"]
        for _ in 0..<5 { if technical.isHittable { break }; app.swipeUp() }
        technical.tap()
        XCTAssertTrue(app.navigationBars["Routing & Verification"].waitForExistence(timeout: 5))
        let technicalShot = XCTAttachment(screenshot: app.screenshot()); technicalShot.name = "Routing-Technical-Details"; technicalShot.lifetime = .keepAlways; add(technicalShot)
        app.navigationBars.buttons.firstMatch.tap()
        let reset = app.buttons["Emergency Reset"]
        for _ in 0..<5 { if reset.isHittable { break }; app.swipeDown() }
        reset.tap()
        XCTAssertTrue(app.navigationBars["Emergency Reset"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Preserved data"].exists)
        // Inspect recovery copy only; never reset the user's VPN/DNS as a layout test.
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Profiles"].isHittable)
    }

    func testCompactDNSOverviewAndPreferenceMeaning() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.vayusetu.ios")
        app.launchArguments = ["--ui-testing", "--ui-tab", "2"]; app.launch()
        XCTAssertTrue(app.buttons["DNSChangeResolver"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["Search resolvers"].exists, "The overview should not embed the resolver library")
        XCTAssertTrue(app.descendants(matching: .any)["DNSPreferredResolver"].firstMatch.exists)
        let diagnostics = app.buttons["DNS Diagnostics"]
        XCTAssertTrue(diagnostics.isHittable, "Overview actions must fit above the tab bar at default text size")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DNS-Compact-Overview"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["DNSChangeResolver"].tap()
        XCTAssertTrue(app.navigationBars["DNS Resolvers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Preferred · saved choice")).firstMatch.exists)
        let library = XCTAttachment(screenshot: app.screenshot()); library.name = "DNS-Preferred-Library"; library.lifetime = .keepAlways; add(library)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Advanced DNS Settings"].tap()
        app.buttons["Connection Mode"].tap()
        XCTAssertTrue(app.navigationBars["Routing Policy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["DNS through VPN"].exists)
        XCTAssertFalse(app.staticTexts["VPN → DNS"].exists)
    }

}
