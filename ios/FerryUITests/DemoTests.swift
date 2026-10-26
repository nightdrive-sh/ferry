import XCTest

/// "Try without a computer" from a fresh install: the demo's pretend computers, inside the app with no network (the
/// mock isn't asked). With FERRY_SHOTS set (`TEST_RUNNER_FERRY_SHOTS=<folder> ios/uitest.sh …`) it saves pictures of
/// each step there.
@MainActor
final class DemoTests: XCTestCase {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }

    func launch(_ extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-reset", "-pasteHelpSeen", "YES"] + extra
        app.launch()
    }

    func row(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    func shot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["FERRY_SHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
    }

    /// Into the demo from the setup screen; the notifications prompt comes as it does after a real setup.
    func tryDemo(notifications: Bool) {
        let tryIt = app.buttons["Try without a computer"]
        XCTAssertTrue(tryIt.waitForExistence(timeout: 10))
        XCTAssertTrue(element("Get Ferry for your computer").exists)   // for someone with no computer running Ferry yet
        shot("1-setup")
        tryIt.tap()
        if notifications {
            let turnOn = app.buttons["Turn On Notifications"]
            XCTAssertTrue(turnOn.waitForExistence(timeout: 5))
            turnOn.tap()
            // The second button allows, in whatever language the simulator speaks; asked once per install
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 5) { alert.buttons.element(boundBy: 1).tap() }
        }
        XCTAssertTrue(app.buttons["Leave Demo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.online("2/2 online").waitForExistence(timeout: 5))
    }

    func testTheDemoSendsReceivesAndLeaves() {
        launch(["-notificationsAsked", "NO", "-seedClipboard", "demo-clip-310"])
        tryDemo(notifications: true)
        XCTAssertTrue(row("screenshot.png").waitForExistence(timeout: 5))
        XCTAssertTrue(row("https://nightdrive.sh/ferry").exists)
        XCTAssertTrue(element("Send MacBook something").exists)   // the hint: what to try
        shot("2-demo")

        app.buttons["Type a text"].tap()
        let field = app.textFields["Text or link"].exists ? app.textFields["Text or link"] : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("typed in the demo")
        app.buttons["Send"].tap()
        // Where it went, until MacBook's reply 3 s after this first send
        XCTAssertTrue(element("Received is for what your computers send you").waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Send Clipboard"].waitForExistence(timeout: 8))
        XCTAssertFalse(field.exists)

        app.buttons["sendClipboard"].tap()
        XCTAssertTrue(app.staticTexts["Sent to MacBook"].waitForExistence(timeout: 5))
        shot("3-sent")

        // MacBook sends something back after the first send, and its notification shows with Ferry open
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Hello from MacBook'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        shot("4-notification")
        XCTAssertTrue(row("Hello from MacBook").waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["demoHint"].exists)   // answered: nothing more to say
        banner.tap()
        XCTAssertTrue(app.staticTexts["Copied"].waitForExistence(timeout: 5))
        shot("5-copied")

        app.buttons["Leave Demo"].tap()
        XCTAssertTrue(app.buttons["Try without a computer"].waitForExistence(timeout: 5))
    }

    func testTheDemoSendsAPhotoAndIsLeftFromSettings() {
        launch(["-notificationsAsked", "YES", "-seedClipboardImage"])
        tryDemo(notifications: false)
        app.buttons["sendClipboard"].tap()
        XCTAssertTrue(app.staticTexts["Sent to MacBook"].waitForExistence(timeout: 5))

        app.settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Add a Computer"].exists)   // the computers are pretend: no adding a real one
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'python3-cryptography'")).firstMatch.exists)
        for link in ["Ferry Website", "Email Support", "Privacy Policy"] {
            app.swipeUp()
            XCTAssertTrue(element(link).waitForExistence(timeout: 2), link)
        }
        shot("6-settings")
        app.buttons["settingsLeaveDemo"].tap()
        XCTAssertTrue(app.buttons["Try without a computer"].waitForExistence(timeout: 5))
    }

    /// MacBook's reply is timed inside the app: Ferry keeps running for it when the phone is locked (or another app
    /// is opened) right after the first send, so its notification comes then, not at the next unlock.
    func testTheDemosReplyNotifiesWithFerryInTheBackground() {
        launch(["-notificationsAsked", "NO", "-seedClipboard", "demo-clip-background"])
        tryDemo(notifications: true)
        app.buttons["sendClipboard"].tap()
        XCTAssertTrue(app.staticTexts["Sent to MacBook"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Hello from MacBook'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        banner.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.staticTexts["Copied"].waitForExistence(timeout: 5))
    }

    /// The demo lives in memory only: the next launch is at setup again.
    func testTheDemoDoesntOutliveTheApp() {
        launch(["-notificationsAsked", "YES"])
        tryDemo(notifications: false)
        app.terminate()
        app.launchArguments = ["-notificationsAsked", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Try without a computer"].waitForExistence(timeout: 10))
    }
}
