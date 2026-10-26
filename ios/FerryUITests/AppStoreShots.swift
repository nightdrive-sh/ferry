import XCTest

/// The App Store's screenshots, in the demo: `ios/appstore-shots.sh` runs this with FERRY_APPSTORE_SHOTS set to a
/// folder, and takes each picture itself with `simctl io screenshot` (the status bar it set, the device's own pixels).
/// The test asks for one by writing `<name>.want` there and waits for `<name>.png`. Skipped in a normal run. The names
/// are the App Store's order: the first three show in search results.
@MainActor
final class AppStoreShots: XCTestCase {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    var app: XCUIApplication!
    var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let path = ProcessInfo.processInfo.environment["FERRY_APPSTORE_SHOTS"]
        try XCTSkipUnless(path != nil, "only for ios/appstore-shots.sh")
        folder = URL(fileURLWithPath: path!)
    }

    func shot(_ name: String) {
        let png = folder.appending(path: "\(name).png")
        try? FileManager.default.removeItem(at: png)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))   // let animations settle
        FileManager.default.createFile(atPath: folder.appending(path: "\(name).want").path, contents: nil)
        let end = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: png.path), Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "no picture for \(name)")
    }

    func testShots() {
        app = XCUIApplication()
        app.launchArguments = ["-reset", "-pasteHelpSeen", "YES", "-notificationsAsked", "NO",
                               "-seedClipboard", "Wi-Fi password: violet-harbor-42"]
        app.launch()

        let tryIt = app.buttons["Try without a computer"]
        XCTAssertTrue(tryIt.waitForExistence(timeout: 10))
        shot("4-setup")   // first, before the demo's notification can cover it
        tryIt.tap()
        let turnOn = app.buttons["Turn On Notifications"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 5))
        turnOn.tap()
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) { alert.buttons.element(boundBy: 1).tap() }
        XCTAssertTrue(app.online("2/2 online").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'screenshot.png'")).firstMatch
            .waitForExistence(timeout: 5))

        // The computers, the one in use and the one that sleeps
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Send to MacBook'")).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Desktop'")).firstMatch
            .waitForExistence(timeout: 3))
        shot("3-computers")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()   // closes the menu

        app.buttons["Type a text"].tap()
        let field = app.textFields["Text or link"].exists ? app.textFields["Text or link"] : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        // A new simulator's keyboard first introduces slide to type, over the sheet
        let introduction = app.buttons["Continue"]
        if introduction.waitForExistence(timeout: 3) { introduction.tap() }
        field.typeText("Table for four at 7, I'll be a bit late")
        shot("2-compose")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Sent to MacBook"].waitForExistence(timeout: 8))

        // MacBook answers the first send, as a notification
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Hello from MacBook'")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        shot("1-arrived")
    }
}
