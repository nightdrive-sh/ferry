import XCTest

/// Setup from a fresh install, by a typed address (the camera can't be tested in the simulator), settings, and the
/// paste permission help after the first Send Clipboard.
@MainActor
final class SetupTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args + ["-notificationsAsked", "YES"]   // NotificationTests covers the prompt
        app.launch()
        return app
    }

    func type(_ app: XCUIApplication, _ address: String) {
        app.buttons["Type a Computer's Name"].tap()
        let field = app.textFields["Computer name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText(address)
        app.buttons["Connect"].tap()
    }

    func testSetupByAddressFindsTheOthers() {
        let app = launch(["-reset"])
        type(app, "http://127.0.0.1:47271/ferry/")
        XCTAssertTrue(app.staticTexts["RECEIVED"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.settingsButton.waitForExistence(timeout: 5))
        app.settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'MacBook'")).firstMatch.exists
                      || app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'MacBook'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nightdrive'")).firstMatch.exists
                      || app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Nightdrive'")).firstMatch.exists)
    }

    func testABareNameThatDoesntResolveAsksForTheFullOne() {
        let app = launch(["-reset"])
        type(app, "nosuchhost")
        XCTAssertTrue(app.staticTexts["Type the full name, like computer.tailXXXX.ts.net"].waitForExistence(timeout: 10))
    }

    func testAnAddressThatDoesntAnswer() {
        let app = launch(["-reset"])
        type(app, "http://127.0.0.1:47279/ferry/")
        XCTAssertTrue(app.staticTexts["Can't reach that computer. Is Tailscale on, the computer awake, and Ferry running on it?"]
            .waitForExistence(timeout: 12))
    }

    /// Add Device's QR code in the Camera: nightdrive.sh's add page, a universal link with the address in its fragment.
    func link(_ address: String) -> URL { URL(string: "https://nightdrive.sh/ferry/add#" + address)! }

    func testTheAddPageSetsUpAFreshInstall() {
        let app = launch(["-reset"])
        XCTAssertTrue(app.buttons["Scan QR Code"].waitForExistence(timeout: 5))
        app.open(link("http://127.0.0.1:47271/ferry/"))
        XCTAssertTrue(app.staticTexts["RECEIVED"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.online("2/2 online").waitForExistence(timeout: 10))
    }

    func testTheAddPageAddsAComputerOnceSetUp() {
        let app = launch(["-reset", "-mock", "-pasteHelpSeen", "YES"])
        XCTAssertTrue(app.online("2/2 online").waitForExistence(timeout: 10))
        app.open(link("http://127.0.0.1:47279/ferry/"))   // nothing answers there
        XCTAssertTrue(app.staticTexts["Add a Computer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Can't reach that computer. Is Tailscale on, the computer awake, and Ferry running on it?"]
            .waitForExistence(timeout: 12))
        app.open(link("http://127.0.0.1:47272/ferry/"))   // Nightdrive answers: added (it was known), and the sheet goes
        XCTAssertTrue(app.staticTexts["Add a Computer"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.online("2/2 online").exists)
    }

    /// Studio, the mock's computer just set up: it answers 40 s after its first request, as a new computer does once
    /// tailscaled has its HTTPS certificate. Its link is scanned before that, and setup waits for it, saying why.
    func studioLink() -> URL {
        XCTAssertEqual(mock("DELETE", "/mock/cert", port: 47273)?["ok"] as? Bool, true)   // no certificate yet
        return link("http://127.0.0.1:47273/ferry/")
    }

    func testTheAddPageWaitsForAComputerGettingItsCertificate() {
        let app = launch(["-reset", "-pasteHelpSeen", "YES"])
        XCTAssertTrue(app.buttons["Scan QR Code"].waitForExistence(timeout: 5))
        app.open(studioLink())
        XCTAssertTrue(app.staticTexts["Waiting for 127.0.0.1…"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'A computer just set up'")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "waiting"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(app.staticTexts["RECEIVED"].waitForExistence(timeout: 50))
        XCTAssertTrue(app.online("Studio").waitForExistence(timeout: 10))   // one computer: its name
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH \"Can't reach\"")).firstMatch.exists)
    }

    func testCancellingTheWaitForAComputer() {
        let app = launch(["-reset", "-pasteHelpSeen", "YES"])
        XCTAssertTrue(app.buttons["Scan QR Code"].waitForExistence(timeout: 5))
        app.open(studioLink())
        XCTAssertTrue(app.staticTexts["Waiting for 127.0.0.1…"].waitForExistence(timeout: 15))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Scan QR Code"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Waiting for 127.0.0.1…"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH \"Can't reach\"")).firstMatch.exists)
    }

    func testAWrongAddressIsSaidAtOnce() {   // nothing listens there: no waiting a minute for it
        let app = launch(["-reset"])
        XCTAssertTrue(app.buttons["Scan QR Code"].waitForExistence(timeout: 5))
        app.open(link("http://127.0.0.1:47279/ferry/"))
        XCTAssertTrue(app.staticTexts["Can't reach that computer. Is Tailscale on, the computer awake, and Ferry running on it?"]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Waiting for 127.0.0.1…"].exists)
    }

    func testTheAddPageLeavesTheDemo() {
        let app = launch(["-reset", "-pasteHelpSeen", "YES"])
        let tryIt = app.buttons["Try without a computer"]
        XCTAssertTrue(tryIt.waitForExistence(timeout: 5))
        tryIt.tap()
        XCTAssertTrue(app.buttons["Leave Demo"].waitForExistence(timeout: 5))
        app.open(link("http://127.0.0.1:47271/ferry/"))
        XCTAssertTrue(app.buttons["Leave Demo"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["RECEIVED"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.online("2/2 online").waitForExistence(timeout: 10))
    }

    func testPasteHelpAfterTheFirstSendClipboard() {
        let app = launch(["-reset", "-mock", "-pasteHelpSeen", "NO", "-seedClipboard", "801566"])
        XCTAssertTrue(app.buttons["sendClipboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.online("2/2 online").waitForExistence(timeout: 10))
        app.buttons["sendClipboard"].tap()
        XCTAssertTrue(app.staticTexts["Send without the Paste prompt"].waitForExistence(timeout: 8))
        app.buttons["Not Now"].tap()
    }

    func testNoPasteHelpAfterAnEmptyClipboard() {   // iOS asked nothing, and the setting doesn't exist yet
        let app = launch(["-reset", "-mock", "-pasteHelpSeen", "NO", "-emptyClipboard"])
        XCTAssertTrue(app.buttons["sendClipboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.online("2/2 online").waitForExistence(timeout: 10))
        app.buttons["sendClipboard"].tap()
        XCTAssertTrue(app.staticTexts["Clipboard is empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Send without the Paste prompt"].waitForExistence(timeout: 2))
    }
}
