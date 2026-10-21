import Foundation
import Network
import CryptoKit
import Observation
import Security

@MainActor @Observable
final class RemoteServer {
    private(set) var status = "Remote stopped"
    private(set) var invitation = ""
    private(set) var pendingName: String?
    private(set) var pairedCount = 0
    private(set) var connectedCount = 0
    var host = RemoteServer.localAddress()
    @ObservationIgnored private var detectedHost = RemoteServer.localAddress()
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var peers: [UUID: Peer] = [:]
    @ObservationIgnored private var pending: UUID?
    @ObservationIgnored private var inviteSecret: Data?
    @ObservationIgnored private var inviteExpiry = Date.distantPast
    @ObservationIgnored private var credentials: [String: String] = [:]
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored var context: (() -> [String: Any])?
    @ObservationIgnored var command: (([String: Any]) -> (String, String))?
    private let serverID: String
    @ObservationIgnored private let storage: RemoteCredentialStorage
    private let port: UInt16

    init(storage: RemoteCredentialStorage? = nil, id: String? = nil, port: UInt16 = 8765) {
        self.storage = storage ?? KeychainRemoteCredentials(); self.port = port
        let defaults = UserDefaults.standard
        serverID = id ?? defaults.string(forKey: "remoteServerID") ?? UUID().uuidString
        if id == nil { defaults.set(serverID, forKey: "remoteServerID") }
        if let data = self.storage.read(),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) { credentials = stored }
        pairedCount = credentials.count
    }
    func start() {
        guard listener == nil else { return }
        do {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            options.maximumMessageSize = 16384
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            parameters.allowLocalEndpointReuse = true
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            let server = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener = server
            server.service = NWListener.Service(name: "MacTV-\(serverID.prefix(8))", type: "_mactv._tcp", txtRecord: NWTXTRecord(["v": "1", "id": serverID]))
            server.stateUpdateHandler = { [weak self, weak server] state in
                Task { @MainActor [weak self, weak server] in
                    guard let self, let server, self.listener === server else { return }
                    switch state {
                    case .ready: self.status = "Listening · port \(server.port?.rawValue ?? 0)"
                    case .failed(let error): self.stop(); self.status = "Remote unavailable: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            server.start(queue: .main)
            tick = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { break }
                    if let self {
                        let current = Self.localAddress()
                        if self.host == self.detectedHost { self.host = current }
                        self.detectedHost = current
                        self.heartbeat()
                    }
                }
            }
        } catch { status = "Remote unavailable: \(error.localizedDescription)" }
    }
    func stop() {
        restartTask?.cancel(); restartTask = nil
        tick?.cancel(); tick = nil
        listener?.cancel(); listener = nil
        for peer in Array(peers.values) { drop(peer) }
        inviteSecret = nil; invitation = ""; pending = nil; pendingName = nil
        status = "Remote stopped"
    }
    func restart() {
        stop()
        // NWListener cancellation is asynchronous; let its bound socket close before rebinding.
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }
    func newInvitation() {
        guard let port = listener?.port?.rawValue else { return }
        // Rotating an invitation also invalidates in-flight pairing attempts.
        for peer in Array(peers.values) where peer.mode == "pair" && !peer.authenticated { drop(peer) }
        inviteSecret = RemoteWire.random(); inviteExpiry = Date().addingTimeInterval(120)
        let json: [String: Any] = ["v": 1, "host": host, "port": Int(port), "id": serverID,
                                   "secret": inviteSecret!.base64EncodedString()]
        invitation = "mactv1:" + (try! JSONSerialization.data(withJSONObject: json)).base64EncodedString()
    }
    func approve(_ allowed: Bool) {
        guard let id = pending, let peer = peers[id] else { return }
        pending = nil; pendingName = nil
        guard allowed, Date() < inviteExpiry, peer.key != nil else { drop(peer); return }
        let token = RemoteWire.random().base64EncodedString()
        var updated = credentials; updated[peer.clientID] = token
        guard updated.count <= 8, let data = try? JSONEncoder().encode(updated), storage.write(data) else {
            status = "Could not save pairing in Keychain"; drop(peer); return
        }
        credentials = updated; pairedCount = credentials.count
        inviteSecret = nil; invitation = ""; inviteExpiry = .distantPast
        secure(peer, ["type": "paired", "token": token, "serverId": serverID])
        ready(peer)
        for other in Array(peers.values) where other !== peer && other.mode == "pair" && !other.authenticated { drop(other) }
    }
    func revokeAll() {
        guard storage.write(Data("{}".utf8)) else {
            status = "Could not revoke credentials in Keychain. Try again."; return
        }
        credentials = [:]; pairedCount = 0
        restart()
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < 8 else { connection.cancel(); return }
        let peer = Peer(connection); peers[peer.id] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            Task { @MainActor [weak self, weak peer] in
                guard let self, let peer else { return }
                switch state {
                case .ready: self.receive(peer)
                case .failed, .cancelled: self.drop(peer)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }
    private func receive(_ peer: Peer) {
        peer.connection.receiveMessage { [weak self, weak peer] data, context, _, error in
            Task { @MainActor [weak self, weak peer] in
                guard let self, let peer, self.peers[peer.id] != nil else { return }
                guard error == nil else { self.drop(peer); return }
                if let data, !data.isEmpty {
                    guard data.count <= 16384,
                          let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                          meta.opcode == .text,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { self.drop(peer); return }
                    do { try self.process(json, peer) } catch { self.drop(peer); return }
                } else if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                          meta.opcode == .close { self.drop(peer); return }
                self.receive(peer)
            }
        }
    }
    private func process(_ json: [String: Any], _ peer: Peer) throws {
        guard json["v"] as? Int == 1 else { throw RemoteWire.WireError.invalid }
        if peer.key == nil {
            if peer.clientID.isEmpty {
                guard json["type"] as? String == "hello", json["serverId"] as? String == serverID,
                      let id = json["clientId"] as? String, UUID(uuidString: id) != nil,
                      let nonce = json["nonce"] as? String, Data(base64Encoded: nonce)?.count == 32,
                      let mode = json["mode"] as? String, ["pair", "auth"].contains(mode) else { throw RemoteWire.WireError.invalid }
                peer.supportsContext = (json["capabilities"] as? [String])?.contains("context.v1") == true
                peer.clientID = id; peer.clientNonce = nonce; peer.mode = mode
                peer.serverNonce = RemoteWire.random().base64EncodedString()
                if mode == "pair", Date() < inviteExpiry { peer.secret = inviteSecret }
                else if mode == "auth", let token = credentials[id] { peer.secret = Data(base64Encoded: token) }
                guard let secret = peer.secret else { throw RemoteWire.WireError.invalid }
                peer.name = String((json["name"] as? String ?? "Android remote").prefix(64))
                send(peer, ["v": 1, "type": "challenge", "nonce": peer.serverNonce,
                            "proof": RemoteWire.mac(secret, transcript(peer, "server"))])
            } else {
                guard json["type"] as? String == "proof", let proof = json["proof"] as? String,
                      let secret = peer.secret,
                      RemoteWire.verify(proof, secret: secret, text: transcript(peer, "client")) else { throw RemoteWire.WireError.invalid }
                peer.key = try RemoteWire.key(secret, client: peer.clientNonce, server: peer.serverNonce)
                peer.secret = nil
                if peer.mode == "pair" {
                    guard pending == nil, Date() < inviteExpiry else { throw RemoteWire.WireError.invalid }
                    pending = peer.id; pendingName = peer.name
                    peer.deadline = Date().addingTimeInterval(60)
                    secure(peer, ["type": "pending"])
                } else { ready(peer) }
            }
            return
        }
        guard peer.authenticated, let key = peer.key else { throw RemoteWire.WireError.invalid }
        let payload = try RemoteWire.open(json, key: key, direction: "C2S!", expected: peer.received + 1)
        peer.received += 1; peer.lastSeen = Date()
        switch payload["type"] as? String {
        case "pong": break
        case "ping": secure(peer, ["type": "pong"])
        case "command":
            guard let id = payload["id"] as? Int, id > 0, id > peer.lastCommand,
                  let body = payload["command"] as? [String: Any] else { throw RemoteWire.WireError.invalid }
            peer.lastCommand = id
            // Rate limit authenticated senders as well as bounding frame and connection sizes.
            if Date().timeIntervalSince(peer.rateWindow) > 1 { peer.rateWindow = Date(); peer.rateCount = 0 }
            peer.rateCount += 1
            let result = peer.rateCount <= 120 ? (command?(body) ?? ("error", "MacTV is not ready")) : ("error", "Command rate exceeded")
            secure(peer, ["type": "ack", "id": id, "status": result.0, "message": result.1])
            publishContext()
        default: throw RemoteWire.WireError.invalid
        }
    }
    private func transcript(_ peer: Peer, _ role: String) -> String {
        "\(role)|1|\(serverID)|\(peer.mode)|\(peer.clientID)|\(peer.clientNonce)|\(peer.serverNonce)"
    }
    private func ready(_ peer: Peer) {
        for other in Array(peers.values) where other !== peer && other.clientID == peer.clientID { drop(other) }
        peer.authenticated = true; peer.lastSeen = Date()
        connectedCount = peers.values.filter(\.authenticated).count
        secure(peer, ["type": "ready", "serverId": serverID, "heartbeatSeconds": 5])
        publishContext()
    }
    private func secure(_ peer: Peer, _ payload: [String: Any]) {
        guard let key = peer.key else { return }
        peer.sent += 1
        do { send(peer, try RemoteWire.seal(payload, key: key, direction: "S2C!", sequence: peer.sent)) }
        catch { drop(peer) }
    }
    private func send(_ peer: Peer, _ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { drop(peer); return }
        let context = NWConnection.ContentContext(identifier: "MacTV", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        peer.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak peer] error in
            if error != nil { Task { @MainActor [weak self, weak peer] in if let peer { self?.drop(peer) } } }
        })
    }
    func publishContext() {
        guard var payload = context?() else { return }
        payload["type"] = "context"
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys) else { return }
        for peer in Array(peers.values) where peer.authenticated && peer.supportsContext && peer.lastContext != encoded {
            peer.lastContext = encoded; secure(peer, payload)
        }
    }
    private func heartbeat() {
        publishContext()
        if inviteSecret != nil && Date() >= inviteExpiry { inviteSecret = nil; invitation = "" }
        for peer in Array(peers.values) {
            if peer.authenticated {
                if Date().timeIntervalSince(peer.lastSeen) > 16 { drop(peer) }
                else { secure(peer, ["type": "ping"]) }
            } else if Date() > peer.deadline { drop(peer) }
        }
    }
    private func drop(_ peer: Peer) {
        guard peers.removeValue(forKey: peer.id) != nil else { return }
        peer.connection.cancel()
        if pending == peer.id { pending = nil; pendingName = nil }
        connectedCount = peers.values.filter(\.authenticated).count
    }
    private static func localAddress() -> String {
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0 else { return ProcessInfo.processInfo.hostName }
        defer { freeifaddrs(address) }
        var cursor = address
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let sa = item.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: item.pointee.ifa_name).hasPrefix("en") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: buffer)
            }
        }
        return ProcessInfo.processInfo.hostName
    }
}

@MainActor private final class Peer {
    let id = UUID()
    let connection: NWConnection
    var clientID = "", clientNonce = "", serverNonce = "", mode = "", name = ""
    var secret: Data?
    var key: SymmetricKey?
    var sent = 0, received = 0, lastCommand = 0, rateCount = 0
    var authenticated = false
    var supportsContext = false
    var lastContext: Data?
    var lastSeen = Date(), deadline = Date().addingTimeInterval(15), rateWindow = Date()
    init(_ connection: NWConnection) { self.connection = connection }
}

@MainActor protocol RemoteCredentialStorage {
    func read() -> Data?
    func write(_ data: Data) -> Bool
}
@MainActor struct KeychainRemoteCredentials: RemoteCredentialStorage {
    func read() -> Data? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MacTV.remote.v1",
                                   kSecAttrAccount as String: "remote-credentials-v1", kSecReturnData as String: true]
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    func write(_ data: Data) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MacTV.remote.v1", kSecAttrAccount as String: "remote-credentials-v1"]
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        var insert = query; insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}
