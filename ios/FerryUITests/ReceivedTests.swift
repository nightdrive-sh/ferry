import XCTest

/// Runs against tools/mock-ferry.py (ios/uitest.sh starts it), as a fresh install set up with -mock. What reaches the
/// computers, and the simulator's clipboard, are checked by uitest.sh from the mock's log and `simctl pbpaste`.
@MainActor
final class ReceivedTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-reset", "-mock", "-notificationsAsked", "YES"]
        app.launch()
    }

    func row(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    func testListShowsWhatTheComputersSent() {
        XCTAssertTrue(app.staticTexts["RECEIVED"].waitForExistence(timeout: 10))
        XCTAssertTrue(row("801566").waitForExistence(timeout: 10))
        XCTAssertTrue(row("night-waves.png").exists)
        XCTAssertTrue(app.online("2/2 online").exists)
    }

    /// A code leaves the computer's box once copied (docs/protocol.md › Codes and passwords). Last in the class (the
    /// tests run in name order): the mock doesn't have it any more afterwards.
    func testTapCopiesACodeAndItLeaves() {
        let code = row("801566")
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        let codes = { self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "801566")).count }
        let before = codes()   // one from each pretend computer
        code.tap()
        XCTAssertTrue(app.staticTexts["Copied"].waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntil { codes() == before - 1 })
    }

    func testSwipeRemoves() {
        let link = row("https://nightdrive.sh/docs")
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        let before = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "https://nightdrive.sh/docs")).count
        link.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(waitUntil { self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "https://nightdrive.sh/docs")).count == before - 1 })
    }

    /// Polls a condition the UI reaches by itself (the list after the next poll).
    func waitUntil(_ seconds: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return true
    }
}
