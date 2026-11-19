import XCTest

/// Every screen in fixture mode. Pass `TEST_RUNNER_SHOWCASE_SHOTS=<dir>` to xcodebuild to also
/// write each screenshot there as a PNG; they are always attached to the result bundle.
final class ShowcaseUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["SHOWCASE_RESET"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["home.mode"].waitForExistence(timeout: 20))
    }

    func testEveryScreenInFixtureMode() throws {
        XCTAssertEqual(app.staticTexts["home.mode"].label, "Fixture")
        shot("00-home")

        step("Gate content") {
            open("gate")
            XCTAssertTrue(text("gate.access").waitForLabel("Access granted"))
            app.buttons["Premium · article/2"].tap()
            XCTAssertTrue(text("gate.access").waitForLabel("No access"))
            shot("01-gate-content")
            back()
        }

        step("Metered access: three new items consume, a repeat does not, the fourth is locked") {
            open("metered")
            app.buttons["metered.item.1"].tap()
            XCTAssertTrue(text("metered.remaining").waitForLabel("2 of 3"))
            XCTAssertEqual(text("metered.consumed").label, "yes")
            app.buttons["metered.item.1"].tap()
            XCTAssertTrue(text("metered.used").waitForLabel("yes"))
            XCTAssertEqual(text("metered.remaining").label, "2 of 3")
            XCTAssertEqual(text("metered.consumed").label, "no")
            app.buttons["metered.item.2"].tap()
            XCTAssertTrue(text("metered.remaining").waitForLabel("1 of 3"))
            app.buttons["metered.item.3"].tap()
            XCTAssertTrue(text("metered.remaining").waitForLabel("0 of 3"))
            app.buttons["metered.item.4"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["metered.locked"].waitForExistence(timeout: 10))
            shot("02-metered-access")
            back()
        }

        step("Feature switch: ads on for an anonymous reader") {
            open("featureSwitch")
            XCTAssertTrue(text("feature.state").waitForLabel("on"))
            XCTAssertTrue(text("feature.adSlot").exists)
            shot("03-feature-switch")
            back()
        }

        step("Surface properties") {
            open("surfaceProperties")
            XCTAssertTrue(text("surface.banner").waitForLabel("Sign in to keep your reading list on every device."))
            shot("04-surface-properties")
            back()
        }

        step("Native paywall: copy from the experience, an offer redeems to custom:storekit") {
            open("nativePaywall")
            XCTAssertTrue(text("paywall.headline").waitForLabel("Unlock premium articles"))
            app.buttons["paywall.offer.0"].tap()
            XCTAssertTrue(text("lastCall.json").waitForLabel("custom:storekit", contains: true))
            shot("05-native-paywall")
            back()
        }

        step("Web paywall: the price provider fills the page, a plan redeems") {
            open("webPaywall")
            let page = app.webViews.firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 20))
            // The page's fallback says $4.99; the PriceProvider's €4.99 replaces it.
            let monthly = page.links.matching(NSPredicate(format: "label CONTAINS 'Monthly'")).firstMatch
            XCTAssertTrue(monthly.waitForLabel("€4.99 / month", contains: true), monthly.label)
            shot("06-web-paywall")
            monthly.tap()
            // Elements after the web view drop out of the accessibility tree, so the event row sits above it.
            XCTAssertTrue(text("webPaywall.event").waitForLabel("onRedemption: redeemed, custom:storekit"))
            back()
        }

        step("Redeem an offer: custom, navigate, none, declined, and a repeat claim declined") {
            open("redeem")
            let outcome = text("redeem.outcome")
            XCTAssertTrue(app.buttons["redeem.offer.3"].waitForExistence(timeout: 10))
            app.buttons["redeem.offer.0"].tap()
            XCTAssertTrue(outcome.waitForLabel("Redeemed: custom:storekit", contains: true))
            app.buttons["redeem.offer.1"].tap()
            XCTAssertTrue(outcome.waitForLabel("Redeemed: navigate", contains: true))
            app.buttons["redeem.offer.2"].tap()
            XCTAssertTrue(outcome.waitForLabel("Redeemed: none", contains: true))
            app.buttons["redeem.offer.3"].tap()
            XCTAssertTrue(outcome.waitForLabel("Declined (410)", contains: true))
            app.buttons["redeem.offer.2"].tap()
            XCTAssertTrue(outcome.waitForLabel("Declined (409)", contains: true))
            shot("07-redeem-offer")
            back()
        }

        step("Sign in links the anonymous reader; sign out goes back to it") {
            open("signIn")
            XCTAssertTrue(text("signIn.anonymousId").waitForLabel("mos-anon", contains: true))
            app.buttons["signIn.signIn"].tap()
            XCTAssertTrue(text("signIn.identify").waitForLabel("anonymous → jwt"))
            XCTAssertTrue(text("signIn.linked").waitForLabel("true"))
            XCTAssertTrue(text("signIn.decisionIdentity").label.contains("jwt: sample-user-1"))
            shot("08-sign-in")
            app.buttons["signIn.signOut"].tap()
            XCTAssertTrue(text("signIn.identify").waitForLabel("jwt → anonymous"))
            XCTAssertTrue(text("signIn.decisionIdentity").waitForLabel("anonymous", contains: true))
            back()
        }

        step("Offline: network, cache, fallback, unavailable, then flush the queued meters") {
            open("offline")
            app.buttons["offline.decide.1"].tap()
            XCTAssertTrue(text("offline.source").waitForLabel("network"))
            app.switches["offline.toggle"].switches.firstMatch.tap()
            app.buttons["offline.decide.1"].tap()
            XCTAssertTrue(text("offline.source").waitForLabel("cache", contains: true))
            app.buttons["offline.decide.2"].tap()
            XCTAssertTrue(text("offline.source").waitForLabel("fallback (from offline/1)"))
            XCTAssertTrue(text("offline.queued").waitForLabel("2"))
            app.buttons["offline.flushButton"].tap()
            XCTAssertTrue(text("offline.flush").waitForLabel("sent 0, remaining 2, requestFailed"))
            app.buttons["offline.clearCache"].tap()
            app.buttons["offline.decide.1"].tap()
            XCTAssertTrue(text("offline.source").waitForLabel("unavailable"))
            XCTAssertEqual(text("offline.hasAccess").label, "true")
            shot("09-offline")
            app.switches["offline.toggle"].switches.firstMatch.tap()
            app.buttons["offline.flushButton"].tap()
            XCTAssertTrue(text("offline.flush").waitForLabel("sent 2, remaining 0"))
            XCTAssertTrue(text("offline.queued").waitForLabel("0"))
            back()
        }

        step("App endpoints: a GET answers 200, a POST echoes its body") {
            open("endpoints")
            app.buttons["endpoints.get"].tap()
            XCTAssertTrue(text("endpoints.status").waitForLabel("HTTP 200"))
            XCTAssertTrue(text("lastCall.json").waitForLabel("Sample User", contains: true), text("lastCall.json").label)
            shot("10-app-endpoints")
            app.buttons["endpoints.post"].tap()
            XCTAssertTrue(text("endpoints.status").waitForLabel("HTTP 201"))
            XCTAssertTrue(text("lastCall.json").label.contains("Note 1"), text("lastCall.json").label)
            back()
        }

        step("Settings") {
            app.buttons["home.settings"].tap()
            XCTAssertTrue(app.buttons["settings.resetIdentity"].waitForExistence(timeout: 10))
            shot("11-settings")
            app.buttons["settings.resetIdentity"].tap()
            XCTAssertTrue(text("settings.note").waitForExistence(timeout: 10))
            app.buttons["Cancel"].tap()
            XCTAssertTrue(text("home.identity").waitForLabel("Anonymous", contains: true))
        }
    }

    // MARK: Steps

    private func step(_ name: String, _ body: () -> Void) {
        XCTContext.runActivity(named: name) { _ in body() }
    }

    private func open(_ screen: String) {
        let row = app.buttons["home.\(screen)"]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.staticTexts["screen.explainer"].waitForExistence(timeout: 10))
    }

    private func back() {
        // Not navigationBars.buttons: iPhone Duo's cover display puts Back in a side toolbar.
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["MOS Showcase"].waitForExistence(timeout: 10))
        // Back on Home, scroll to the top so the next row lookup starts from the same place.
        for _ in 0..<3 where !app.staticTexts["home.mode"].isHittable { app.swipeDown() }
    }

    private func text(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SHOWCASE_SHOTS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
        }
    }
}

private extension XCUIElement {
    /// Waits for the label to equal `text`, or to contain it.
    func waitForLabel(_ text: String, contains: Bool = false, timeout: TimeInterval = 15) -> Bool {
        let predicate = contains ? NSPredicate(format: "label CONTAINS %@", text) : NSPredicate(format: "label == %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
