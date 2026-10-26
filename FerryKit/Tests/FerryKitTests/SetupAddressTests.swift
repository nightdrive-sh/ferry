import Foundation
import Testing
@testable import FerryKit

@Suite struct SetupAddressTests {
    let full = URL(string: "https://nightdrive.tail1.ts.net/ferry/")!

    @Test func qrCodeURL() {
        #expect(SetupAddress.parse("https://nightdrive.tail1.ts.net/ferry/") == .url(full))
    }

    @Test func missingSlash() {
        #expect(SetupAddress.parse("https://nightdrive.tail1.ts.net/ferry") == .url(full))
    }

    @Test func hostOnly() {
        #expect(SetupAddress.parse("nightdrive.tail1.ts.net") == .url(full))
        #expect(SetupAddress.parse("  NightDrive.tail1.ts.net/ ") == .url(full))
    }

    @Test func httpBecomesHttps() {
        #expect(SetupAddress.parse("http://nightdrive.tail1.ts.net/ferry/") == .url(full))
    }

    @Test func bareName() {
        #expect(SetupAddress.parse(" nightdrive ") == .bareName("nightdrive"))
        #expect(SetupAddress.parse("office-pc") == .bareName("office-pc"))
    }

    @Test func mockKeepsItsSchemeAndPort() {   // the simulator's mock answers plain HTTP on localhost
        #expect(SetupAddress.parse("http://127.0.0.1:47271/ferry/") == .url(URL(string: "http://127.0.0.1:47271/ferry/")!))
    }

    @Test func addLink() {   // what Add Device's QR code holds since the nightdrive.sh page
        #expect(SetupAddress.parse("https://nightdrive.sh/ferry/add#https://nightdrive.tail1.ts.net/ferry/") == .url(full))
        #expect(SetupAddress.parse("https://nightdrive.sh/ferry/add/#https://nightdrive.tail1.ts.net/ferry/") == .url(full))
        #expect(SetupAddress.parse("https://NightDrive.sh/ferry/add#nightdrive.tail1.ts.net") == .url(full))
        #expect(SetupAddress.parse("https://nightdrive.sh/ferry/add#https%3A%2F%2Fnightdrive.tail1.ts.net%2Fferry%2F") == .url(full))
        #expect(SetupAddress.parse("https://nightdrive.sh/ferry/add#http://127.0.0.1:47271/ferry/")
            == .url(URL(string: "http://127.0.0.1:47271/ferry/")!))
    }

    @Test func addLinkWithoutAComputer() {
        #expect(SetupAddress.parse("https://nightdrive.sh/ferry/add") == .invalid)
        #expect(SetupAddress.parse("https://nightdrive.sh/ferry/add#") == .invalid)
        #expect(SetupAddress.parse("https://nightdrive.sh/ferry/add#https://nightdrive.sh/ferry/add") == .invalid)
        #expect(SetupAddress.parse("https://nightdrive.sh/ferry/add#not a host!") == .invalid)
    }

    @Test func linkForAComputer() {
        let link = SetupAddress.link(for: full)
        #expect(link.absoluteString == "https://nightdrive.sh/ferry/add#https://nightdrive.tail1.ts.net/ferry/")
        #expect(SetupAddress.parse(link.absoluteString) == .url(full))
        #expect(SetupAddress.isLink(link))
        #expect(!SetupAddress.isLink(full))
    }

    @Test func shortName() {   // "Waiting for nightdrive…" before the computer has said its own name
        #expect(SetupAddress.shortName(full) == "nightdrive")
        #expect(SetupAddress.shortName(URL(string: "http://127.0.0.1:47273/ferry/")!) == "127.0.0.1")
    }

    @Test func invalid() {
        #expect(SetupAddress.parse("not a host!") == .invalid)
        #expect(SetupAddress.parse("") == .invalid)
        #expect(SetupAddress.parse("   ") == .invalid)
        #expect(SetupAddress.parse("https://") == .invalid)
    }
}
