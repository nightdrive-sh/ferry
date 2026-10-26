import Foundation
import Testing
@testable import FerryKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct ModelsTests {
    @Test func decodesItems() throws {
        let r = try JSONDecoder().decode(ItemsResponse.self, from: fixture("items"))
        #expect(r.computer == "Nightdrive")
        #expect(r.items.count == 3)
        #expect(r.keep == 7)
        #expect(r.idle == 0)
        #expect(r.items[0].time == Date(timeIntervalSince1970: 1792398788.298958))
        #expect(r.items[0].to == .phone)
        #expect(r.items[0].kind == .text)
        #expect(r.items[0].text == "801566")
        #expect(r.items[1].name == "night-waves.png")
        #expect(r.items[1].size == 5696605)
        #expect(r.items[1].type == "image/png")
        #expect(r.items[2].from == "iphone")
        #expect(r.items[2].seen == true)
    }

    @Test func decodesMissingIdleAsNil() throws {
        let json = #"{"computer":"x","items":[],"keep":7,"idle":null}"#
        let r = try JSONDecoder().decode(ItemsResponse.self, from: Data(json.utf8))
        #expect(r.idle == nil)
        // An older Ferry doesn't send the key at all
        let older = try JSONDecoder().decode(ItemsResponse.self, from: Data(#"{"computer":"x","items":[],"keep":7}"#.utf8))
        #expect(older.idle == nil)
    }

    @Test func decodesMachinesWithSelf() throws {
        let r = try JSONDecoder().decode(MachinesResponse.self, from: fixture("machines"))
        #expect(r.machines.count == 2)
        #expect(r.machines[0].isSelf == true)
        #expect(r.machines[0].url == URL(string: "https://nightdrive.tail1.ts.net/ferry/"))
        #expect(r.machines[1].isSelf == false)
        #expect(r.machines[1].name == "MacBook")
    }

    @Test func linkDetection() throws {
        func item(_ text: String) throws -> Item {
            let json = #"{"id":"a","to":"phone","kind":"text","time":1,"text":"\#(text)"}"#
            return try JSONDecoder().decode(Item.self, from: Data(json.utf8))
        }
        #expect(try item("https://nightdrive.sh/docs").isLink)
        #expect(try item(" http://example.com/a?b=1 ").isLink)
        #expect(try !item("see https://x.y").isLink)
        #expect(try !item("801566").isLink)
        #expect(try !item("ftp://example.com").isLink)
    }

    @Test func webLink() {
        #expect(WebLink.url(in: " https://example.com/a ") == URL(string: "https://example.com/a"))
        #expect(WebLink.url(in: "see https://example.com") == nil)
        #expect(WebLink.url(in: "ftp://x.y") == nil)
        #expect(WebLink.url(in: "https://") == nil)
    }

    @Test func machinesResponseForgotten() throws {
        let r = try JSONDecoder().decode(MachinesResponse.self, from: Data(#"""
            {"machines": [{"url": "https://nightdrive.tail1.ts.net/ferry/", "name": "Nightdrive", "self": true}],
             "forgotten": [{"device": "studio", "time": 1, "forgotten": true}, {"device": "mini", "time": 2, "forgotten": false},
                           "x", {"device": 5, "time": 1, "forgotten": true}, {"device": "ipad", "forgotten": true}]}
            """#.utf8))
        #expect(r.machines.count == 1)
        #expect(r.forgotten == ["studio", "ipad"])
        let old = try JSONDecoder().decode(MachinesResponse.self, from: Data(#"{"machines": []}"#.utf8))   // an older Ferry
        #expect(old.forgotten.isEmpty)
    }
}
