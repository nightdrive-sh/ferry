import XCTest

/// Notifications end to end in the simulator: the mock computer encrypts and signs as bin/ferry does, the local relay
/// (ios/uitest.sh) hands the push to the simulator with simctl, and the app's extension opens it. The clipboard after a
/// tap is printed by uitest.sh (`simctl pbpaste`): the test runner reading it would stop at iOS's Paste prompt.
@MainActor
final class NotificationTests: XCTestCase {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }

    func start() {
        // The app starts over with -reset; the mock would still notify the last test's subscription, and a tap on that
        // banner names an address the fresh app never made
        for port in [47271, 47272] { mock("DELETE", "/mock/subs", port: port) }
        app = XCUIApplication()
        app.launchArguments = ["-reset", "-mock", "-pasteHelpSeen", "YES", "-notificationsAsked", "NO",
                               "-relay", "http://127.0.0.1:47280/", "-fakeToken"]
        app.launch()
        turnOnNotifications()
        waitForSubscription()
    }

    /// The prompt after setup, then iOS's own question (asked only the first time this simulator runs Ferry).
    func turnOnNotifications() {
        let turnOn = app.buttons["Turn On Notifications"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10))
        turnOn.tap()
        // The second button allows, in whatever language the simulator speaks ("Allow", "Salli")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) { alert.buttons.element(boundBy: 1).tap() }
    }

    /// The app registers at the relay and subscribes on the mock computers in the background.
    func waitForSubscription(file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline {
            if let subs = mock("GET", "/mock/subs")?["subs"] as? [String], !subs.isEmpty { return }
            RunLoop.current.run(until: .now.addingTimeInterval(0.5))
        }
        XCTFail("the app never subscribed on MacBook", file: file, line: line)
    }

    func banner(_ text: String) -> XCUIElement {
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The simulator doesn't run notification service extensions for simulated pushes, so the banner there is the
    /// relay's fallback line; on a phone it is the text itself (docs/testing-on-device.md). The tap opens either.
    func ferryBanner(_ text: String) -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS 'Something arrived'", text)).firstMatch
    }

    func testTapCopiesText() {
        start()
        XCUIDevice.shared.press(.home)
        // Truly in the background first: a push that lands while the app is still on screen shows no banner, by design
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        RunLoop.current.run(until: .now.addingTimeInterval(1.5))
        mock("POST", "/mock/leave", ["text": "424242"])
        let notification = ferryBanner("424242")
        XCTAssertTrue(notification.waitForExistence(timeout: 10))
        notification.tap()
        XCTAssertTrue(app.staticTexts["Copied"].waitForExistence(timeout: 8))   // Ferry is open, and says it copied
    }

    func testForegroundShowsNoBanner() {
        start()
        mock("POST", "/mock/leave", ["text": "777001"])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '777001'")).firstMatch
            .waitForExistence(timeout: 6))
        XCTAssertFalse(ferryBanner("777001").exists)
    }
}
