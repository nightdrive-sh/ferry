import CryptoKit
import Foundation
import Security
import Testing
@testable import FerryKit

/// RFC 8291 encryption in the test target only, for payloads the bin/ferry vector doesn't cover. The vector itself
/// (PushCryptoTests) is what proves the app reads a real computer's messages.
func encryptForTest(_ plaintext: Data, to keys: PushKeys) throws -> Data {
    let receiver = try P256.KeyAgreement.PrivateKey(rawRepresentation: keys.privateKey).publicKey.x963Representation
    let sender = P256.KeyAgreement.PrivateKey()
    let shared = try sender.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: receiver))
    let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared.withUnsafeBytes { Data($0) }), salt: keys.auth,
                                     info: Data("WebPush: info\0".utf8) + receiver + sender.publicKey.x963Representation,
                                     outputByteCount: 32)
    let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8),
                                     outputByteCount: 16)
    let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8),
                                       outputByteCount: 12)
    let box = try AES.GCM.seal(plaintext + [2], using: cek, nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))
    return salt + Data([0, 0, 0x10, 0, 65]) + sender.publicKey.x963Representation + box.ciphertext + box.tag
}

@Suite struct PushTests {
    @Test func opensANotice() throws {
        let v = try PushVector.load()
        let notice = try #require(PushNotice.open(["a": "abc", "m": v.bodyData.base64EncodedString()], keys: v.keys))
        #expect(notice.address == "abc")
        #expect(notice.message.title == "Nightdrive")
        #expect(notice.message.text == "801566 ä")
        #expect(notice.message.kind == .text)
        #expect(notice.message.id == "a1b2c3d4e5f6")
    }

    @Test func noticeWithoutIdStillOpens() throws {   // api/test-push sends no item
        let keys = PushKeys.generate()
        let body = try encryptForTest(Data(#"{"title":"Nightdrive","body":"Notifications work","machine":""}"#.utf8), to: keys)
        let notice = try #require(PushNotice.open(["a": "x", "m": body.base64EncodedString()], keys: keys))
        #expect(notice.message.id == nil)
        #expect(notice.message.kind == nil)
        #expect(notice.message.body == "Notifications work")
    }

    @Test func garbageIsNil() throws {
        let v = try PushVector.load()
        let m = v.bodyData.base64EncodedString()
        #expect(PushNotice.open(["m": m], keys: v.keys) == nil)
        #expect(PushNotice.open(["a": "abc"], keys: v.keys) == nil)
        #expect(PushNotice.open(["a": "abc", "m": "not base64!"], keys: v.keys) == nil)
        #expect(PushNotice.open(["a": "abc", "m": m], keys: PushKeys.generate()) == nil)
    }

    @Test func keychainReadableWhileLockedAndShared() {   // Review Focus 1
        let a = PushKeychain.attributes(group: "G.fi.feature.ferry.shared")
        #expect(a[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(a[kSecAttrAccessGroup as String] as? String == "G.fi.feature.ferry.shared")
        #expect(a[kSecAttrService as String] as? String == "fi.feature.ferry.push")
        #expect(a[kSecAttrSynchronizable as String] as? Bool == false)
    }
}

let relay = URL(string: "https://push.nightdrive.sh/")!

func stubRelay() -> HTTPRelay {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubProtocol.self]
    return HTTPRelay(base: relay, session: URLSession(configuration: c))
}

let relayAddress = RelayAddress(endpoint: URL(string: "https://push.nightdrive.sh/push/abc")!, secret: "s3cret")

/// In HTTPBackendTests' serialized suite: StubProtocol's state is global, and two serialized suites still run side by side.
extension HTTPBackendTests {
    var address: RelayAddress { relayAddress }

    @Test func registerPostsAndDecodes() async throws {
        StubProtocol.reply(.http(201, json(#"{"endpoint":"https://push.nightdrive.sh/push/abc","secret":"s3cret"}"#)))
        let a = try await stubRelay().register(token: "00ff", env: .sandbox, vapid: "BKEY")
        #expect(a == address)
        #expect(a.id == "abc")
        let s = try #require(StubProtocol.seen.first)
        #expect(s.request.httpMethod == "POST")
        #expect(s.request.url?.absoluteString == "https://push.nightdrive.sh/v1/register")
        let body = try #require(try JSONSerialization.jsonObject(with: s.body) as? [String: String])
        #expect(body == ["token": "00ff", "env": "sandbox", "vapid": "BKEY"])
    }

    @Test func existsReadsTheStatus() async throws {
        StubProtocol.reply(.http(204, Data()))
        #expect(try await stubRelay().exists(address))
        let s = try #require(StubProtocol.seen.first)
        #expect(s.request.httpMethod == "GET")
        #expect(s.request.url == address.endpoint)
        #expect(s.request.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
        StubProtocol.reply(.http(404, Data()))
        #expect(try await !stubRelay().exists(address))
        StubProtocol.reply(.http(500, json("down")))
        await #expect(throws: FerryError.refused(status: 500, message: "down")) { _ = try await stubRelay().exists(address) }
    }

    @Test func deleteSendsTheSecret() async throws {
        StubProtocol.reply(.http(204, Data()))
        try await stubRelay().delete(address)
        let s = try #require(StubProtocol.seen.first)
        #expect(s.request.httpMethod == "DELETE")
        #expect(s.request.url == address.endpoint)
        #expect(s.request.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
    }

    @Test func subscribeSendsADirectSubscription() async throws {
        let keys = PushKeys.generate()
        StubProtocol.reply(.http(200, json(#"{"ok":true}"#)))
        try await backend().subscribe(address.endpoint, keys: keys, on: machine)
        let s = try #require(StubProtocol.seen.first)
        #expect(s.request.httpMethod == "POST")
        #expect(s.request.url?.absoluteString == "https://nightdrive.tail1.ts.net/ferry/api/subscribe")
        #expect(s.request.value(forHTTPHeaderField: "X-Ferry") == "1")
        let body = try #require(try JSONSerialization.jsonObject(with: s.body) as? [String: Any])
        #expect(body["endpoint"] as? String == "https://push.nightdrive.sh/push/abc")
        #expect(body["direct"] as? Bool == true)
        let k = try #require(body["keys"] as? [String: String])
        #expect(k == ["p256dh": keys.p256dh, "auth": keys.authString])
    }

    @Test func unsubscribe() async throws {
        StubProtocol.reply(.http(200, json(#"{"ok":true}"#)))
        try await backend().unsubscribe(address.endpoint, on: machine)
        let s = try #require(StubProtocol.seen.first)
        #expect(s.request.url?.absoluteString == "https://nightdrive.tail1.ts.net/ferry/api/unsubscribe")
        let body = try #require(try JSONSerialization.jsonObject(with: s.body) as? [String: String])
        #expect(body == ["endpoint": "https://push.nightdrive.sh/push/abc"])
    }

    @Test func itemsCarryThePushKey() throws {
        let r = try JSONDecoder().decode(ItemsResponse.self, from: json(#"{"computer":"N","items":[],"keep":7,"idle":0,"push":"BKEY"}"#))
        #expect(r.push == "BKEY")
        let none = try JSONDecoder().decode(ItemsResponse.self, from: json(#"{"computer":"N","items":[],"keep":7,"idle":0}"#))
        #expect(none.push == nil)
    }
}
