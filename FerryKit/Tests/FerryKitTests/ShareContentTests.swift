import Foundation
import Testing
@testable import FerryKit

/// What a share becomes (the phase 3 design's table): every file under its own name, a link without the page title.
struct ShareContentTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "share-\(UUID().uuidString)")

    func file(_ name: String, _ bytes: String = "x") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @Test func linkAndTitleSendTheLinkOnly() throws {
        let p = ShareContent.payloads([.link(URL(string: "https://example.com/a")!), .text("Example page")], copyingInto: folder)
        #expect(p == [.text("https://example.com/a", clip: false)])
    }

    @Test func textAlone() throws {
        #expect(ShareContent.payloads([.text("801566")], copyingInto: folder) == [.text("801566", clip: false)])
        let withLink = "look at https://example.com/a"
        #expect(ShareContent.payloads([.text(withLink)], copyingInto: folder) == [.text(withLink, clip: false)])
    }

    @Test func blankTextIsDropped() throws {
        #expect(ShareContent.payloads([.text("  \n")], copyingInto: folder).isEmpty)
    }

    @Test func fileIsCopiedWithItsNameAndType() throws {
        let original = try file("IMG_0001.JPG", "jpeg bytes")
        let p = ShareContent.payloads([.file(original)], copyingInto: folder)
        guard case .file(let url, let name, let type, let clip) = try #require(p.first) else { Issue.record("not a file"); return }
        #expect(p.count == 1)
        #expect(name == "IMG_0001.JPG")
        #expect(type == "image/jpeg")
        #expect(!clip)
        #expect(url.lastPathComponent == "IMG_0001.JPG")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(try Data(contentsOf: url) == Data("jpeg bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: original.path()))
    }

    @Test func aFileURLSharedAsALinkIsAFile() throws {
        let original = try file("notes.txt")
        let p = ShareContent.payloads([.link(original), .text("notes")], copyingInto: folder)
        #expect(p.count == 2)   // a file is no web link: the text stays
        #expect(p.first == .text("notes", clip: false))
        guard case .file(_, let name, _, _) = try #require(p.last) else { Issue.record("not a file"); return }
        #expect(name == "notes.txt")
    }

    @Test func sameNameTwiceBothKept() throws {
        let p = ShareContent.payloads([.file(try file("IMG_0001.JPG", "a")), .file(try file("IMG_0001.JPG", "b"))],
                                          copyingInto: folder)
        let urls = p.compactMap { if case .file(let u, _, _, _) = $0 { u } else { nil } }
        #expect(urls.count == 2)
        #expect(urls[0] != urls[1])
        #expect(try urls.map { try Data(contentsOf: $0) } == [Data("a".utf8), Data("b".utf8)])
    }

    /// Review: one file that couldn't be copied (an iCloud placeholder, a full disk) emptied the whole share.
    @Test func aFileThatCantBeCopiedIsLeftOut() throws {
        let gone = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/missing.jpg")
        let p = ShareContent.payloads([.file(try file("a.jpg")), .file(gone), .file(try file("b.jpg"))], copyingInto: folder)
        #expect(p.compactMap { if case .file(_, let name, _, _) = $0 { name } else { nil } } == ["a.jpg", "b.jpg"])
    }

    @Test func unknownExtensionIsOctetStream() throws {
        let p = ShareContent.payloads([.file(try file("x.ferryblob"))], copyingInto: folder)
        guard case .file(_, _, let type, _) = try #require(p.first) else { Issue.record("not a file"); return }
        #expect(type == "application/octet-stream")
    }

    @Test func summary() {
        func f(_ name: String, _ type: String) -> SendPayload { .file(URL(filePath: "/tmp/\(name)"), name: name, type: type, clip: false) }
        #expect(ShareContent.summary([f("report.pdf", "application/pdf")]) == "report.pdf")
        #expect(ShareContent.summary([.text("first line\nsecond", clip: false)]) == "first line")
        #expect(ShareContent.summary([.text(String(repeating: "a", count: 100), clip: false)]) == String(repeating: "a", count: 80))
        #expect(ShareContent.summary([f("a.jpg", "image/jpeg"), f("b.png", "image/png"), f("c.heic", "image/heic")]) == "3 photos")
        #expect(ShareContent.summary([f("a.mov", "video/quicktime"), f("b.mp4", "video/mp4")]) == "2 videos")
        #expect(ShareContent.summary([f("a.jpg", "image/jpeg"), f("b.pdf", "application/pdf"), .text("x", clip: false)]) == "3 items")
    }
}
