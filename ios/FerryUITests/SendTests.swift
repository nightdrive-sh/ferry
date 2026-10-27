import XCTest

/// Sending against the mock: what arrives is checked by ios/uitest.sh from the mock's log. MacBook is in use
/// (idle 0), Nightdrive was used 20 min ago.
@MainActor
final class SendTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// A fresh install set up with the mock. `clipboard` is put on the pasteboard by the app itself (-seedClipboard):
    /// copied by this runner, the app's read would stop at iOS's Paste prompt, which only a real device test covers.
    func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-reset", "-mock", "-pasteHelpSeen", "YES", "-notificationsAsked", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["sendClipboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.online("2/2 online").waitForExistence(timeout: 10))
    }

    func testSendClipboardTextToTheComputerInUse() {
        launch(["-seedClipboard", "801566"])
        app.buttons["sendClipboard"].tap()
        XCTAssertTrue(app.staticTexts["Sent to MacBook"].waitForExistence(timeout: 8))
    }

    func testSendClipboardImage() {
        launch(["-seedClipboardImage"])
        app.buttons["sendClipboard"].tap()
        XCTAssertTrue(app.staticTexts["Sent to MacBook"].waitForExistence(timeout: 8))
        XCTAssertEqual(lastFile(on: URL(string: "http://127.0.0.1:47271/ferry/")!)?["type"] as? String, "image/png")
    }

    /// A photo goes as the JPEG Photos copied, not encoded anew as a PNG five times its size
    func testSendClipboardPhotoAsItsJPEG() {
        launch(["-seedClipboardPhoto", "jpeg"])
        app.buttons["sendClipboard"].tap()
        XCTAssertTrue(app.staticTexts["Sent to MacBook"].waitForExistence(timeout: 8))
        let file = lastFile(on: URL(string: "http://127.0.0.1:47271/ferry/")!)
        XCTAssertEqual(file?["name"] as? String, "clipboard.jpg")
        XCTAssertEqual(file?["type"] as? String, "image/jpeg")
    }

    /// A HEIC goes as a JPEG: apps on Linux paste no HEIC from the clipboard
    func testSendClipboardHEICAsAJPEG() {
        launch(["-seedClipboardPhoto", "heic"])
        app.buttons["sendClipboard"].tap()
        XCTAssertTrue(app.staticTexts["Sent to MacBook"].waitForExistence(timeout: 8))
        let file = lastFile(on: URL(string: "http://127.0.0.1:47271/ferry/")!)
        XCTAssertEqual(file?["name"] as? String, "clipboard.jpg")
        XCTAssertEqual(file?["type"] as? String, "image/jpeg")
    }

    func testAHandPickLastsOneSend() {
        launch(["-seedClipboard", "to nightdrive"])
        app.buttons["Send to MacBook, change computer"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Nightdrive'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Send to Nightdrive, change computer"].waitForExistence(timeout: 3))
        app.buttons["sendClipboard"].tap()
        XCTAssertTrue(app.staticTexts["Sent to Nightdrive"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Send to MacBook, change computer"].waitForExistence(timeout: 3))
    }

    /// The whole circle takes the tap, not only the glyph: a tap beside "Aa" fell through to the list row under
    /// the bar (Jari: a long press there opened a row's Copy/Share/Remove menu).
    func testTheRoundButtonsTakeATapAnywhereInTheirCircle() {
        launch()
        app.buttons["Type a text"].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        let field = app.textFields["Text or link"].exists ? app.textFields["Text or link"] : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        app.settingsButton.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
    }

    func testTypedTextWaitsForCopy() {
        launch()
        app.buttons["Type a text"].tap()
        let field = app.textFields["Text or link"].exists ? app.textFields["Text or link"] : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("typed on the phone")
        app.buttons["Send"].tap()
        // "Sent to …" may come and go while the sheet closes; that it arrived is in the mock's log (uitest.sh)
        XCTAssertTrue(app.staticTexts["Send Clipboard"].waitForExistence(timeout: 8))
        XCTAssertFalse(field.exists)
    }
}

/// With the mock started as `ios/uitest.sh --down Nightdrive` (it sets FERRY_DOWN for the runner).
@MainActor
final class DownTests: XCTestCase {
    func testASleepingComputerCantBePicked() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FERRY_DOWN"] == "Nightdrive", "needs uitest.sh --down Nightdrive")
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-mock", "-notificationsAsked", "YES"]
        app.launch()
        XCTAssertTrue(app.online("1/2 online").waitForExistence(timeout: 15))
        app.buttons["Send to MacBook, change computer"].tap()
        let nightdrive = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Nightdrive'")).firstMatch
        XCTAssertTrue(nightdrive.waitForExistence(timeout: 3))
        XCTAssertFalse(nightdrive.isEnabled)
        // Its "can't reach" subtitle shows in the menu but isn't exposed to accessibility queries
    }
}

/// With nothing answering: `ios/uitest.sh --down MacBook,Nightdrive` (FERRY_DOWN set for the runner).
@MainActor
final class OfflineTests: XCTestCase {
    func testSendClipboardRespondsAtOnceAndSaysWhy() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FERRY_DOWN"]?.contains("MacBook") == true,
                          "needs uitest.sh --down MacBook,Nightdrive")
        let app = XCUIApplication()
        app.launchArguments = ["-reset", "-seedMachines", "-pasteHelpSeen", "YES", "-notificationsAsked", "YES", "-seedClipboard", "801566"]
        app.launch()
        let send = app.buttons["sendClipboard"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)                          // no waiting for a first poll
        send.tap()
        XCTAssertTrue(app.staticTexts["Can't reach MacBook"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Try again"].exists)
        XCTAssertTrue(app.online("0/2 online").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Can't reach your computers. Is Tailscale on?"].waitForExistence(timeout: 10))
    }
}
