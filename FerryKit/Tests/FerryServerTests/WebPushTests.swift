import CryptoKit
import FerryKit
import Foundation
import Testing
@testable import FerryServer

@Suite struct WebPushTests {
    @Test func encryptsSoThePhoneCanRead() throws {
        let keys = PushKeys.generate()
        let message = Data("801566 ä".utf8)
        let body = try WebPush.encrypt(message, p256dh: keys.p256dh, auth: keys.authString)
        #expect(try PushCrypto.decrypt(body, with: keys) == message)
        #expect(Array(body[16..<20]) == [0, 0, 0x10, 0])   // record size 4096
        #expect(body[20] == 65)
        #expect(try WebPush.encrypt(message, p256dh: keys.p256dh, auth: keys.authString) != body)   // a fresh salt and key each time
    }

    @Test func badSubscriptionKeysThrow() {
        #expect(throws: (any Error).self) { try WebPush.encrypt(Data("x".utf8), p256dh: "nope", auth: "AAAA") }
    }

    @Test func keyIsKept() throws {
        let state = tempFolder()
        let a = try VAPIDKey.load(orCreateIn: state)
        let b = try VAPIDKey.load(orCreateIn: state)
        #expect(a.publicKey == b.publicKey)
        #expect(a.publicKey.count == 87)
        let attrs = try FileManager.default.attributesOfItem(atPath: state.appending(path: "vapid.pem").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let pem = try String(contentsOf: state.appending(path: "vapid.pem"), encoding: .utf8)
        #expect(pem.hasPrefix("-----BEGIN PRIVATE KEY-----"))   // PKCS#8, as bin/ferry writes it
    }

    @Test func jwtVerifies() throws {
        let key = try VAPIDKey.load(orCreateIn: tempFolder())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let header = try key.authorization(for: URL(string: "https://push.nightdrive.sh/push/abc")!, now: now,
                                           contact: "https://github.com/nightdrive-sh/ferry")
        #expect(header.hasPrefix("vapid t="))
        let parts = header.dropFirst("vapid t=".count).components(separatedBy: ", k=")
        #expect(parts.count == 2)
        #expect(parts[1] == key.publicKey)
        let jwt = parts[0].components(separatedBy: ".")
        #expect(jwt.count == 3)
        let head = try JSONSerialization.jsonObject(with: Data(base64URL: jwt[0])!) as? [String: String]
        #expect(head == ["typ": "JWT", "alg": "ES256"])
        let claims = try JSONSerialization.jsonObject(with: Data(base64URL: jwt[1])!) as? [String: Any]
        #expect(claims?["aud"] as? String == "https://push.nightdrive.sh")
        #expect((claims?["exp"] as? NSNumber)?.intValue == 1_800_003_600)
        #expect(claims?["sub"] as? String == "https://github.com/nightdrive-sh/ferry")
        let pub = try P256.Signing.PublicKey(x963Representation: Data(base64URL: parts[1])!)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: Data(base64URL: jwt[2])!)
        #expect(pub.isValidSignature(sig, for: Data("\(jwt[0]).\(jwt[1])".utf8)))
    }

    @Test func audienceKeepsAPort() throws {
        let key = try VAPIDKey.load(orCreateIn: tempFolder())
        let header = try key.authorization(for: URL(string: "https://push.example.com:8443/x")!, now: Date(), contact: "c")
        let jwt = header.dropFirst("vapid t=".count).components(separatedBy: ", k=")[0].components(separatedBy: ".")
        let claims = try JSONSerialization.jsonObject(with: Data(base64URL: jwt[1])!) as? [String: Any]
        #expect(claims?["aud"] as? String == "https://push.example.com:8443")
    }

    func decode(_ d: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    /// docs/protocol.md › Codes and passwords: the lock screen shows the body, so a code isn't in it
    @Test func aCodeIsntInTheBody() throws {
        let code = BoxItem(id: "a", to: "phone", kind: "text", time: 0, text: "801566")
        let p = try decode(WebPush.payload(title: "MacBook", body: "801566", machine: "", item: code, limit: 2600))
        #expect(p["body"] as? String == "Code or password · open to see")
        #expect(p["secret"] as? Bool == true)
        #expect(p["text"] as? String == "801566")   // a tap on it still copies it
        let other = BoxItem(id: "b", to: "phone", kind: "text", time: 0, text: "See you at eight")
        let q = try decode(WebPush.payload(title: "MacBook", body: "See you at eight", machine: "", item: other, limit: 2600))
        #expect(q["body"] as? String == "See you at eight")
        #expect(q["secret"] == nil)
        let file = BoxItem(id: "c", to: "phone", kind: "file", time: 0, name: "IMG_1234.jpg")
        let f = try decode(WebPush.payload(title: "MacBook", body: "IMG_1234.jpg", machine: "", item: file, limit: 2600))
        #expect(f["body"] as? String == "IMG_1234.jpg")
    }

    @Test func payloadRules() throws {
        let short = BoxItem(id: "a1b2c3d4e5f6", to: "phone", kind: "text", time: 0, text: String(repeating: "x", count: 100))
        let p = try decode(WebPush.payload(title: "MacBook", body: "801566", machine: "", item: short, limit: 2600))
        #expect(p["text"] as? String == short.text)
        #expect(p["id"] as? String == "a1b2c3d4e5f6")
        #expect(p["kind"] as? String == "text")
        #expect(p["title"] as? String == "MacBook")
        #expect(p["machine"] as? String == "")

        let longText = String(repeating: "y", count: 3000)
        let long = BoxItem(id: "b", to: "phone", kind: "text", time: 0, text: longText)
        let q = try decode(WebPush.payload(title: "MacBook", body: longText, machine: "", item: long, limit: 2600))
        #expect(q["text"] == nil)
        #expect((q["body"] as? String)?.count == 300)

        let file = BoxItem(id: "c", to: "phone", kind: "file", time: 0, name: "a.pdf")
        let f = try decode(WebPush.payload(title: "MacBook", body: "a.pdf", machine: "", item: file, limit: 2600))
        #expect(f["kind"] as? String == "file")
        #expect(f["text"] == nil)

        let m = WebPush.payload(title: "MacBook", body: "hi", machine: String(repeating: "m", count: 5000), item: nil, limit: 2600)
        #expect(try decode(m)["machine"] as? String == "")
        #expect(try decode(m)["id"] == nil)   // a test notification carries no item

        for d in [WebPush.payload(title: String(repeating: "ä", count: 5000), body: String(repeating: "ö", count: 5000),
                                  machine: "", item: nil, limit: 2600), m] {
            #expect(d.count <= 2600)
        }
    }
}
