import XCTest

/// The share view against the mock, shown over the app by -shareText / -shareImage, as the share extension builds it.
/// What arrives is checked by ios/uitest.sh from the mock's log. MacBook is in use (idle 0), Nightdrive was used 20 min
/// ago.
@MainActor
final class ShareTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// Set up with the mock first (the App Group's list is what a share reads), then opened again with the share.
    func launch(sharing: [String], setup: [String] = ["-mock"], online: String = "2/2 online") {
        app = XCUIApplication()
        app.launchArguments = ["-reset", "-pasteHelpSeen", "YES", "-notificationsAsked", "YES"] + setup
        app.launch()
        XCTAssertTrue(app.online(online).waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["-pasteHelpSeen", "YES", "-notificationsAsked", "YES"] + sharing
        app.launch()
    }

    func testSeveralAnswerAndATapSends() {
        launch(sharing: ["-shareText", "shared hello"])
        let macbook = app.buttons["MacBook"], nightdrive = app.buttons["Nightdrive"]
        XCTAssertTrue(nightdrive.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { nightdrive.isEnabled && macbook.isEnabled })
        XCTAssertLessThan(macbook.frame.minY, nightdrive.frame.minY)   // the one in use first
        nightdrive.tap()
        XCTAssertTrue(app.staticTexts["Sent to Nightdrive"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["MacBook"].exists)   // the whole sheet is the confirmation, not a row under the list
        XCTAssertTrue(app.buttons["sendClipboard"].waitForExistence(timeout: 5))   // the sheet closed by itself
    }

    func testAnImageGoesThroughTheBackgroundSession() {
        launch(sharing: ["-shareImage"])
        let macbook = app.buttons["MacBook"]
        XCTAssertTrue(macbook.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["share.png"].exists)
        XCTAssertTrue(waitUntil { macbook.isEnabled })
        macbook.tap()
        XCTAssertTrue(app.staticTexts["Sent to MacBook"].waitForExistence(timeout: 15))
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}

/// With the mock started as `ios/uitest.sh --down Nightdrive` (it sets FERRY_DOWN for the runner).
@MainActor
final class ShareDownTests: XCTestCase {
    func testTheOnlyComputerThatAnswersGetsItWithoutATap() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FERRY_DOWN"] == "Nightdrive", "needs uitest.sh --down Nightdrive")
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-seedMachines", "-pasteHelpSeen", "YES", "-notificationsAsked", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["sendClipboard"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["-pasteHelpSeen", "YES", "-notificationsAsked", "YES", "-shareText", "auto"]
        app.launch()
        // Nightdrive's port is closed, so it fails at once: the send goes without a tap and the sheet has closed again
        // before the runner could see it, so MacBook is asked what arrived
        XCTAssertTrue(app.buttons["sendClipboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForText("auto", on: URL(string: "http://127.0.0.1:47271/ferry/")!))
        XCTAssertFalse(app.buttons["Nightdrive"].exists)   // no list left waiting for a tap
    }
}

/// The real share extension, from Safari's share sheet: best effort, since it drives another app's system UI.
@MainActor
final class ShareSheetTests: XCTestCase {
    func testSafariLinkThroughTheShareSheet() {
        let ferry = XCUIApplication()
        ferry.launchArguments = ["-reset", "-mock", "-pasteHelpSeen", "YES", "-notificationsAsked", "YES"]
        ferry.launch()
        XCTAssertTrue(ferry.online("2/2 online").waitForExistence(timeout: 15))

        // Safari 26 keeps Share in its More menu; identifiers, since the simulator may run in any language
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.open(URL(string: "http://127.0.0.1:47271/ferry/")!)
        XCTAssertTrue(safari.buttons["MoreMenuButton"].waitForExistence(timeout: 15))
        safari.buttons["MoreMenuButton"].tap()
        XCTAssertTrue(safari.buttons["ShareButton"].waitForExistence(timeout: 5))
        safari.buttons["ShareButton"].tap()
        let cell = safari.cells.matching(NSPredicate(format: "identifier == 'shareCell' AND label == 'Ferry'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()

        let macbook = safari.buttons["MacBook"]
        XCTAssertTrue(macbook.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: macbook)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(safari.staticTexts["http://127.0.0.1:47271/ferry/"].exists)   // the link, not the page title
        macbook.tap()
        // "Sent to MacBook" shows for 2 s inside another app's sheet, which the runner doesn't always catch: MacBook
        // is asked what arrived
        XCTAssertTrue(waitForText("http://127.0.0.1:47271/ferry/", on: URL(string: "http://127.0.0.1:47271/ferry/")!))
    }
}
