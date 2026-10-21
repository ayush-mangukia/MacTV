import Foundation
import CryptoKit

@main struct WireTests {
    static func main() throws {
        let secret = Data(0..<32), client = Data(32..<64).base64EncodedString(), server = Data(64..<96).base64EncodedString()
        let key = try RemoteWire.key(secret, client: client, server: server)
        let proof = RemoteWire.mac(secret, "server|1|test")
        let frame = try RemoteWire.seal(["type": "ping"], key: key, direction: "C2S!", sequence: 1)
        let opened = try RemoteWire.open(frame, key: key, direction: "C2S!", expected: 1)
        precondition(opened["type"] as? String == "ping")
        precondition(!RemoteWire.verify(proof, secret: Data(repeating: 0, count: 32), text: "server|1|test"))
        for (candidate, direction, sequence) in [(frame, "C2S!", 2), (frame, "S2C!", 1),
                                               (frame.merging(["body": Data(repeating: 0, count: 32).base64EncodedString()]) { _,new in new }, "C2S!", 1)] {
            do { _ = try RemoteWire.open(candidate, key: key, direction: direction, expected: sequence); fatalError("Accepted tamper/replay") }
            catch { }
        }
        let vector: [String: Any] = ["secret": secret.base64EncodedString(), "clientNonce": client, "serverNonce": server,
            "key": key.withUnsafeBytes { Data($0).base64EncodedString() }, "proof": proof, "frame": frame]
        print(String(data: try JSONSerialization.data(withJSONObject: vector, options: [.sortedKeys]), encoding: .utf8)!)
        fputs("Swift crypto checks passed: round trip, wrong proof, replay, direction, tamper\n", stderr)
    }
}
