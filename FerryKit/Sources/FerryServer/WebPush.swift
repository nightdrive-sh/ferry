import CryptoKit
import FerryKit
import Foundation

/// The computer's VAPID key (RFC 8292): pushes are signed with it, and the phone's relay address only takes pushes
/// signed by the key it was made for (`push` in `api/items`).
public struct VAPIDKey: Sendable {
    let key: P256.Signing.PrivateKey

    /// vapid.pem in the state folder, made on the first run: PKCS#8 PEM like bin/ferry's, readable only by its user
    public static func load(orCreateIn state: URL) throws -> VAPIDKey {
        let fm = FileManager.default
        let path = state.appending(path: "vapid.pem")
        if let pem = try? String(contentsOf: path, encoding: .utf8) {
            return VAPIDKey(key: try P256.Signing.PrivateKey(pemRepresentation: pem))
        }
        try fm.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = P256.Signing.PrivateKey()
        guard fm.createFile(atPath: path.path, contents: Data(key.pemRepresentation.utf8),
                            attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        return VAPIDKey(key: key)
    }

    /// The public key as an uncompressed point, base64url
    public var publicKey: String { key.publicKey.x963Representation.base64URL }

    /// `Authorization` for a push to endpoint: a JWT for the push service's origin, valid an hour
    public func authorization(for endpoint: URL, now: Date, contact: String) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host() else { throw URLError(.badURL) }
        let aud = "\(scheme)://\(host)\(endpoint.port.map { ":\($0)" } ?? "")"
        struct Claims: Encodable { let aud: String; let exp: Int; let sub: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let head = Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8).base64URL
        let claims = try encoder.encode(Claims(aud: aud, exp: Int(now.timeIntervalSince1970) + 3600, sub: contact)).base64URL
        let signing = "\(head).\(claims)"
        let signature = try key.signature(for: Data(signing.utf8)).rawRepresentation.base64URL
        return "vapid t=\(signing).\(signature), k=\(publicKey)"
    }
}

/// RFC 8291 message encryption (aes128gcm, one record), written as bin/ferry's `encrypt()` writes it, so the phone's
/// `PushCrypto.decrypt` reads a Mac's notifications like a Linux computer's.
public enum WebPush {
    public static func encrypt(_ payload: Data, p256dh: String, auth: String) throws -> Data {
        guard let uaPub = Data(base64URL: p256dh), let secret = Data(base64URL: auth) else { throw PushCryptoError.malformed }
        let ua = try P256.KeyAgreement.PublicKey(x963Representation: uaPub)
        let eph = P256.KeyAgreement.PrivateKey()
        let asPub = eph.publicKey.x963Representation
        let shared = try eph.sharedSecretFromKeyAgreement(with: ua)
        let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared.withUnsafeBytes { Data($0) }),
                                         salt: secret, info: Data("WebPush: info\0".utf8) + uaPub + asPub,
                                         outputByteCount: 32)
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                         info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                           info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        // 0x02: the last (only) record's padding delimiter
        let sealed = try AES.GCM.seal(payload + [2], using: cek,
                                      nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))
        return salt + Data([0, 0, 0x10, 0, UInt8(asPub.count)]) + asPub + sealed.ciphertext + sealed.tag
    }

    /// A notification's content, bin/ferry's `payload()`: what the phone shows, and the item so a tap opens it. The
    /// whole text goes along only when it fits, never a cut one (the app fetches a long one); title and body are cut
    /// by characters, so the JSON and its UTF-8 stay whole. A code or a password isn't in the body.
    public static func payload(title: String, body: String, machine: String, item: BoxItem?, limit: Int) -> Data {
        struct Content: Encodable {
            var title: String
            var body: String
            var machine: String
            var id: String?
            var kind: String?
            var text: String?
            var secret: Bool?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func encode(_ c: Content) -> Data { (try? encoder.encode(c)) ?? Data("{}".utf8) }
        var c = Content(title: String(title.prefix(200)), body: String(body.prefix(300)), machine: machine,
                        id: item?.id, kind: item?.kind)
        if let item, item.isSecret {   // the lock screen shows the body; the text goes along for a tap to copy
            c.body = Secret.hidden
            c.secret = true
        }
        if let item, item.kind == "text" {
            var whole = c
            whole.text = item.text ?? ""
            let d = encode(whole)
            if d.count <= limit { return d }
        }
        var out = encode(c)
        while out.count > limit, !(c.title.isEmpty && c.body.isEmpty) {   // only absurdly long names get here
            c.body = String(c.body.prefix(c.body.count / 2))
            c.title = String(c.title.prefix(c.title.count / 2))
            out = encode(c)
        }
        if out.count > limit {   // a machine address no computer has (api/relay-push takes it from the request)
            c.machine = ""
            out = encode(c)
        }
        return out
    }
}
