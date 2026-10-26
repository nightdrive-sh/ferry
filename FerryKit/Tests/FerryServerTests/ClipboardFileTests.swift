import Foundation
import Testing
@testable import FerryServer

@Suite struct ClipboardFileTests {
    @Test func eachSendHasItsOwnFile() async throws {   // Final review: a second screenshot replaced the first
        let box = Box(state: tempFolder(), keepDays: 7, clock: TestClock().function)
        let a = try ClipboardFile.write(Data("AA".utf8))
        let left = try await box.leaveFile(a, for: "iphone")
        let b = try ClipboardFile.write(Data("BB".utf8))
        #expect(a != b)
        #expect(a.lastPathComponent == "Clipboard.png" && b.lastPathComponent == "Clipboard.png")
        #expect(try Data(contentsOf: URL(filePath: left.path!)) == Data("AA".utf8))   // what waits for the phone is still A
        #expect(try Data(contentsOf: b) == Data("BB".utf8))
    }
}
