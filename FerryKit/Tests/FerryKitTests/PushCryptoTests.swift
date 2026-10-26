import Foundation
import Testing
@testable import FerryKit

/// tools/push-vector.py: a message encrypted by bin/ferry's own encrypt().
struct PushVector: Decodable {
    let privateKey: String, auth: String, p256dh: String, plaintext: String, body: String

    static func load() throws -> PushVector { try JSONDecoder().decode(PushVector.self, from: fixture("push-vector")) }

    var keys: PushKeys { PushKeys(privateKey: Data(base64URL: privateKey)!, auth: Data(base64URL: auth)!) }
    var bodyData: Data { Data(base64URL: body)! }
}

@Suite struct PushCryptoTests {
    @Test func decryptsWhatBinFerryEncrypted() throws {
        let v = try PushVector.load()
        #expect(v.keys.p256dh == v.p256dh)
        let plain = try PushCrypto.decrypt(v.bodyData, with: v.keys)
        #expect(String(decoding: plain, as: UTF8.self) == v.plaintext)
    }

    @Test func wrongKeyCannotDecrypt() throws {
        let v = try PushVector.load()
        #expect(throws: PushCryptoError.cannotDecrypt) { try PushCrypto.decrypt(v.bodyData, with: PushKeys.generate()) }
    }

    @Test func truncatedBodyIsMalformed() throws {
        let v = try PushVector.load()
        #expect(throws: PushCryptoError.malformed) { try PushCrypto.decrypt(v.bodyData.prefix(50), with: v.keys) }
    }

    @Test func generatedKeysHaveTheWebPushShape() throws {
        let k = PushKeys.generate()
        let point = try #require(Data(base64URL: k.p256dh))
        #expect(point.count == 65)
        #expect(point.first == 0x04)
        #expect(Data(base64URL: k.authString)?.count == 16)
        #expect(k.auth.count == 16)
    }

    @Test func base64URLRoundTrips() {
        let d = Data([0xfb, 0xff, 0x00, 0x3e])
        #expect(d.base64URL == "-_8APg")
        #expect(Data(base64URL: "-_8APg") == d)
        #expect(Data(base64URL: "not base64!") == nil)
    }
}
