import CryptoKit
import Foundation

/// The phone's notification keys, in Web Push's shape: a computer encrypts for them exactly as for a browser's
/// subscription (`keys.p256dh`, `keys.auth`), so bin/ferry needs no second way to encrypt.
public struct PushKeys: Codable, Equatable, Sendable {
    /// `P256.KeyAgreement.PrivateKey.rawRepresentation`
    public let privateKey: Data
    /// 16 random bytes
    public let auth: Data

    public init(privateKey: Data, auth: Data) {
        self.privateKey = privateKey
        self.auth = auth
    }

    public static func generate() -> PushKeys {
        PushKeys(privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation,
                 auth: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
    }

    /// The public key as an uncompressed point (65 bytes), base64url.
    public var p256dh: String {
        ((try? P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey))?.publicKey.x963Representation ?? Data()).base64URL
    }

    public var authString: String { auth.base64URL }
}

public enum PushCryptoError: Error, Equatable {
    case malformed
    case cannotDecrypt
}

/// RFC 8291 (Web Push message encryption), aes128gcm with a single record, as bin/ferry's `encrypt()` writes it.
public enum PushCrypto {
    /// salt(16) ‖ record size(4) ‖ key id length(1) ‖ the sender's public key(65) ‖ ciphertext ‖ tag(16)
    static let headerLength = 16 + 4 + 1 + 65
    static let tagLength = 16

    public static func decrypt(_ body: Data, with keys: PushKeys) throws -> Data {
        let body = Data(body)   // a slice's indices don't start at 0
        guard body.count > headerLength + tagLength, body[20] == 65 else { throw PushCryptoError.malformed }
        let salt = body[0..<16]
        let senderKey = body[21..<86]
        let sealed = body[86...]
        do {
            let me = try P256.KeyAgreement.PrivateKey(rawRepresentation: keys.privateKey)
            let shared = try me.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: senderKey))
            let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared.withUnsafeBytes { Data($0) }),
                                             salt: keys.auth,
                                             info: Data("WebPush: info\0".utf8) + me.publicKey.x963Representation + senderKey,
                                             outputByteCount: 32)
            let cek = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                             info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
            let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                               info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }),
                                            ciphertext: sealed.dropLast(tagLength), tag: sealed.suffix(tagLength))
            let padded = try AES.GCM.open(box, using: cek)
            // The last record ends in 0x02 after any zero padding
            guard let end = padded.lastIndex(where: { $0 != 0 }), padded[end] == 2 else { throw PushCryptoError.malformed }
            return padded[padded.startIndex..<end]
        } catch let e as PushCryptoError {
            throw e
        } catch {
            throw PushCryptoError.cannotDecrypt
        }
    }
}

extension Data {
    public init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }

    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
