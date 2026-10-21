import Foundation
import CryptoKit
import Security

// Protocol v1 is documented in protocol/README.md. All secrets use standard padded Base64.
enum RemoteWire {
    static let version = 1
    static func random(_ count: Int = 32) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }
    static func mac(_ secret: Data, _ text: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: secret))).base64EncodedString()
    }
    static func verify(_ value: String, secret: Data, text: String) -> Bool {
        guard let bytes = Data(base64Encoded: value) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Data(text.utf8), using: SymmetricKey(data: secret))
    }
    static func key(_ secret: Data, client: String, server: String) throws -> SymmetricKey {
        guard let c = Data(base64Encoded: client), c.count == 32,
              let s = Data(base64Encoded: server), s.count == 32 else { throw WireError.invalid }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: c + s,
                                     info: Data("MacTV/v1".utf8), outputByteCount: 32)
    }
    static func nonce(_ direction: String, _ sequence: Int) throws -> AES.GCM.Nonce {
        var number = UInt64(sequence).bigEndian
        return try AES.GCM.Nonce(data: Data(direction.utf8) + withUnsafeBytes(of: &number) { Data($0) })
    }
    static func seal(_ payload: [String: Any], key: SymmetricKey, direction: String, sequence: Int) throws -> [String: Any] {
        let aad = Data("MacTV/1/\(direction)/\(sequence)".utf8)
        let sealed = try AES.GCM.seal(JSONSerialization.data(withJSONObject: payload), using: key,
                                      nonce: nonce(direction, sequence), authenticating: aad)
        return ["v": 1, "type": "secure", "seq": sequence, "body": (sealed.ciphertext + sealed.tag).base64EncodedString()]
    }
    static func open(_ frame: [String: Any], key: SymmetricKey, direction: String, expected: Int) throws -> [String: Any] {
        guard frame["v"] as? Int == 1, frame["type"] as? String == "secure", frame["seq"] as? Int == expected,
              let body = frame["body"] as? String, let data = Data(base64Encoded: body), data.count >= 16 else { throw WireError.invalid }
        let box = try AES.GCM.SealedBox(nonce: nonce(direction, expected), ciphertext: data.dropLast(16), tag: data.suffix(16))
        let plain = try AES.GCM.open(box, using: key, authenticating: Data("MacTV/1/\(direction)/\(expected)".utf8))
        guard let result = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw WireError.invalid }
        return result
    }
    enum WireError: Error { case invalid }
}
