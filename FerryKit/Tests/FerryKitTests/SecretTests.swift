import Foundation
import Testing
@testable import FerryKit

/// The same vectors as linux/tests/test_secret.py: one rule on every platform (docs/protocol.md › Codes and passwords).
@Suite struct SecretTests {
    struct Vectors: Decodable {
        let secret: [String]
        let not: [String]
    }

    @Test func theSharedVectors() throws {
        let v = try JSONDecoder().decode(Vectors.self, from: fixture("secrets"))
        for text in v.secret { #expect(Secret.looksLike(text), "\(text.debugDescription) is a code or a password") }
        for text in v.not { #expect(!Secret.looksLike(text), "\(text.debugDescription) isn't") }
    }

    @Test func aDecodedNoticeHidesACode() throws {
        // A computer from before the rule sends the code itself as the body
        let old = try JSONDecoder().decode(PushMessage.self, from: Data(
            #"{"title":"MacBook","body":"801566","machine":"","id":"abc","kind":"text","text":"801566"}"#.utf8))
        #expect(old.shownBody == Secret.hidden)
        // A computer that follows it has hidden it already, and says so
        let new = try JSONDecoder().decode(PushMessage.self, from: Data(
            #"{"title":"MacBook","body":"Code or password · open to see","machine":"","id":"abc","kind":"text","text":"801566","secret":true}"#.utf8))
        #expect(new.shownBody == Secret.hidden)
        #expect(new.text == "801566")   // a tap still copies it
    }

    @Test func otherNoticesShowTheirBody() throws {
        let text = try JSONDecoder().decode(PushMessage.self, from: Data(
            #"{"title":"MacBook","body":"See you at eight","machine":"","id":"abc","kind":"text","text":"See you at eight"}"#.utf8))
        #expect(text.shownBody == "See you at eight")
        // A file's name may look like one (IMG_1234.jpg), and is still shown
        let file = try JSONDecoder().decode(PushMessage.self, from: Data(
            #"{"title":"MacBook","body":"IMG_1234.jpg","machine":"","id":"abc","kind":"file"}"#.utf8))
        #expect(file.shownBody == "IMG_1234.jpg")
        let test = try JSONDecoder().decode(PushMessage.self, from: Data(#"{"title":"MacBook","body":"Test1234","machine":""}"#.utf8))
        #expect(test.shownBody == "Test1234")
    }
}
